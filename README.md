<ins>**Currently unstable and incomplete*</ins>

<br><br>

<div align="center">
  <img alt="Rapto" src="https://github.com/raptodb/rapto/blob/unstable/assets/rapto-base-logo.png">
</div>

<br><br>

Rapto takes into consideration multiple architectural aspects that differentiate it from traditional in-memory databases. Performance does not derive exclusively from the classic in-memory model, but also from the execution model, protocol, and memory layout that provide these characteristics:

- **Scalability**: The runtime uses a completely single-threaded event-driven architecture based exclusively on `poll`. This linear model avoids synchronization, cache contention, and overhead introduced by threads or context-switching. In addition, memory remains preallocated to maintain predictable and stable behavior even under high workloads.

- **Performance**: For common read and write operations, latencies often remain below ten microseconds. This is possible thanks to the frame-based protocol, aggressive buffer reuse, and the in-memory storage system, designed to favor zero-copy deserialization and minimize allocations during serialization and query execution.

- **Cache-aware**: Memory is managed through a flat hashmap containing key-value pairs with a total size of 16 bytes. The pointer associated with the key encodes the value type directly inside the pointer LSB bits, reducing cache accesses and memory overhead. Although this choice introduces coupling between key and value type, the `Ref` wrapper provides a safe access layer.

- **Flexibility**: Although Rapto maintains a simple and direct key-value model, it also supports structured value types such as `list` and `map`, allowing representation of slightly more complex data without introducing document systems or additional layers.

## Model

- The limitations introduced by the tagged-pointer key-value pair model led to the creation of only 8 value types, carefully chosen to cover as many use cases as possible. Collection types include `list` and `map`, which can contain scalar values such as `integer`, `decimal`, `string`, `flag`, and `point`.

- The query format is built around the standard [frame-base protocol](https://github.com/raptodb/rapto#frame-based-protocol), making parsing simple, safe, and efficient. Queries are composed of three main components: `command`, `flags`, and `args`. Flags allow commands to modify their behavior without introducing additional command variants, keeping the query model compact and flexible.

- Persistence and AOF replay are available through the `--aof` and `--aof-file` commands with multiple configuration options. Instead of storing traditional snapshots, the AOF appends the exact pipeline received from the client together with its timestamp, used both as a temporal reference and identifier. This allows loading sessions from a specific point in time.

- External AOF management is handled through the `inspect` tool, which provides statistical query analysis, pipeline manipulation, and especially compaction, reducing AOF replay and startup times.

### Frame-based protocol

The standard protocol used is `Frames`, a simple length-prefixed protocol based on iterators for reading and building buffers. The same format is reused across pipelines, queries and collections to keep parsing consistent, allowing zero-copy deserialization and reduce allocation overhead.

## Start

Build the project first: 
```sh
zig build
```
Then:
```sh
./raptodb help
```

## Testing from Source

Unit tests are still in progress with the goal of full coverage. Fuzz tests will be added in the future.

```sh
zig build test
```

## For contributors

In addition to Rapto's adoption of [Contributor Covenant](https://www.contributor-covenant.org/), contributors are discouraged from relying on LLMs to generate code or prose. AI-generated code and writing are often repetitive, low-quality, and inconsistent in style, and are frequently submitted without proper supervision or a full understanding by their authors.

## License

Copyright (c) raptodb <br>
Copyright (c) Andrea Vaccaro

The content of this repository is licensed under the [BSD-3-Clause](LICENSE.md) license.
