//! BSD 3-Clause License
//!
//! Copyright (c) raptodb
//! Copyright (c) Andrea Vaccaro
//! All rights reserved.
//!
//! Redistribution and use in source and binary forms, with or without
//! modification, are permitted provided that the following conditions are met:
//!
//! 1. Redistributions of source code must retain the above copyright notice, this
//!    list of conditions and the following disclaimer.
//!
//! 2. Redistributions in binary form must reproduce the above copyright notice,
//!    this list of conditions and the following disclaimer in the documentation
//!    and/or other materials provided with the distribution.
//!
//! 3. Neither the name of the copyright holder nor the names of its
//!    contributors may be used to endorse or promote products derived from
//!    this software without specific prior written permission.
//!
//! THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//! AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//! IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
//! DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
//! FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
//! DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
//! SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//! CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
//! OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
//! OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//!
//! This file is part of "Rapto".
//! It contains the implementation of main.

const DEBUG_MODE_MEMORY = false;

pub const RAPTO_VERSION = "0.1.0";

const std = @import("std");

const log = @import("log.zig");
const snap = @import("snap.zig");
const signal = @import("signal.zig");
const options = @import("options.zig");
const utils = @import("utils.zig");
const ree = @import("ree.zig");
const cmds = @import("db.zig");

const RaptoConfig = options.RaptoConfig;
const Zprof = @import("zprof.zig").Zprof;
const Profiler = @import("zprof.zig").Profiler;
const Server = @import("server.zig").Server;
const Storage = @import("storage.zig").Storage;
const Query = @import("query.zig").Query;
const AtomicCell = @import("atomic_cell.zig").AtomicCell;

pub const ServerSessionError = Server.BindError || Storage.LoadError || error{
    NoCapacity,
    CorruptedStat,
    ThreadError,
    OpenError,
    OutOfMemory,
};
pub const ResolveError = Storage.PutError || error{
    MissingTokens,
    TypeOverflow,
    KeyNotFound,
    KeyReplacementExist,
    MismatchType,
    SaveFailed,
    InvalidMetadata,
    WriteFailed,
    ReadFailed,
    EndOfStream,
    UnsupportedType,
    NoKeysFound,
    UnknownArgument,
    NoPersistence,
    OutOfMemory,
};

var logger: log.Logger = undefined;
var profiler: *Profiler = undefined;
var quit: bool = false;

/// Opens a file, if does not exist, creates it.
/// After, if file exist loads and prefetchs items to RAM.
/// Returns capacity of storage and `std.fs.File`.
inline fn getStorage(allocator: std.mem.Allocator, conf: *RaptoConfig) !*Storage {
    var exist: bool = true;

    const file: std.fs.File = if (std.fs.cwd().openFile(conf.db_path.?, .{ .mode = .read_write })) |f| blk: {
        const stat = f.stat() catch return error.CorruptedStat;

        // replace database capacity from
        // file size if it is greater.
        // if size is not specified, Rapto uses
        // all RAM possible
        if (conf.db_size) |size| {
            conf.db_size = @max(stat.size, size);
            if (conf.db_size == 0) return error.NoCapacity;
        }

        break :blk f;
    } else |err| if (err == error.FileNotFound) blk: {
        exist = false;
        break :blk std.fs.cwd().createFile(conf.db_path.?, .{ .read = true }) catch return error.OpenError;
    } else return error.OpenError;

    if (conf.db_size) |size|
        logger.info("Storage size={d} file='{s}'", .{ size, conf.db_path.? })
    else
        logger.info("Storage size=ALLRAM file='{s}'", .{conf.db_path.?});

    // initialize storage
    var storage = Storage.init(allocator, file, conf);

    // if database exist load items
    // and prefetch from RAM
    if (exist) {
        logger.info("Opened storage file. Loading and prefetching have started.", .{});

        var elap = std.time.Timer.start() catch unreachable;

        // load items to RAM
        const obj_count = try storage.load();
        // prefetching storage with sorting
        storage.prefetch();

        const since = @as(f64, @floatFromInt(elap.read())) / std.time.ns_per_s;

        if (obj_count == 0)
            logger.info("No items to load.", .{})
        else
            logger.info("Loaded {d} items in {d:.6}s.", .{ obj_count, since });
    }
    // if database not exist do nothing.
    // database is created
    else logger.info("Created storage file '{s}'.", .{conf.db_path.?});

    return &storage;
}

