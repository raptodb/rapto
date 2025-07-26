//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Unofficial "lz4" algorithm bindings in Zig.

const std = @import("std");

extern fn LZ4_compress_default(src: [*]const u8, dst: [*]u8, src_size: c_int, dst_capacity: c_int) c_int;
extern fn LZ4_decompress_safe(src: [*]const u8, dst: [*]u8, compressed_size: c_int, dst_capacity: c_int) c_int;
extern fn LZ4_compressBound(src_size: c_int) c_int;

/// Compresses string with LZ4 algorithm.
pub fn compress(allocator: std.mem.Allocator, noalias src: []const u8) error{OutOfMemory}![]u8 {
    const compr_len = LZ4_compressBound(@as(c_int, @intCast(src.len)));

    const buf: []u8 = try allocator.alloc(u8, @intCast(compr_len));
    errdefer allocator.free(buf);

    const len = LZ4_compress_default(
        src.ptr,
        buf.ptr,
        @intCast(src.len),
        @intCast(buf.len),
    );

    if (compr_len != len) {
        @branchHint(.likely);
        return allocator.realloc(buf, @intCast(len));
    }

    return buf;
}

/// Decompresses string with LZ4 algorithm.
/// It can fail with DecompressionFail error.
/// Allocates 255 times string to ensure max decompression size.
pub fn decompress(allocator: std.mem.Allocator, noalias src: []const u8) error{ OutOfMemory, DecompressionFail }![]u8 {
    // allocates buffer with 1:255 ratio to ensure max decompression safety
    const buf = try allocator.alloc(u8, src.len * 255);
    errdefer allocator.free(buf);

    const len = LZ4_decompress_safe(
        src.ptr,
        buf.ptr,
        @intCast(src.len),
        @intCast(buf.len),
    );

    if (len < 1) {
        @branchHint(.unlikely);
        return error.DecompressionFail;
    }

    return allocator.realloc(buf, @intCast(len));
}

test "compress and decompress" {
    const original = "some test data that should compress and decompress correctly";
    const compressed = try compress(std.testing.allocator, original);
    defer std.testing.allocator.free(compressed);

    const decompressed = try decompress(std.testing.allocator, compressed);
    defer std.testing.allocator.free(decompressed);

    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
