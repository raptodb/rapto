### This branch is dedicated to a complete redesign of the entire architecture. The database completely changes its data storage model, task management, and the entire system.
### When this branch is ready to go, it will be merged with `unstable` branch and the documentation and presentation will be changed.

<br><br>

<div align="center">
  <img alt="Rapto" src="https://github.com/raptodb/rapto/blob/unstable/assets/rapto-base-logo.png">
</div>

<br><br>

## The Rapto database

Rapto is an in-memory key-value database with persistent storage. It is designed to ensure speed and simplicity in operations and is used in very specific contexts.

The supported data types are intentionally minimal for reasons of efficiency and purpose and include `integer`, `decimal` and `string`. They are subject to continuous optimization to maximize performance in query operations.

The contexts of use are limited and very specific, such as real-time monitoring, embedded systems, LRU cache. For a general overview, it is recommended to use a few frequently accessed keys.

## The pillars

**🎯 _Quality_** <br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Architecture and code quality ensuring readability and maintainability.

**🛡️ _Security_** <br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Built using trusted, safety-focused languages like Zig.

**👣 _Footprinting_** <br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Memory is used efficiently by tracking it at each operation.

**⚡ _Performance_** <br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Optimized for peak computational and memory efficiency.

**🦾 _Flexibility_** <br>
&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;Introduction of new features without cost and performance regression.

> ***The foundation of all these pillars is the reliability that Rapto is committed to ensuring in professional systems.***

## Benchmarks

Valid benchmarks are available through Rapto clients. <br>
Internal tests focused on query resolution showed latencies in a few microseconds.
> [!IMPORTANT]
> However, these results are not publicly verified and should be considered indicative only.

Benchmarks should be based on <ins>max</ins>, <ins>min</ins> and <ins>avg</ins> statistics based on 2000 epochs of `SET` and `GET` which give a general overview of the performance.

#### Official Rapto clients

| Client                                            | Server version        | Benchmark tested | AVG stats              |
| :------------------------------------------------ | :-------------------: | :--------------: | :--------------------: |
| [zig-rapto](https://github.com/raptodb/zig-rapto) | `v0.1.0` (unreleased) | ✅               | `SET`: 19µs, `GET`:12µs |

## Documentation

The only official documentation of Rapto resides in the [wiki](https://github.com/raptodb/rapto/wiki) of this repository.

## License

Copyright (c) raptodb <br>
Copyright (c) Andrea Vaccaro (President)

The content of this repository is licensed under the [BSD-3-Clause](LICENSE.md) license.