/// Procedure of normal quitting.
fn exitProcedure(storage: *Storage, cell: *AtomicCell(Query)) void {
    @branchHint(.cold);

    snap.snap(storage, &logger, false) catch {};
    // send quit to main putting null client on cell
    cell.waitAndPut(.{});
}

/// Footer for actions.
fn footerActions(storage: *Storage, cell: *AtomicCell(Query)) void {
    defer exitProcedure(storage, cell);

    var c: [1]u8 = undefined;
    while (true) {
        const status = std.c.read(0, &c, 1);
        if (status < 1) continue;

        switch (c[0]) {
            'q', 'Q' => return,
            's', 'S' => snap.snap(storage, &logger, false) catch continue,
            else => {},
        }
    }
}

fn serverSession(allocator: std.mem.Allocator, conf: *RaptoConfig) ServerSessionError!void {
    // try to get storage file and compute capacity.
    // if does not exist, creates it
    const storage = try getStorage(allocator, conf);
    defer {
        storage.file.close();
        storage.deinit();
    }

    var modc = std.atomic.Value(u64).init(0);
    // if autosnap is enabled starts
    // thread with auto save config
    try snap.startAutosnap(storage, &logger, conf.save, &modc);

    // create thread-safe cell to share queries
    var cell: AtomicCell(Query) = .{};

    // bind server
    var session = try Server.bind(allocator, &logger, &cell, conf);
    defer session.deinit();
    // listen connections
    const t1 = try utils.spawn(Server.listen, .{&session});
    t1.detach();

    // start handler for actions
    const t2 = try utils.spawn(footerActions, .{ storage, &cell });
    t2.detach();
    // enable footer for server,
    // if conf is set, footer is enabled
    if (!DEBUG_MODE_MEMORY) {
        logger.conf = conf;
        logger.stdout.interface.writeByte('\n') catch unreachable;
    }

    logger.info("Started server addr={f}; LISTENING...", .{conf.addr.?});

    // setup db commands with same parameter storage
    const db: cmds = .{ .storage = storage };
    while (true) {
        // waits a query from shared cell with
        // client handlers, when query is occurred
        // returns task with query and client information
        const task = cell.waitAndGet();
        if (task.client) |client| {
            @branchHint(.likely);
            defer allocator.free(task.raw_query);

            // this block resolves query and returns response with
            // bool which indicates whether the response
            // was allocated in the heap.
            const content: ResolveError!struct { []const u8, bool } = switch (task.command) {
                // testing commands
                .PING => .{ "pong", false },

                // commands with string return type
                .GET => db.GET(task.args),
                .TYPE => db.TYPE(task.args),
                .CHECK => db.CHECK(task.args),
                .COUNT => db.COUNT(),
                .LIST => db.LIST(),
                .FREQ => db.FREQ(task.args),
                .LAST => db.LAST(task.args),
                .IDLE => db.IDLE(task.args),
                .LEN => db.LEN(task.args),
                .SIZE => db.SIZE(task.args),
                .MEM => db.MEM(profiler, task.args),
                .DB => db.DB(task.args),
                .DUMP => db.DUMP(task.args),

                // commands with void return type
                else => blk: {
                    _ = switch (task.command) {
                        .SET => db.SET(task.args),
                        .UPDATE => db.UPDATE(task.args),
                        .RENAME => db.RENAME(task.args),
                        .TOUCH => db.TOUCH(task.args),
                        .HEAD => db.HEAD(task.args),
                        .TAIL => db.TAIL(task.args),
                        .SHEAD => db.SHEAD(task.args),
                        .STAIL => db.STAIL(task.args),
                        .SORT => db.SORT(),
                        .RESTORE => db.RESTORE(task.args),
                        .ERASE => db.ERASE(),
                        .DEL => db.DEL(task.args),
                        .SAVE => if (conf.no_persistence) error.NoPersistence else db.SAVE(&logger),
                        .COPY => db.COPY(task.args),

                        // all handled
                        else => unreachable,
                    } catch |err| break :blk err;

                    // default response for void
                    // return type commands
                    break :blk .{ "OK", false };
                },

                // shutdowns the server
                .DOWN => {
                    exitProcedure(storage, &cell);
                    break;
                },
            };

            const response, const heap_allocated = content catch |err| blk: {
                @branchHint(.unlikely);
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk .{ ree.expandResolveError(err), false },
                }
            };
            defer if (heap_allocated) allocator.free(response);

            // sends the response to client
            client.send(response) catch {};

            // increment counter of storage modifies
            if (conf.save != null)
                _ = modc.fetchAdd(1, .seq_cst);
        }
        // if client is null,
        // quit is detected
        else break;
    }
}

