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
        if (args.key_size == 0) return error.KeyTooShort;

        const config: Config = .{
            .address = args.address,
            .clients = args.clients,
            .batch_size = args.batch_size,
            .test_cmd = std.meta.stringToEnum(Config.TestCmd, args.@"test") orelse
                return error.UnsupportedTest,
            .ops_per_client = @divFloor(args.ops, args.clients),
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

    pub const TestCmd = enum { set, get };
};

config: Config,

/// Single threaded or multi threaded Io. Current
/// configuration is affected by config.clients.
io: std.Io,

pub fn run(self: Benchmark, allocator: std.mem.Allocator) !Stats {
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

    {
        const first_client = &clients.items[0];
        var batch = try first_client.batch(allocator, .{});
        defer batch.deinit();
        // After initialization of all clients, we need to load
        // dataset from this configuration.
        // For convenience we can use batch of first client as a guinea pig.
        try self.loadDataset(allocator, &batch);
        // Now we do warmup with the same guinea pig xD
        try self.warmup(allocator, &batch);
    }

    for (clients.items, futures.items) |*client, *future| {
        // We have to call async to avoid error.ConcurrencyUnavailable
        // when `io` is initialized as single-threaded.
        future.* = self.io.async(runTest, .{ self, allocator, client });
    }

    // All stats of clients merged with each other.
    var stats: Stats = .init;

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

    pub const init: Stats = .{
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
        try writer.print("ops={d:<6}   ", .{batch_size});

        const values = [_]std.Io.Duration{
            self.avg(),
            self.percentile(0.0),
            self.percentile(0.50),
            self.percentile(0.95),
            self.percentile(0.99),
        };

        for (values) |value| {
            var buf: [9]u8 = @splat(' ');
            _ = std.fmt.bufPrint(&buf, "{f}", .{value}) catch {};
            try writer.writeAll(&buf);
            try writer.writeByte(' ');
        }

        try writer.print("{f}\n", .{self.percentile(1.0)});
    }
};

fn batchAppendSet(
    self: Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
) std.mem.Allocator.Error!void {
    const key: []u8 = try allocator.alloc(u8, self.config.key_size);
    defer allocator.free(key);
    const string_value: []u8 = try allocator.alloc(u8, self.config.value_size);
    defer allocator.free(string_value);
    self.io.random(key);
    self.io.random(string_value);
    try batch.set(key, .{ .string = string_value }, .{});
}

fn batchAppendGet(
    self: Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
) std.mem.Allocator.Error!void {
    const key: []u8 = try allocator.alloc(u8, self.config.key_size);
    defer allocator.free(key);
    self.io.random(key);
    try batch.get(&.{key}, .{});
}

fn loadDataset(
    self: Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
) Client.Batch.FlushError!void {
    if (self.config.dataset_keys == 0) return;

    var remaining_set: u64 = self.config.dataset_keys;
    while (remaining_set > 0) : (remaining_set -|= 1024) {
        for (0..@min(remaining_set, 1024)) |_| {
            try self.batchAppendSet(allocator, batch);
        }
        _ = try batch.flush(self.io);
    }
}

fn warmup(
    self: Benchmark,
    allocator: std.mem.Allocator,
    batch: *Client.Batch,
) Client.Batch.FlushError!void {
    // Warmup should not set keys or make write operations.
    if (self.config.test_cmd == .set) return;

    for (0..self.config.warmup_batches) |_| {
        for (0..self.config.batch_size) |_| switch (self.config.test_cmd) {
            .get => try self.batchAppendGet(allocator, batch),
            // Handled earlier.
            .set => unreachable,
        };
        _ = try batch.flush(self.io);
    }
}

fn runTest(
    self: Benchmark,
    allocator: std.mem.Allocator,
    client: *Client,
) Client.Batch.FlushError!Stats {
    var batch = try client.batch(allocator, .{});
    defer batch.deinit();

    var stats: Stats = .init;

    var remaining_ops = self.config.ops_per_client;
    while (remaining_ops > 0) : (remaining_ops -|= self.config.batch_size) {
        // Bench always `batch_size` at time, this is not a bug.
        for (0..self.config.batch_size) |_| switch (self.config.test_cmd) {
            .set => try self.batchAppendSet(allocator, &batch),
            .get => try self.batchAppendGet(allocator, &batch),
        };

        const now: std.Io.Timestamp = .now(self.io, .awake);
        const rvs = try batch.flush(self.io);
        std.mem.doNotOptimizeAway(rvs);
        const elapsed = now.untilNow(self.io, .awake);

        try stats.append(allocator, elapsed, self.config.batch_size);
    }

    return stats;
}
