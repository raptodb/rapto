//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of benchmark.

const Benchmark = @This();

const std = @import("std");
const cli = @import("cli.zig");
const assert = std.debug.assert;

const Client = @import("Client.zig");

pub const Context = struct {
    pub const Error = error{ UnsupportedTest, KeyTooShort };

    config: Config,
    threaded: std.Io.Threaded,

    pub fn init(
        allocator: std.mem.Allocator,
        args: *const cli.Command.Benchmark,
    ) Context.Error!Context {
        // Already checked in cli/Benchmark.zig.
        assert(args.clients != 0);
        if (args.key_size == 0) return error.KeyTooShort;

        const config: Config = .{
            .address = args.address,
            .clients = args.clients,
            .batch_size = args.batch_size,
            .test_cmd = std.meta.stringToEnum(Config.TestCmd, args.@"test") orelse
                return error.UnsupportedTest,
            .ops_per_client = @divCeil(args.ops, args.clients),
            .dataset_keys = args.dataset_keys,
            .warmup_batches = args.warmup_batches,
            .key_size = args.key_size,
            .value_size = args.value_size,
        };

        var threaded: std.Io.Threaded = .init_single_threaded;
        if (config.clients > 1) threaded = .init(allocator, .{});

        return .{ .config = config, .threaded = threaded };
    }

    pub fn deinit(self: *Context) void {
        self.threaded.deinit();
    }

    pub fn benchmark(self: *Context) Benchmark {
        return .{ .config = self.config, .io = self.threaded.io() };
    }
};

pub const Config = struct {
    /// IP address of Server, default: 127.0.0.1:7286.
    address: std.Io.net.IpAddress,
    /// Number of concurrent clients.
    clients: u32,
    /// Number of operations per batch.
    batch_size: u32,
    /// Test command to benchmark.
    test_cmd: TestCmd,
    /// Operations per client.
    ops_per_client: u64,
    /// Number of preloaded dataset keys.
    dataset_keys: u32,
    /// Number of batches used as warmup.
    warmup_batches: u32,
    /// Key size in bytes.
    key_size: u32,
    /// Value size in bytes.
    value_size: u32,

    pub const TestCmd = enum { set, @"get-hit", @"get-miss" };
};

config: Config,

/// Single threaded or multi-threaded Io. Current
/// configuration is affected by config.clients.
io: std.Io,

dataset_keys: u64 = 0,
shared_op_index: std.atomic.Value(u64) = .init(0),

pub fn run(self: *Benchmark, allocator: std.mem.Allocator) !Stats {
    var clients: std.ArrayList(Client) = try .initCapacity(allocator, self.config.clients);
    defer clients.deinit(allocator);
    clients.expandToCapacity();
    var futures: std.ArrayList(std.Io.Future(Client.Batch.FlushError!Stats)) =
        try .initCapacity(allocator, self.config.clients);
    defer futures.deinit(allocator);
    futures.expandToCapacity();
    const client_config: Client.Config = .{ .address = self.config.address };
    // Perform connections.
    for (clients.items) |*client| client.* = try .open(self.io, client_config);
    defer for (clients.items) |*client| client.close(self.io);

    // All stats of clients merged with each other.
    var stats: Stats = .empty;
    stats.key_size = self.config.key_size;
    stats.value_size = self.config.value_size;

    {
        assert(clients.items.len != 0);
        const first_client = &clients.items[0];
        var batch = try first_client.batch(allocator, .{});
        defer batch.deinit();
        // After initialization of all clients, we need to load
        // dataset from this configuration.
        // For convenience we can use batch of first client as a guinea pig.
        try self.loadDataset(allocator, &batch);
        const loaded_keys = self.dataset_keys;
        // Now we do warmup with the same guinea pig xD
        const warmup_ok = try self.warmup(allocator, &batch);

        stats.dataset_keys = loaded_keys;
        stats.warmup_batches = if (warmup_ok) self.config.warmup_batches else 0;
    }

    for (clients.items, futures.items) |*client, *future| {
        // We have to call async to avoid error.ConcurrencyUnavailable
        // when `io` is initialized as single-threaded.
        future.* = self.io.async(runTest, .{ self, allocator, client });
    }

    for (futures.items) |*future| {
        // Propagate errors, if they are present.
        var client_stats: Stats = try future.await(self.io);
        defer client_stats.deinit(allocator);

        try stats.merge(allocator, client_stats);
    }

    return stats;
}

