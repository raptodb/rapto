<br><br>

<div align="center">
  <img alt="Rapto" src="./assets/rapto-base-logo.png">
</div>

<br><br>

**Rapto** is an in-memory NoSQL database written in Zig, with AOF persistence.

Its creation began as an experimental and completely OSS project. It is not intended to replace existing databases, but rather to demonstrate that a project built around solid architectural decisions, while avoiding unnecessary complexity, can become scalable and efficient software, both in terms of performance and development costs.

## Design

A good way to think about Rapto is as **a hierarchical organization of many small and specialized components**.

The server, protocol, and storage are separated, but the path a query takes through these components remains explicit. This is an important design choice: when a query reaches the server, passes through the protocol, gets processed, and produces a reply. Each part of this path has a precise responsibility and can be observed, measured, and **optimized independently**.

Although Rapto is still an immature project and depends in part on the optimizations provided by Zig, the benchmarks seem to **confirm these claims**:

*\* Benchmarked on WSL2 with Intel Core i7-12700H, server instance with default parameters*
```
Benchmarking test=get-hit with 1 parallel clients...
Dataset: keys=1000000 key=12B value=3B; Warmup: 512 batches.
Summary:     100032 operations completed in 63.198ms
             1582833.15 ops/s 24731.77 batches/s throughput
Latencies:   avg       min       p50       p95       p99       max      
batch=64     40.433us  27.26us   38.381us  51.402us  76.035us  169.563us
```

```
Benchmarking test=get-hit with 512 parallel clients...
Dataset: keys=1000000 key=12B value=3B; Warmup: 512 batches.
Summary:     131072 operations completed in 2.854ms
             45913105.86 ops/s 717392.28 batches/s throughput
Latencies:   avg       min       p50       p95       p99       max      
batch=64     305.556us 27.898us  312.724us 536.43us  764.004us 1.251ms
```

Here, we can see that throughput increases significantly as the number of clients grows. **But the server is entirely single-threaded**. Rather, a larger number of concurrent clients keeps the event loop constantly fed, allowing the server to amortize event handling costs. This occurs because the architecture enabled me to optimize the `epoll`-based event poller **separately and independently**.

