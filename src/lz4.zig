//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Unofficial "lz4" algorithm bindings in Zig.

const std = @import("std");

extern fn LZ4_compress_default(src: [*]const u8, dst: [*]u8, src_size: c_int, dst_capacity: c_int) c_int;
extern fn LZ4_decompress_safe(src: [*]const u8, dst: [*]u8, compressed_size: c_int, dst_capacity: c_int) c_int;
extern fn LZ4_compressBound(src_size: c_int) c_int;

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
    if (compr_len != len)
        return allocator.realloc(buf, @intCast(len));

    return buf;
}

pub fn decompress(allocator: std.mem.Allocator, noalias src: []const u8) error{ OutOfMemory, DecompressionFail }![]u8 {
    // allocate buffer with 1:255 ratio to ensure max decompression safety
    const buf = try allocator.alloc(u8, src.len * 255);
    errdefer allocator.free(buf);

    const len = LZ4_decompress_safe(
        src.ptr,
        buf.ptr,
        @intCast(src.len),
        @intCast(buf.len),
    );
    if (len < 1) return error.DecompressionFail;

    return allocator.realloc(buf, @intCast(len));
}