pub fn main() void {
    // check memory leaks
    defer if (DEBUG_MODE_MEMORY)
        std.debug.assert(!profiler.hasLeaks());

    // start handler for signals
    signal.hsignal();

    // using ArenaAllocator with parent allocator c_allocator
    // is the best combination for fast alloc/dealloc of small
    // and medium objects.
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    var arenaAllocator = arena.allocator();

    // setting raw term and reset on exit
    const old_termios = signal.toRawTermios();
    defer _ = std.c.tcsetattr(0, .FLUSH, &old_termios);

    // get logger with max level of verbosity
    logger = log.Logger.init(arenaAllocator, .noisy);

    var conf = RaptoConfig.parseFromArgs(arenaAllocator) catch |err| {
        @branchHint(.unlikely);

        const msg = switch (err) {
            error.HelpFlag => return logger.stdout.interface.print("{s}", .{options.usage()}) catch {},
            error.OutOfMemory => signal.OOM(),
            else => ree.expandOptionsError(err),
        };

        logger.critical("Options parser: {s}\n\n{s}", .{ msg, options.usage() });
    };
    defer conf.deinit(arenaAllocator);

    // if selected verbose is different than .noisy
    // (previously initialized with it), reinit logger
    if (conf.verbose != .noisy)
        logger = log.Logger.init(arenaAllocator, conf.verbose);

    // select capacity as ALL RAM if size
    // is not specified, else as fixed buffer
    const zprof = if (conf.db_size) |size| blk: {
        const buf: []u8 = arenaAllocator.alloc(u8, size) catch signal.OOM();
        var fba = std.heap.FixedBufferAllocator.init(buf);
        var fbaAllocator = fba.allocator();

        // this allocator is wrapped with tracker Zprof
        break :blk Zprof(true).init(&fbaAllocator, null) catch signal.OOM();
    } else Zprof(true).init(&arenaAllocator, null) catch signal.OOM();
    defer zprof.deinit();

    profiler = &zprof.profiler;
    const allocator = zprof.allocator;

    // handle server
    if (conf.mode == .server) {
        @branchHint(.likely);

        defer {
            std.Thread.sleep(1 * std.time.ns_per_s);
            logger.info("Quitted.", .{});
        }

        logger.info("Rapto {s} is starting.", .{RAPTO_VERSION});
        logger.info("Server db={s} pid={d} addr={f}", .{ conf.name.?, std.os.linux.getpid(), conf.addr.? });

        serverSession(allocator, &conf) catch |err| {
            @branchHint(.unlikely);

            const msg = switch (err) {
                error.OutOfMemory => signal.OOM(),
                else => ree.expandServerSessionError(err),
            };

            logger.critical("{s}", .{msg});
        };
    }

    // TODO: client-cli mode for testing,
    // requires silent verbose

    // already handled with error
    // on options parser
    else unreachable;
}

test "reftest" {
    _ = std.testing.refAllDeclsRecursive(@This());
}
