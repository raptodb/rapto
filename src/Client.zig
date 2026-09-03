//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of zig-rapto client.

const Client = @This();

const std = @import("std");
const frames = @import("frames.zig");
const value = @import("Client/value.zig");
const assert = std.debug.assert;

const Query = @import("Query.zig");
const Pipeline = @import("Pipeline.zig");
const Stream = @import("Stream.zig");

const Quota = Query.Flags.Quota;

pub const Config = struct {
    /// Address of Server to connect, default: 127.0.0.1:7286.
    address: std.Io.net.IpAddress = .{ .ip4 = .loopback(7286) },
};

pub const Batch = struct {
    pub const Config = struct {
        /// Minimum size for pipeline. This optimizes the
        /// allocation/deallocation overhead.
        /// The preserved size is allocated at initialization time
        /// and is never deallocated until the `deinit()` method.
        pipeline_preserved_size: u32 = 16 * 1024 * 2,
        /// Maximum readable bytes from `flush()` or `flushOne()` over header.
        /// This avoid too large inputs from reader (maybe socket)
        /// throwing error.StreamTooLong.
        /// For now, by default, we can set at largest limit possible,
        /// see Pipeline.Header.
        max_pipeline_bytes: u64 = std.math.maxInt(u32),
    };

    const Builder = struct {
        serializer: Query.Serializer,
        wrapped_builder: Pipeline.Builder,

        fn begin(
            pipeline: *Pipeline,
            command: Query.Command,
            flags: Query.Flags,
        ) std.mem.Allocator.Error!Builder {
            const builder: Pipeline.Builder = try .begin(pipeline);
            const serializer: Query.Serializer = try .begin(
                pipeline.writer(),
                command,
                flags,
            );
            return .{ .serializer = serializer, .wrapped_builder = builder };
        }

        fn end(self: Builder) void {
            self.wrapped_builder.end();
        }

        fn append(self: Builder, arg: []const u8) std.mem.Allocator.Error!void {
            return self.serializer.appendArg(arg);
        }

        fn appendVec(self: Builder, args: []const []const u8) std.mem.Allocator.Error!void {
            for (args) |arg| try self.append(arg);
        }

        fn appendScalarValue(self: Builder, scalar: value.Scalar) std.mem.Allocator.Error!void {
            const builder = try self.serializer.beginArg();
            defer builder.end();
            scalar.serializeToWriter(builder.writer) catch |err| return switch (err) {
                // Assuming writer is derived from std.Io.Writer.Allocating,
                // write fails are caused by OOM.
                error.WriteFailed => error.OutOfMemory,
            };
        }

        fn appendNumeric(self: Builder, comptime T: type, v: T) std.mem.Allocator.Error!void {
            comptime assert(@sizeOf(T) <= 8);
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, v, .little);
            return self.append(buf[0..@sizeOf(T)]);
        }

        fn appendRange(self: Builder, range: Range) std.mem.Allocator.Error!void {
            try self.appendNumeric(i64, range.from_index);
            try self.appendNumeric(i64, range.to_index);
        }
    };

    config: Batch.Config,

    client: Client,
    pipeline: Pipeline,
    /// Queries appended but not flushed.
    pending: u64 = 0,
    /// For each query, sets flag `assume_lock_ownership` to true.
    assume_lock_ownership: bool = false,

    pub fn deinit(self: *Batch) void {
        self.pipeline.deinit();
    }

    pub const FlushError =
        Pipeline.ReadError || std.Io.net.Stream.Reader.Error || std.Io.net.Stream.Writer.Error;

    /// Flushes all queries until last `flush()` to stream.
    /// After flushing, returns replies pipeline. Not thread-safe.
    pub fn flush(self: *Batch, io: std.Io) FlushError!value.ReturnValues {
        assert(self.pending != 0);
        const pending_before_stream = self.pending;

        var reader = self.client.stream.reader(io);
        var writer = self.client.stream.writer(io);

        self.pipeline.stream(&writer.interface) catch |err| return switch (err) {
            error.WriteFailed => writer.err.?,
        };
        // All pending queries were drained.
        self.pending = 0;

        self.pipeline.read(&reader.interface) catch |err| return switch (err) {
            error.OutOfMemory, error.EndOfStream => |e| e,
            error.ReadFailed => reader.err.?,
            error.StreamTooLong => err: {
                // For now, current read limit is Batch.Config.max_pipeline_bytes.
                // This error is likely to never be reached.
                @branchHint(.cold);
                break :err error.StreamTooLong;
            },
        };

        const replies = self.pipeline.take();
        assert(pending_before_stream == replies.len);

        return .init(replies);
    }

    pub const FlushOneError = FlushError || value.ReturnValue.DeserializeError;

    /// As `flush()`, assuming one pending query. Not thread-safe between `Client`.
    pub fn flushOne(self: *Batch, io: std.Io) FlushOneError!value.ReturnValue {
        assert(self.pending == 1);
        const rvs = try self.flush(io);
        assert(rvs.len == 1 and self.pending == 0);
        return rvs.at(0);
    }

    pub fn build(
        self: *Batch,
        command: Query.Command,
        flags: Query.Flags,
        args: anytype,
    ) std.mem.Allocator.Error!void {
        const args_info = @typeInfo(@TypeOf(args));
        comptime assert(args_info == .@"struct");

        var mut_flags = flags;
        mut_flags.assume_lock_ownership = .init(self.assume_lock_ownership);

        var builder: Builder = try .begin(&self.pipeline, command, mut_flags);
        defer builder.end();

        const fields = args_info.@"struct".fields;
        inline for (fields) |field| {
            const arg = @field(args, field.name);
            switch (field.type) {
                []const []const u8 => try builder.appendVec(arg),
                []const u8 => try builder.append(arg),
                value.Scalar => try builder.appendScalarValue(arg),
                Range => try builder.appendRange(arg),
                else => switch (@typeInfo(field.type)) {
                    .int, .float => try builder.appendNumeric(field.type, arg),
                    else => @compileError("Unsupported Batch.build() argument type"),
                },
            }
        }

        self.pending += 1;
    }

    /// Range of relative indexes.
    pub const Range = struct {
        from_index: i64,
        to_index: i64,

        pub const default: Range = .{
            .from_index = 0,
            .to_index = -1,
        };
    };

    pub const MatchingConfig = struct { limit: Quota = .unlimited };
    pub const MatchingCursorConfig = struct { limit: Quota = .unlimited, cursor: u64 = 0 };
    pub const CreateConfig = struct { get: bool = false, if_not_exists: bool = false };
    pub const DelConfig = struct { get: bool = false };
    pub const ItemsConfig = struct { limit: Quota = .unlimited, range: Range = .default };
    pub const DelItemsConfig =
        struct { get: bool = false, limit: Quota = .unlimited, range: Range = .default };
    pub const GetConfig = struct { limit: Quota = .unlimited };
    pub const InsertConfig = struct { get: bool, replace: bool, index: u64 = std.math.maxInt(u64) };
    pub const RenameConfig = struct { if_not_exists: bool = true };

    pub fn ping(self: *Batch) std.mem.Allocator.Error!void {
        return self.build(.ping, .{}, .{});
    }

    pub fn down(self: *Batch) std.mem.Allocator.Error!void {
        return self.build(.down, .{}, .{});
    }

    pub fn purge(self: *Batch) std.mem.Allocator.Error!void {
        return self.build(.purge, .{}, .{});
    }

    pub fn get(
        self: *Batch,
        keys: []const []const u8,
        config: GetConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .limit = config.limit };
        return self.build(.get, flags, .{keys});
    }

    pub fn getItems(
        self: *Batch,
        key: []const u8,
        config: ItemsConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .limit = config.limit };
        return self.build(.get_list, flags, .{ key, config.range });
    }

    pub fn getEntries(
        self: *Batch,
        key: []const u8,
        map_keys: []const []const u8,
    ) std.mem.Allocator.Error!void {
        return self.build(.get_map, .{}, .{ key, map_keys });
    }

    pub fn del(self: *Batch, key: []const u8, config: DelConfig) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .get = config.get };
        return self.build(.del, flags, .{key});
    }

    pub fn delMatching(
        self: *Batch,
        glob_patterns: []const []const u8,
        config: MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .limit = config.limit, .cursor = .init(config.cursor) };
        return self.build(.del_patterns, flags, .{glob_patterns});
    }

    pub fn delItems(
        self: *Batch,
        key: []const u8,
        config: DelItemsConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .get = .init(config.get), .limit = config.limit };
        return self.build(.del_list, flags, .{ key, config.range });
    }

    pub fn delEntries(
        self: *Batch,
        key: []const u8,
        map_keys: []const []const u8,
        config: DelConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .limit = config.limit };
        return self.build(.del_map, flags, .{ key, map_keys });
    }

    pub fn delEntriesMatching(
        self: *Batch,
        key: []const u8,
        map_keys: []const []const u8,
        config: MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .limit = config.limit, .cursor = .init(config.cursor) };
        return self.build(.del_map_patterns, flags, .{ key, map_keys });
    }

    pub fn count(self: *Batch, config: MatchingConfig) std.mem.Allocator.Error!void {
        const cm_config: MatchingCursorConfig = .{ .limit = config.limit };
        return self.countMatching(&.{"*"}, cm_config);
    }

    pub fn countMatching(
        self: *Batch,
        glob_patterns: []const []const u8,
        config: MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{
            .limit = config.limit,
            .cursor = .init(config.cursor),
        };
        return self.build(.count_patterns, flags, .{glob_patterns});
    }

    pub fn countItems(self: *Batch, key: []const u8) std.mem.Allocator.Error!void {
        return self.build(.count_list, .{}, .{key});
    }

    pub fn countEntries(
        self: *Batch,
        key: []const u8,
        config: MatchingConfig,
    ) std.mem.Allocator.Error!void {
        const cem_config: MatchingCursorConfig = .{ .limit = config.limit };
        return self.countEntriesMatching(key, &.{"*"}, cem_config);
    }

    pub fn countEntriesMatching(
        self: *Batch,
        key: []const u8,
        glob_patterns: []const []const u8,
        config: MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{
            .limit = config.limit,
            .cursor = .init(config.cursor),
        };
        return self.build(.count_map_patterns, flags, .{ key, glob_patterns });
    }

    pub fn exists(self: *Batch, keys: []const []const u8) std.mem.Allocator.Error!void {
        return self.build(.exists, .{}, .{keys});
    }

    pub fn existsEntries(
        self: *Batch,
        key: []const u8,
        map_keys: []const []const u8,
    ) std.mem.Allocator.Error!void {
        return self.build(.exists_map, .{}, .{ key, map_keys });
    }

    pub fn set(
        self: *Batch,
        key: []const u8,
        scalar: value.Scalar,
        config: CreateConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{
            .get = .init(config.get),
            .if_not_exists = .init(config.if_not_exists),
        };
        return self.build(.set, flags, .{ key, scalar });
    }

    pub fn appendItem(
        self: *Batch,
        key: []const u8,
        scalar: value.Scalar,
    ) std.mem.Allocator.Error!void {
        return self.build(.append_list, .{}, .{ key, scalar });
    }

    pub fn appendString(
        self: *Batch,
        key: []const u8,
        scalar: value.Scalar,
    ) std.mem.Allocator.Error!void {
        return self.build(.append_string, .{}, .{ key, scalar });
    }

    pub fn insertItem(
        self: *Batch,
        key: []const u8,
        scalar: value.Scalar,
        config: InsertConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .get = .init(config.get), .replace = .init(config.replace) };
        return self.build(.insert_list, flags, .{ key, config.index, scalar });
    }

    pub fn insertString(
        self: *Batch,
        key: []const u8,
        scalar: value.Scalar,
        config: InsertConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .get = .init(config.get), .replace = .init(config.replace) };
        return self.build(.insert_string, flags, .{ key, config.index, scalar });
    }

    pub fn put(
        self: *Batch,
        key: []const u8,
        map_key: []const u8,
        scalar: value.Scalar,
        config: CreateConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{
            .get = .init(config.get),
            .if_not_exists = .init(config.if_not_exists),
        };
        return self.build(.put, flags, .{ key, map_key, scalar });
    }

    pub fn add(self: *Batch, key: []const u8, scalar: value.Scalar) std.mem.Allocator.Error!void {
        return self.build(.add, .{}, .{ key, scalar });
    }

    pub fn sub(self: *Batch, key: []const u8, scalar: value.Scalar) std.mem.Allocator.Error!void {
        return self.build(.sub, .{}, .{ key, scalar });
    }

    pub fn rename(
        self: *Batch,
        current_key: []const u8,
        new_key: []const u8,
        config: RenameConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .if_not_exists = .init(config.if_not_exists) };
        return self.build(.rename, flags, .{ current_key, new_key });
    }

    pub fn copy(
        self: *Batch,
        from_key: []const u8,
        to_key: []const u8,
        config: CreateConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{
            .get = .init(config.get),
            .if_not_exists = .init(config.if_not_exists),
        };
        return self.build(.copy, flags, .{ from_key, to_key });
    }

    pub fn typeOf(self: *Batch, keys: []const []const u8) std.mem.Allocator.Error!void {
        return self.build(.type, .{}, .{keys});
    }

    pub fn typeOfItems(
        self: *Batch,
        key: []const u8,
        config: ItemsConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{ .limit = config.limit };
        return self.build(.type_list, flags, .{ key, config.range });
    }

    pub fn typeOfEntries(
        self: *Batch,
        key: []const u8,
        map_keys: []const []const u8,
    ) std.mem.Allocator.Error!void {
        return self.build(.type_map, .{}, .{ key, map_keys });
    }

    pub fn keysMatching(
        self: *Batch,
        glob_patterns: []const []const u8,
        config: MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{
            .limit = config.limit,
            .cursor = .init(config.cursor),
        };
        return self.build(.keys_patterns, flags, .{glob_patterns});
    }

    pub fn entriesMatching(
        self: *Batch,
        key: []const u8,
        glob_patterns: []const []const u8,
        config: MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        const flags: Query.Flags = .{
            .limit = config.limit,
            .cursor = .init(config.cursor),
        };
        return self.build(.entries_patterns, flags, .{ key, glob_patterns });
    }

    /// Tries to lock atomically keys until `unlock`. If any key is
    /// already locked, it fails throwing error.Locked.
    /// Initializes lock instance that assumes all queries appended do not include
    /// non-owned keys or locked keys by others. Initialization assumes no pending
    /// queries. Ownership will be transfered to caller, responsible of `unlock()`.
    ///
    /// After this call, the batch used to perform lock operations can be accessed
    /// directly from Lock.batch, not responsible of `deinit()`.
    pub fn lock(
        self: *Batch,
        allocator: std.mem.Allocator,
        io: std.Io,
        keys: []const []const u8,
        config: Lock.Config,
    ) Lock.Error!Lock {
        return .lock(self, allocator, io, .{ .literals = keys }, config);
    }

    /// As `lock`, but keys are locked/unlocked by searching keys
    /// with glob patterns. Initialization assumes no pending queries.
    /// Ownership will be transfered to caller, responsible of `unlock()`.
    ///
    /// After this call, the batch used to perform lock operations can be accessed
    /// directly from Lock.batch, not responsible of `deinit()`.
    pub fn lockMatching(
        self: *Batch,
        allocator: std.mem.Allocator,
        io: std.Io,
        glob_patterns: []const []const u8,
        config: Lock.Config,
    ) Lock.Error!Lock {
        return .lock(self, allocator, io, .{ .glob_patterns = glob_patterns }, config);
    }

    /// Cursor is used by iterative operations, so `flush()`
    /// is handled automatically. Any iterative function of cursor,
    /// asserts no pending queries. Does not take ownership.
    pub fn cursor(self: *Batch) Cursor {
        return .{ .b = self };
    }
};

