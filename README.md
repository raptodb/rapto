<br><br>

<div align="center">
  <img alt="Rapto" src="https://github.com/raptodb/rapto/blob/unstable/assets/rapto-base-logo.png">
</div>

<br><br>

Rapto takes into consideration multiple architectural aspects that differentiate it from traditional in-memory databases. Performance does not derive exclusively from the classic in-memory model, but also from the execution model, protocol, and memory layout that provide these characteristics:

- **Scalability**: The runtime uses a completely single-threaded event-driven architecture based exclusively on `poll`. This linear model avoids synchronization, cache contention, and overhead introduced by threads or context-switching. In addition, memory remains preallocated to maintain predictable and stable behavior even under high workloads.

- **Performance**: For common read and write operations, latencies often remain below ten microseconds. This is possible thanks to the frame-based protocol, aggressive buffer reuse, and the in-memory storage system, designed to favor zero-copy deserialization and minimize allocations during serialization and query execution.

- **Cache-aware**: Memory is managed through a flat hashmap containing key-value pairs with a total size of 16 bytes. The pointer associated with the key encodes the value type directly inside the pointer LSB bits, reducing cache accesses and memory overhead. Although this choice introduces coupling between key and value type, the `Ref` wrapper provides a safe and typed access layer.

- **Flexibility**: Although Rapto maintains a simple and direct key-value model, it also supports structured value types such as `list` and `map`, allowing representation of slightly more complex data without introducing document systems or additional layers.

## For contributors

In addition to Rapto's adoption of [Contributor Covenant](https://www.contributor-covenant.org/), contributors are discouraged from relying on LLMs to generate code or prose. AI-generated code and writing are often repetitive, low-quality, and inconsistent in style, and are frequently submitted without proper supervision or a full understanding by their authors.

## License

Copyright (c) raptodb <br>
Copyright (c) Andrea Vaccaro (President)

The content of this repository is licensed under the [BSD-3-Clause](LICENSE.md) license.
