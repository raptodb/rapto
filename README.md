<br><br>

<div align="center">
  <img alt="Rapto" src="https://github.com/raptodb/rapto/blob/unstable/assets/rapto-base-logo.png">
</div>

<br><br>

## The Rapto database

Rapto is an in-memory key-value database with temporal persistent storage. It is designed to ensure speed and simplicity in operations and is used in very specific contexts.

The supported data types are intentionally minimal for reasons of efficiency and purpose and include `integer`, `decimal` and `string`. They are subject to continuous optimization to maximize performance in query operations.

The contexts of use are limited and very specific, such as real-time monitoring, embedded systems, LRU cache.

## The pillars

### 👣 _Footprinting_

Memory is used efficiently for low-space environments, leaving trace and control for each operation.

### ⚡ _Performance_

Performance-oriented, Rapto will be a competition for other databases.

### 📄 _Minimalism_

The key to good code introduces flexibility, simplicity, overall efficiency and documentation.

### 🛡️ _Security_

To ensure security, Zig is the winning candidate for distributed systems.

***These features make Rapto a choice for high-reliability professional contexts, now and in the future.***

## Benchmarks

Valid benchmarks are available through Rapto clients.
Internal tests focusing exclusively on query resolution within the engine have shown latencies in the range of <ins>~3 to ~6 microseconds</ins>. <br>
> [!IMPORTANT]
> However, these results are not publicly verified and should be considered indicative only.

## Documentation

The only official documentation of Rapto resides in the [wiki](https://github.com/raptodb/rapto/wiki) of this repository.
