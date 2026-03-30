//! Copyright 2026 Andrea Vaccaro
//! Licensed under the Apache License, Version 2.0
//! http://www.apache.org/licenses/LICENSE-2.0
//!
//! This file is part of "Rapto".
//! It contains the implementation of response builder and query dispatcher.

const std = @import("std");

const Module = @import("Response/Module.zig");
const Query = @import("Task.zig").Query;
const Response = @This();

allocating: std.Io.Writer.Allocating,

const HeaderType: type = u32;
const header_size = @sizeOf(HeaderType);

pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!Response {
    return .{ .allocating = try .initCapacity(allocator, header_size) };
}

pub fn deinit(self: *Response) void {
    self.allocating.deinit();
}

pub fn process(self: *Response, module: Module, query: *const Query) error{ OutOfMemory, Shutdown }!void {
    self.reset();
    // if dispatch fails, this errdefer clears the buffer,
    // so payloadIsEmpty() returns true and the response
    // is not appended to the reply list
    errdefer self.reset();

    const ctx: Module.Context = .{
        .writer = &self.allocating.writer,
        .query = query,
    };

    try self.dispatch(module, ctx);
    self.writeEndToHeader();
}

fn dispatch(self: *Response, module: Module, ctx: Module.Context) error{ OutOfMemory, Shutdown }!void {
    // writes the response of processed query in
    // a buffer and returns the status of response
    // zig fmt: off
    _ = switch (ctx.query.command) {
        .PING   => module.ping(ctx),
 
        // CRUD operations
        .SET    => module.set(ctx),
        .GET    => module.get(ctx),
        .UPDATE => module.update(ctx),
        .DEL    => module.del(ctx),
 
        .COPY   => module.copy(ctx),
        .RENAME => module.rename(ctx),
        .COUNT  => module.count(ctx),
        .TYPE   => module.type(ctx),
        .LIST   => module.list(ctx),
        .EXIST  => module.exist(ctx),
        .ERASE  => module.erase(ctx),
 
        .DOWN   => return error.Shutdown,
    }
    // if status contains error, warns the database
    // or returns a bad response to the client
    catch |err| switch (err) {
        error.OutOfMemory,
        error.WriteFailed => return error.OutOfMemory,
        
        else => if (!ctx.query.flags.noreply) try self.writeError(err),
    };
    // zig fmt: on

    if (!ctx.query.flags.noreply and self.hasEmptyPayload())
        ctx.writer.writeAll("OK") catch return error.OutOfMemory;
}

pub fn buffered(self: *const Response) []const u8 {
    return self.allocating.written();
}

pub fn hasEmptyPayload(self: *const Response) bool {
    return self.allocating.writer.end == header_size;
}

pub fn writeError(self: *Response, err: anyerror) error{OutOfMemory}!void {
    self.reset();
    return self.allocating.writer.print("ERR={s}", .{@errorName(err)});
}

fn reset(self: *Response) void {
    self.allocating.shrinkRetainingCapacity(header_size);
}

fn writeEndToHeader(self: *Response) void {
    const writer = self.allocating.writer;
    std.mem.writeInt(
        HeaderType,
        writer.buffer[0..header_size],
        @truncate(writer.end),
        .little,
    );
}