pub const Stats = struct {
    /// Duration of each batch, kept sorted in ascending order.
    sorted_latencies: std.ArrayList(std.Io.Duration),
    /// Duration to execute `total_ops`.
    duration: std.Io.Duration,
    total_ops: u64,

    // Pre-benchmarking data.
    dataset_keys: u64 = 0,
    warmup_batches: u64 = 0,
    key_size: ?u64 = null,
    value_size: ?u64 = null,

    pub const empty: Stats = .{
        .sorted_latencies = .empty,
        .duration = .zero,
        .total_ops = 0,
    };

    pub fn deinit(self: *Stats, allocator: std.mem.Allocator) void {
        self.sorted_latencies.deinit(allocator);
    }

    const ascAppend = struct {
        fn asc(a: std.Io.Duration, b: std.Io.Duration) std.math.Order {
            return std.math.order(a.nanoseconds, b.nanoseconds);
        }
    }.asc;
    const ascMerge = struct {
        fn asc(_: void, a: std.Io.Duration, b: std.Io.Duration) bool {
            return ascAppend(a, b) == .lt;
        }
    }.asc;

    pub fn append(
        self: *Stats,
        allocator: std.mem.Allocator,
        latency: std.Io.Duration,
        total_ops: u64,
    ) std.mem.Allocator.Error!void {
        const index = std.sort.upperBound(
            std.Io.Duration,
            self.sorted_latencies.items,
            latency,
            ascAppend,
        );
        try self.sorted_latencies.insert(allocator, index, latency);
        self.duration.nanoseconds += latency.nanoseconds;
        self.total_ops += total_ops;
    }

    pub fn merge(
        self: *Stats,
        allocator: std.mem.Allocator,
        stats: Stats,
    ) std.mem.Allocator.Error!void {
        try self.sorted_latencies.appendSlice(allocator, stats.sorted_latencies.items);
        std.mem.sort(std.Io.Duration, self.sorted_latencies.items, {}, ascMerge);
        self.duration.nanoseconds = @max(self.duration.nanoseconds, stats.duration.nanoseconds);
        self.total_ops += stats.total_ops;
    }

    pub fn avg(self: Stats) std.Io.Duration {
        var sum: std.Io.Duration = .zero;
        for (self.sorted_latencies.items) |duration| sum.nanoseconds += duration.nanoseconds;
        return .fromNanoseconds(@divFloor(sum.nanoseconds, @max(self.count(), 1)));
    }

    pub fn percentile(self: Stats, p: f64) std.Io.Duration {
        assert(p >= 0.0 and p <= 1.0);
        if (self.count() == 0) return .zero;
        const last_index: f64 = @floatFromInt(self.count() - 1);
        const idx: usize = @round(last_index * p);
        return self.sorted_latencies.items[idx];
    }

    pub fn operationsPerSecond(self: Stats) f64 {
        const ops: f64 = @floatFromInt(self.total_ops);
        const ns: f64 = @floatFromInt(self.duration.toNanoseconds());
        const seconds = ns / std.time.ns_per_s;
        return if (seconds == 0) 0.0 else ops / seconds;
    }

    pub fn batchesPerSecond(self: Stats) f64 {
        const batches: f64 = @floatFromInt(self.count());
        const ns: f64 = @floatFromInt(self.duration.toNanoseconds());
        const seconds = ns / std.time.ns_per_s;
        if (seconds == 0) return 0.0;
        return batches / seconds;
    }

    /// Count of total batches requested.
    pub fn count(self: Stats) u64 {
        return self.sorted_latencies.items.len;
    }

    pub fn print(self: Stats, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        assert(self.key_size != null);
        assert(self.value_size != null);

        if (self.dataset_keys == 0) {
            try writer.print("Dataset: empty; ", .{});
        } else {
            try writer.print(
                "Dataset: keys={d} key={d}B value={d}B; ",
                .{ self.dataset_keys, self.key_size.?, self.value_size.? },
            );
        }
        if (self.warmup_batches == 0) {
            try writer.print("Warmup: no.\n", .{});
        } else {
            try writer.print("Warmup: {d} batches.\n", .{self.warmup_batches});
        }
        try writer.print(
            "Summary:     {d} operations completed in {f}\n",
            .{ self.total_ops, self.duration },
        );
        try writer.print(
            "             {d:.2} ops/s {d:.2} batches/s throughput\n",
            .{ self.operationsPerSecond(), self.batchesPerSecond() },
        );
        try writer.print(
            "Latencies:   {s:<9} {s:<9} {s:<9} {s:<9} {s:<9} {s:<9}\n",
            .{ "avg", "min", "p50", "p95", "p99", "max" },
        );

        const batch_size = @divFloor(self.total_ops, @max(self.count(), 1));
        try writer.print("batch={d:<6} ", .{batch_size});

        const values = [_]std.Io.Duration{
            self.avg(),
            self.percentile(0.0),
            self.percentile(0.50),
            self.percentile(0.95),
            self.percentile(0.99),
        };

        for (values) |value| {
            var buf: [9]u8 = @splat(' ');
            _ = std.fmt.bufPrint(&buf, "{f}", .{value}) catch unreachable;
            try writer.writeAll(&buf);
            try writer.writeByte(' ');
        }

        try writer.print("{f}\n", .{self.percentile(1.0)});
    }
};