pub const Lock = struct {
    pub const Config = struct {
        /// Minimum size for pipeline of lock batch. This optimizes
        /// the allocation/deallocation overhead.
        /// The preserved size is allocated at initialization time
        /// and is never deallocated until the `deinit()` method.
        batch_pipeline_preserved_size: u32 = 4 * 1024,
        /// Maximum readable bytes from `flush()` or `flushOne()` over header.
        /// This avoid too large inputs from reader (maybe socket)
        /// throwing error.StreamTooLong.
        /// For now, by default, we can set at largest limit possible,
        /// see Pipeline.Header.
        max_pipeline_bytes: u64 = std.math.maxInt(u32),
    };

    pub const Error = Batch.FlushError || error{Locked};

    /// Likely to be accessed directly. This batch sets
    /// by default `assume_lock_ownership` to true.
    batch: Batch,

    b: *Batch,
    locked: bool,
    keys: union(enum) {
        literals: []const []const u8,
        glob_patterns: []const []const u8,
    },

    fn lock(
        b: *Batch,
        allocator: std.mem.Allocator,
        io: std.Io,
        keys: union(enum) {
            literals: []const []const u8,
            glob_patterns: []const []const u8,
        },
        config: Lock.Config,
    ) Lock.Error!Lock {
        assert(b.pending == 0);

        var lock_instance: Lock = undefined;
        lock_instance.b = b;
        lock_instance.keys = keys;

        const batch_config: Batch.Config = .{
            .pipeline_preserved_size = config.batch_pipeline_preserved_size,
            .max_pipeline_bytes = config.max_pipeline_bytes,
        };
        lock_instance.batch = try b.client.batch(allocator, batch_config);
        errdefer lock_instance.batch.deinit();
        lock_instance.batch.assume_lock_ownership = true;

        // Try to lock all selected keys.
        try b.build(.lock, .{}, .{keys});
        const resp = try b.flushOne(io);
        // At least one key is locked...
        // We can't lock an already locked key.
        if (resp.maybeError(.locked)) return error.Locked;

        lock_instance.locked = true;
        return lock_instance;
    }

    /// Unlocks all locked keys/patterns. This call flushes query.
    /// Assumes no pending queries from all two batches.
    pub fn unlock(self: *Lock, io: std.Io) Batch.FlushError!void {
        assert(self.locked);
        assert(self.b.pending == 0 and self.batch.pending == 0);

        switch (self.keys) {
            .literals => |l| try self.b.build(.unlock, .{}, .{l}),
            .glob_patterns => |p| try self.b.build(.unlock_patterns, .{}, .{p}),
        }
        const rv = try self.b.flushOne(io);
        // Unlock never returns an error.
        assert(!rv.hasError());

        try self.batch.deinit();
        // In this line flush has succeeded.
        self.locked = false;
        self.b.assume_lock_ownership = false;
    }
};

