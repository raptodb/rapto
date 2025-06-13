<br><br>

<div align="center">
  <img alt="Rapto" src="https://github.com/raptodb/rapto/blob/unstable/assets/rapto-base-logo.png">
</div>

<br><br>

<p align="center">
  For engineers seeking a fast, memory-efficient data engine, <br>
  <strong>Rapto</strong> provides transposition-heuristic storage, low memory footprint and high-performance querying.
</p>

<br>

## Table of contents

- [Table of contents](#table-of-contents)
- [👁️‍🗨️ Overview](#️️-overview)
- [🧪 The development and use cases](#-the-development-and-use-cases)
- [📊 Benchmarks](#-benchmarks)
- [🚀 Getting started](#-getting-started)
  - [🔗 Dependencies and compatibility](#-dependencies-and-compatibility)
  - [🛠️ How to build](#️-how-to-build)
  - [📚 Documentation](#-documentation)

## 👁️‍🗨️ Overview

This repository is about Rapto server. Clients are put in specific repositories and are divided by language.

## 🧪 The development and use cases

**Rapto** is built on several pillars that set it apart from other data engines.<br> Its core principles are footprinting, speed, minimalism, and security:
<dl>
<dt>Footprinted</dt>
<dd>Memory control is a key component. Memory usage is monitored during each operation to ensure efficient and predictable behavior.</dd>
<dt>Fast</dt>
<dd>Rapto offers competitive latency compared to other in-memory key-value databases, making it suitable for high-performance scenarios.</dd>
<dt>Minimal</dt>
<dd>The code base is small, well-documented, and efficient, prioritizing clarity without compromising capabilities.</dd>
<dt>Secure</dt>
<dd>Written entirely in Zig, Rapto leverages the language's security and reliability features, making it a great candidate for use in distributed systems.</dd>
</dt>
These features make Rapto a choice for high-reliability professional contexts, now and in the future.

## 📊 Benchmarks

Valid benchmarks are available through Rapto clients. <br>
Internal tests focusing exclusively on query resolution within the engine have shown latencies in the range of **~3** to **~6** **microseconds**. <br>
<ins>However, these results are not publicly verified and should be considered indicative only.</ins>

## 🚀 Getting started

This section is about the server building and usage.

### 🔗 Dependencies and compatibility

The only dependencies are `libc` and `lz4`.

Rapto is only compatible with Linux/Unix-like systems.

### 🛠️ How to build

The code is compiled using the Zig build system. Version <ins>0.14.0+</ins> is required.

> [!NOTE]
> Release modes are not included in the build file. In different contexts you can choose the appropriate one.
> For high performance contexts it is recommended to use the `-OReleaseFast` parameter.

Example: `zig build -OReleaseFast`

The result will be a executable `rapto` in zig-out folder.
To use the executable with the various options it is better to consult [/docs/usage](https://github.com/raptodb/rapto/blob/unstable/docs/usage) and [/docs/README.md](https://github.com/raptodb/rapto/blob/unstable/docs/README.md)

Example: `./rapto server --name mydb --db-size 150000 --save 300 100 --addr 127.0.0.1:30000`

### 📚 Documentation

The documentation are provided in [/docs/README.md](https://github.com/raptodb/rapto/blob/unstable/docs/README.md) file.