fn createKey(
    self: Benchmark,
    allocator: std.mem.Allocator,
    key_index: u64,
) std.mem.Allocator.Error![]u8 {
    return allocator.print("{d:0>[1]}", .{ key_index, self.config.key_size });
}

fn batchAppendSet(
    self: Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
    key_index: u64,
) std.mem.Allocator.Error!void {
    const key = try self.createKey(allocator, key_index);
    defer allocator.free(key);
    const string_value: []u8 = try allocator.alloc(u8, self.config.value_size);
    defer allocator.free(string_value);
    self.io.random(string_value);
    try batch.set(.from(key), .{ .string = string_value }, .{});
}

fn batchAppendGet(
    self: Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
    key_index: u64,
) std.mem.Allocator.Error!void {
    const key = try self.createKey(allocator, key_index);
    defer allocator.free(key);
    try batch.get(&.{.from(key)}, .{});
}

fn loadDataset(
    self: *Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
) Client.Batch.FlushError!void {
    if (self.config.dataset_keys == 0) return;

    // Dummy batch size always good for loading any dataset.
    const batch_size: u64 = 1024;

    var load_count: u64 = 0;
    var remaining_set: u64 = self.config.dataset_keys;
    while (remaining_set > 0) : (remaining_set -|= batch_size) {
        for (0..@min(remaining_set, batch_size)) |_| {
            try self.batchAppendSet(allocator, batch, load_count);
            load_count += 1;
        }
        _ = try batch.flush(self.io);
    }

    self.dataset_keys = load_count;
}

fn warmup(
    self: Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
) Client.Batch.FlushError!bool {
    if (
    // Warmup should not set keys or make write operations.
    (self.config.test_cmd == .set)
    // Warmup has no sense when we do get-hit test and dataset is empty.
    or (self.config.test_cmd == .@"get-hit" and self.dataset_keys == 0)) {
        // No batches used for warmup.
        return false;
    }

    var op_index: u64 = 0;
    for (0..self.config.warmup_batches) |_| {
        for (0..self.config.batch_size) |_| {
            const key_index = switch (self.config.test_cmd) {
                .@"get-miss" => self.dataset_keys + op_index,
                .@"get-hit" => op_index % self.dataset_keys,
                // Handled earlier.
                .set => unreachable,
            };

            switch (self.config.test_cmd) {
                .@"get-hit",
                .@"get-miss",
                => try self.batchAppendGet(allocator, batch, key_index),
                // Handled earlier.
                .set => unreachable,
            }
            op_index += 1;
        }
        _ = try batch.flush(self.io);
    }

    return true;
}

fn runTest(
    self: *Benchmark,
    allocator: std.mem.Allocator,
    client: *Client,
) Client.Batch.FlushError!Stats {
    var batch = try client.batch(allocator, .{});
    defer batch.deinit();

    var stats: Stats = .empty;
    errdefer stats.deinit(allocator);

    var remaining_ops = self.config.ops_per_client;

    while (remaining_ops > 0) : (remaining_ops -|= self.config.batch_size) {
        // Reserve a unique range of indices for this batch.
        const base_index = self.shared_op_index.fetchAdd(self.config.batch_size, .monotonic);

        for (0..self.config.batch_size) |batch_index| {
            const global_index = base_index + @as(u64, @intCast(batch_index));

            const key_index = switch (self.config.test_cmd) {
                .set, .@"get-miss" => self.dataset_keys + global_index,
                .@"get-hit" => global_index % self.dataset_keys,
            };

            switch (self.config.test_cmd) {
                .@"get-hit",
                .@"get-miss",
                => try self.batchAppendGet(allocator, &batch, key_index),
                .set => try self.batchAppendSet(allocator, &batch, key_index),
            }
        }

        const now: std.Io.Timestamp = .now(self.io, .awake);
        const rvs = try batch.flush(self.io);
        std.mem.doNotOptimizeAway(rvs);
        const elapsed = now.untilNow(self.io, .awake);

        try stats.append(allocator, elapsed, self.config.batch_size);
    }

    return stats;
}