This aspect also leads to a very interesting concept regarding how requests work, which we will call [Batch](#quick-start-with-batch).

However, performance is not only related to this, but also to techniques that reduce memory usage and decrease the frequency of allocations, which can be reduced by preallocating and reusing the same buffer for different objects. Rapto reuses the same buffer used to receive requests, process queries, and build the replies to be sent back, reducing cache invalidations and unnecessary allocations.

## Quick start with Batch

We introduce **batch** as an ordered sequence of queries that can be accumulated.

**Batch** is the primitive underlying the Rapto protocol and allows the client to send multiple queries with a single request, amortizing the RTT. It defines a precise contract: **the queries in a batch are indivisible**, so another batch cannot insert itself between them. <br>
**Note**: **"indivisible"** does not mean **"atomic"**. A query failure doesn't trigger a rollback to the previous state or an abort, subsequent queries continue to execute normally. The error will still be caught and returned to the client.

For example, if there are two entries `last_updated_x` and `x`, with two independent queries we can know `x` in correlation with `last_updated_x`. But imagine if another query inserts itself between these two and changes the value of `x`: the state of `x` becomes inconsistent with the old `last_updated_x`.
With a batch, this cannot happen natively:

```zig
// Default address to 127.0.0.1:7286
var client: Client = try .open(io, .{});
defer client.close(io);

var batch = try client.batch(allocator, .{});
defer batch.deinit();

try batch.set(.from("x"), .{ .string = "rapto" }, .{});
// Increment last_updated_x by one.
try batch.add(.from("last_updated_x"), .{ .integer = 1 });

var replies = try batch.flush(io);
while (try replies.next()) |value| assert(value != .@"error");
```

Now that we have introduced **batch**, we can derive from this primitive to structures such as `Cursor`, to perform efficient scans (but potentially inconsistent), and `Lock`, to build operations such as **CAS**.

```zig
try batch.count(.{});
const total_keys = try batch.flushOneExpect(io, .integer);

const cursor = batch.cursor();
var iterator = cursor.keysIterator(
    &.{ .from("engineer:*"), .from("student:*") },
    1024,   // Scan count per iteration.
    @intCast(total_keys), // Max cursor.
);

while (try iterator.next(io)) |keys| {
    // Keys is a List with more features,
    // but for this example we can print it directly.
    std.debug.print("{f}\n", .{keys});
}
```

```zig
// Tries to lock, throwing error.Locked if the selected
// key is already locked by another instance.
var lock = try batch.lock(allocator, io, &.{.from("wallet:01")}, .{});
defer _ = lock.unlock(io) catch {};

const money = blk: {
    try lock.batch.get(&.{.from("wallet:01")}, .{});
    const list = try lock.batch.flushOneExpect(io, .list);
    break :blk list.atExpect(0, .decimal);
};

// At this point, no client can modify "wallet:01".
// `money` has always the same value and
// it can't be modified normally until `unlock()`.
if (money >= taxes) {
    try lock.batch.sub(.from("wallet:01"), .{ .decimal = taxes });
    const reply = try lock.batch.flushOne(io);
    assert(reply != .@"error");
}
```

We could also combine `Cursor` with `Lock`, first locking all the keys and then iterating over them progressively.

## Query model

Queries are contained in a batch, or simply represent a single unit of a request. When sent, **they execute an independent operation on the database**, where a response is expected (even an empty one).

The technical composition of a query is formed primarily by the command and its arguments, and secondarily by **flags**, which modify its behavior. While arguments are command-specific and can include strings and other scalar types standardized in Rapto's data model, such as integer and decimal, flags are generic and handle semantics such as iteration limits, locking principles applicable to write commands, but also simpler behaviors like a `set` with `if_not_exists`.

```zig
try batch.insertItem(
    .from("pending-jobs"),
    .{ .integer = 4496 },
    // When index is not set, insert has behavior of append by default.
    .{ .get = true, .replace = true, .index = 5 },
);
```

However, **commands** describe the object of the operation and are divided into several categories: control commands, such as locking and shutdown, read commands (unaffected by any locks), and write commands.

Most read and write commands are divided based on two types of key lookup: **deterministic and non-deterministic**. **Literal keys**, which are known in advance and used directly to perform operations, are deterministic, because we know the iterative complexity based on the number of keys inserted.

```zig
try batch.get(&.{.from("key:1"), .from("key:2"), .from("key:3")}, .{});
```

On the other hand, **non-deterministic searches** refer to key lookup based on [multi-pattern matching](#multi-pattern-matching): even when iterations can be limited through the iteration-limiting flag, we will never know with certainty which keys were touched, nor whether the number of keys found matches the limit exactly or is lower.

```zig
// Over "user:andrea-vaccaro", deletes also "user:andrea-vaccaro:*".
try batch.delMatching(&.{.from("user:andrea-vaccaro*")}, .{ .limit = .init(100000) });
```

### Multi-pattern matching

In Rapto, multi-pattern matching is a method for **scanning keys using multiple glob patterns simultaneously**, enabling efficient scans and avoiding multiple queries to search for keys with different patterns. For example:

```zig
try batch.countMatching(&.{
    .from("star:HD[0-9]*"),
    .from("planet:20[2-9][0-9]-*"),
    .from("comet:??"),
}, .{});
```

## Getting a client

The current client API is the primary reference for available commands and their behavior today. More clients in other programming languages and a solid documentation is planned when value types and reply model are finalized.

Now, you can fetch current available Zig client with:
```sh
zig fetch --save git+https://github.com/raptodb/rapto
```
Then add it as dependency:
```zig
const rapto = b.dependency("rapto", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("rapto-client", rapto.module("rapto"));
```

But, if you need a client in another programming language, you can create it yourself by following `Client.zig`, `Client/value.zig` and understanding how works "frames" and "pipeline" concept.

### More client examples

```zig
var batch = try client.batch(allocator, .{});
defer batch.deinit();

const store_name = store.name;

try batch.get(&.{
    .join(&.{ store_name, ":name" }),
    .join(&.{ store_name, ":earnings" }),
    .join(&.{ store_name, ":coordinates" }),
}, .{});
const replies = try batch.flush(io);

const name = try replies.atExpect(0, .string);
const earnings = try replies.atExpect(1, .decimal);
const coordinates = try replies.atExpect(2, .point);
```

```zig
var read_batch = try client.batch(allocator, .{});
defer read_batch.deinit();
var write_batch = try client.batch(allocator, .{});
defer write_batch.deinit();

try read_batch.count(.{});
const total_keys = try read_batch.flushOneExpect(io, .integer);

const cursor = read_batch.cursor();
var iterator = cursor.keysIterator(
    &.{.from("service:v1:*")},
    1024,   // Scan count per iteration.
    @intCast(total_keys), // Max cursor.
);

while (try iterator.next(io)) |keys_iter| {
    var keys = keys_iter;
    while (try keys.nextExpect(.string)) |key| {
        const new_key: []u8 = try allocator.alloc(u8, key.len);
        defer allocator.free(new_key);

        _ = std.mem.replace(u8, key, "service:v1", "service:v2", new_key);
        try write_batch.rename(.from(key), .from(new_key), .{});
    }

    _ = try write_batch.flush(io);
}
```

## Persistence

**Rapto** has persistence based on the batches sent. Each batch sent, which may contain even a single query, is serialized directly to the **AOF** together with a timestamp.

This will allow, in the future, once the `inspect` tool is implemented, the AOF to be compacted, modified, analyzed, and its statistics displayed. For now, we can only record and load the AOF, with the ability to load batches up to a given timestamp.

## Build, testing and coverage

To build and run:
```sh
zig build -Doptimize=...
./raptodb help
```
Quick run of server:
```sh
./raptodb server --name myserver
```
To run unit tests:
```sh
zig build test
```

More unit tests will be available. Fuzz testing and integration will also be supported soon.

To generate test coverage report:
```sh
zig build coverage
```

## Run the benchmark yourself

Benchmarks are **not standalone** and require starting a server instance, against which the benchmark will run. By default, `./raptodb benchmark -t set` will connect to the address `127.0.0.1:7286`, but this can be configured through the `--address` flag.

Benchmarks are sufficiently configurable and allow isolated testing by considering preloaded datasets, server warmup, parallel clients, or the size of keys and values. <br>
**Note**: the server's memory will not be cleared after a benchmark test, so **the database must be restarted to clear the memory**.

To learn how to customize benchmarks, simply **run** `./raptodb help` and check the benchmark section or follow these runs:

*\* Benchmarked on WSL2 with Intel Core i7-12700H*
```
> ./raptodb benchmark --test get-hit --dataset-keys 10000000 --ops 10000000
  --value-size 64 --batch-size 1024 --clients 1
Benchmarking test=get-hit with 1 parallel clients...
Dataset: keys=10000000 key=12B value=64B; Warmup: 512 batches.
Summary:     10000384 operations completed in 2.048s
             4882136.67 ops/s 4767.71 batches/s throughput
Latencies:   avg       min       p50       p95       p99       max      
batch=1024   209.744us 185.757us 200.281us 243.925us 397.393us 1.035ms
```
```
> ./raptodb benchmark --test get-miss --dataset-keys 1000000 --ops 1000000
  --key-size 512 --value-size 512 --batch-size 1024 --warmup-batches 8 --clients 1
Benchmarking test=get-miss with 1 parallel clients...
Dataset: empty; Warmup: 8 batches.
Summary:     1000448 operations completed in 280.102ms
             3571721.92 ops/s 3488.01 batches/s throughput
Latencies:   avg       min       p50       p95       p99       max      
batch=1024   286.696us 245.004us 280.869us 339.726us 382.132us 555.327us
```
```
> ./raptodb benchmark --test set --dataset-keys 1000000 --ops 1000000
  --key-size 64 --value-size 64 --batch-size 1024 --clients 1
Benchmarking test=set with 1 parallel clients...
Dataset: keys=1000000 key=64B value=64B; Warmup: no.
Summary:     1000448 operations completed in 321.764ms
             3109252.38 ops/s 3036.38 batches/s throughput
Latencies:   avg       min       p50       p95       p99       max      
batch=1024   329.339us 172.491us 196.63us  651.773us 787.3us   87.874ms
```
```
> ./raptodb benchmark --test set --dataset-keys 100000 --ops 100000
  --value-size 3 --batch-size 1 --clients 128 --warmup-batches 0
Benchmarking test=set with 128 parallel clients...
Dataset: keys=100000 key=12B value=3B; Warmup: no.
Summary:     100096 operations completed in 181.551ms
             551336.83 ops/s 551336.83 batches/s throughput
Latencies:   avg       min       p50       p95       p99       max      
batch=1      163.508us 16.165us  163.81us  285.347us 392.915us 5.433ms
```

## For contributors

Rapto follows the [Contributor Covenant](https://www.contributor-covenant.org/). If you want to contribute, maintaining a clean and strictly idiomatic Zig-style is necessary. Instead, if you don't want to write code, open an issue!

## License

Copyright (c) Andrea Vaccaro <br>
This repository is licensed under [Apache-2.0](LICENSE.md).