pub const Cursor = struct {
    b: *Batch,

    pub fn ListResultIterator(comptime Context: type) type {
        return struct {
            const Self = @This();

            b: *Batch,

            ctx: Context,
            queryFn: *const fn (
                ctx: *const Context,
                b: *Batch,
                config: Batch.MatchingCursorConfig,
            ) std.mem.Allocator.Error!void,

            cursor: u64 = 0,
            count: u64,
            max_cursor: u64,

            pub fn next(self: *Self, io: std.Io) Batch.FlushOneError!?value.ListIterator {
                assert(self.b.pending == 0);
                if (self.cursor == self.max_cursor) return null;

                const config: Batch.MatchingCursorConfig = .{
                    .limit = .init(self.count),
                    .cursor = self.cursor,
                };
                try self.queryFn(self.ctx, self.b, config);

                const rv = try self.b.flushOne(io);
                if (rv.type() != .list) return error.MismatchType;
                const list = rv.list;

                self.cursor = @min(self.cursor +| self.count, self.max_cursor);
                return list;
            }
        };
    }

    pub fn IntegerResultIterator(comptime Context: type) type {
        return struct {
            const Self = @This();

            b: *Batch,

            ctx: Context,
            queryFn: *const fn (
                ctx: *const Context,
                b: *Batch,
                config: Batch.MatchingCursorConfig,
            ) std.mem.Allocator.Error!void,

            cursor: u64 = 0,
            count: u64,
            max_cursor: u64,

            pub fn next(self: *Self, io: std.Io) Batch.FlushOneError!?i64 {
                assert(self.b.pending == 0);

                const config: Batch.MatchingCursorConfig = .{
                    .limit = .init(self.count),
                    .cursor = self.cursor,
                };
                try self.queryFn(self.ctx, self.b, config);

                const rv = try self.b.flushOne(io);
                if (rv.type() != .integer) return error.MismatchType;

                self.cursor = @min(self.cursor +| self.count, self.max_cursor);
                return rv.scalar.integer;
            }
        };
    }

    const KeysContext = struct { glob_patterns: []const []const u8 };
    const EntriesContext = struct { key: []const u8, glob_patterns: []const []const u8 };

    pub fn keysIterator(
        self: Cursor,
        glob_patterns: []const []const u8,
        count: u64,
        /// Once `next()` reaches this position, it returns null instead of
        /// issuing another query. Maybe retrieved with `Batch.count(.{})`.
        max_cursor: u64,
    ) ListResultIterator(KeysContext) {
        return .{
            .b = self.b,
            .ctx = .{ .glob_patterns = glob_patterns },
            .queryFn = keysMatchingFn,
            .count = count,
            .max_cursor = max_cursor,
        };
    }

    pub fn entriesIterator(
        self: Cursor,
        key: []const u8,
        glob_patterns: []const []const u8,
        count: u64,
        /// Once `next()` reaches this position, it returns null instead of
        /// issuing another query. Maybe retrieved with `Batch.countEntries(.{})`.
        max_cursor: u64,
    ) ListResultIterator(EntriesContext) {
        return .{
            .b = self.b,
            .ctx = .{
                .key = key,
                .glob_patterns = glob_patterns,
            },
            .queryFn = entriesMatchingFn,
            .count = count,
            .max_cursor = max_cursor,
        };
    }

    pub fn countIterator(
        self: Cursor,
        glob_patterns: []const []const u8,
        count: u64,
        /// Once `next()` reaches this position, it returns null instead of
        /// issuing another query. Maybe retrieved with `Batch.count(.{})`.
        max_cursor: u64,
    ) IntegerResultIterator(KeysContext) {
        return .{
            .b = self.b,
            .ctx = .{ .glob_patterns = glob_patterns },
            .queryFn = countMatchingFn,
            .count = count,
            .max_cursor = max_cursor,
        };
    }

    pub fn countEntriesIterator(
        self: Cursor,
        key: []const u8,
        glob_patterns: []const []const u8,
        count: u64,
        /// Once `next()` reaches this position, it returns null instead of
        /// issuing another query. Maybe retrieved with `Batch.countEntries(.{})`.
        max_cursor: u64,
    ) IntegerResultIterator(EntriesContext) {
        return .{
            .b = self.b,
            .ctx = .{ .key = key, .glob_patterns = glob_patterns },
            .queryFn = countEntriesMatchingFn,
            .count = count,
            .max_cursor = max_cursor,
        };
    }

    pub fn delIterator(
        self: Cursor,
        glob_patterns: []const []const u8,
        count: u64,
        /// Once `next()` reaches this position, it returns null instead of
        /// issuing another query. Maybe retrieved with `Batch.count(.{})`.
        max_cursor: u64,
    ) IntegerResultIterator(KeysContext) {
        return .{
            .b = self.b,
            .ctx = .{ .glob_patterns = glob_patterns },
            .queryFn = delMatchingFn,
            .count = count,
            .max_cursor = max_cursor,
        };
    }

    pub fn delEntriesIterator(
        self: Cursor,
        key: []const u8,
        glob_patterns: []const []const u8,
        count: u64,
        /// Once `next()` reaches this position, it returns null instead of
        /// issuing another query. Maybe retrieved with `Batch.countEntries(.{})`.
        max_cursor: u64,
    ) IntegerResultIterator(EntriesContext) {
        return .{
            .b = self.b,
            .ctx = .{ .key = key, .glob_patterns = glob_patterns },
            .queryFn = delEntriesMatchingFn,
            .count = count,
            .max_cursor = max_cursor,
        };
    }

    fn keysMatchingFn(
        ctx: *const KeysContext,
        b: *Batch,
        config: Batch.MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        return b.keysMatching(ctx.glob_patterns, config);
    }

    fn entriesMatchingFn(
        ctx: *const EntriesContext,
        b: *Batch,
        config: Batch.MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        return b.entriesMatching(ctx.key, ctx.glob_patterns, config);
    }

    fn countMatchingFn(
        ctx: *const KeysContext,
        b: *Batch,
        config: Batch.MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        return b.countMatching(ctx.glob_patterns, config);
    }

    fn countEntriesMatchingFn(
        ctx: *const EntriesContext,
        b: *Batch,
        config: Batch.MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        return b.countEntriesMatching(ctx.key, ctx.glob_patterns, config);
    }

    fn delMatchingFn(
        ctx: *const KeysContext,
        b: *Batch,
        config: Batch.MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        return b.delMatching(ctx.glob_patterns, config);
    }

    fn delEntriesMatchingFn(
        ctx: *const EntriesContext,
        b: *Batch,
        config: Batch.MatchingCursorConfig,
    ) std.mem.Allocator.Error!void {
        return b.delEntriesMatching(ctx.key, ctx.glob_patterns, config);
    }
};

stream: Stream,

pub fn open(io: std.Io, config: Config) Stream.ConnectError!Client {
    return .{ .stream = try .connect(io, config.address) };
}

pub fn close(self: Client, io: std.Io) void {
    self.stream.close(io);
}

/// Initializes batch by preallocating pipeline.
/// Ownership will be transfered to caller, responsible of `deinit()`.
pub fn batch(
    self: Client,
    allocator: std.mem.Allocator,
    config: Batch.Config,
) std.mem.Allocator.Error!Batch {
    const pipeline_config: Pipeline.Config = .{
        .rw_buffer_preserved_size = config.pipeline_preserved_size,
        .max_pipeline_bytes = config.max_pipeline_bytes,
    };
    const pipeline: Pipeline = try .init(allocator, pipeline_config);
    return .{ .client = self, .pipeline = pipeline, .config = config };
}
