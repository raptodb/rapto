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
const options = @import("options.zig");
const snap = @import("snap.zig");
const signal = @import("signal.zig");
const utils = @import("utils.zig");
const ree = @import("ree.zig");
const socket = @import("socket.zig");
const cmds = @import("db.zig");

const Zprof = @import("zprof.zig").Zprof;
const Profiler = @import("zprof.zig").Profiler;
const Server = @import("server.zig").Server;
const Client = @import("server.zig").Client;
const Storage = @import("storage.zig").Storage;
const Query = @import("Query.zig");
const ThreadSafeQueue = @import("queue.zig").ThreadSafeQueue;

pub const ServerSessionError = error{
    NoCapacity,
    CorruptedStat,
    ThreadError,
    OpenError,
} || Server.BindError || Storage.LoadError || signal.SignalError || socket.Stream.WriteError;
pub const ResolveError = error{
    MissingTokens,
    TypeOverflow,
    KeyNotFound,
    KeyReplacementExist,
    MismatchType,
    SaveFailed,
    InvalidObject,
    InvalidMetadata,
    NoKeysFound,
    UnknownArgument,
    ExcedeedSpaceLimit,
} || signal.SignalError || Storage.PutError;

var logger: log.Logger = undefined;
var profiler: *Profiler = undefined;
var quit: bool = false;

pub const RaptoConfig = struct {
    // Client is not implemented yet.
    /// Mode of start, could be server or client.
    mode: enum { server, client } = .server,

    /// Name of database.
    name: ?[]const u8 = null,

    /// Directory of database storage.
    db_path: ?[]const u8 = null,

    /// Set verbosity of log output level.
    verbose: log.Level = .noisy,

    /// If enabled, auto-saving is runner
    /// every <delay> with min of <count>.
    save: ?snap.AutosnapConf = null,

    /// IPv4 address for client connection
    /// or server binding.
    addr: ?std.net.Ip4Address = null,

    /// Max database storage capacity. On server launch
    /// will be requested this memory on RAM. If database
    /// storage file is already created omits this
    /// parameter.
    db_size: ?u64 = null,

    /// Deinits config.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name.?);
        allocator.free(self.db_path.?);
    }
};

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
inline fn exitProcedure(storage: *Storage, queue: *ThreadSafeQueue(Query)) void {
    @branchHint(.cold);

    snap.snap(storage, &logger, false) catch {};
    // send quit to main putting null client on queue
    queue.put(storage.allocator, .{}) catch std.process.abort();
}

/// Footer for actions.
fn footerActions(storage: *Storage, queue: *ThreadSafeQueue(Query)) void {
    defer exitProcedure(storage, queue);

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

/// Starts autosnap if it is enalbled.
/// Logs configs about autosnap.
inline fn startAutosnap(storage: *Storage, save_info: ?snap.AutosnapConf, modc: *std.atomic.Value(u64)) !void {
    // if save is enabled, start Auto-snap
    // with configuration
    if (save_info) |*save| {
        const t0 = try utils.spawn(snap.autosnap, .{ storage, &logger, save, modc });
        t0.detach();

        logger.info("Auto-snap enabled with delay={d} count={d}.", .{ save.delay, save.count });
    }
    // if save is not enabled warn
    // to say that Auto-snap is disabled.
    // items will not be saved persistently.
    else logger.warning("Auto-snap disabled.", .{});
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
    try startAutosnap(storage, conf.save, &modc);

    // create queue for queries
    var queue = ThreadSafeQueue(Query){};
    defer queue.deinit(allocator);
    // bind server
    var session = try Server.bind(allocator, &logger, &queue, conf);
    defer session.deinit();
    // listen connections
    const t1 = try utils.spawn(Server.listen, .{&session});
    t1.detach();

    // start handler for actions
    const t2 = try utils.spawn(footerActions, .{ storage, &queue });
    t2.detach();
    // enable footer for server,
    // if conf is set, footer is enabled
    if (!DEBUG_MODE_MEMORY) {
        logger.conf = conf;
        logger.stdout.writeByte('\n') catch unreachable;
    }

    logger.info("Started server addr={}; LISTENING...", .{conf.addr.?});

    // setup db commands with same parameter storage
    const db = cmds{ .storage = storage };
    while (true) {
        // waits a query from shared queue with
        // client handlers, when query is occurred
        // returns task with query and client information
        const task = queue.waitAndPop(allocator);
        if (task.client) |client| {
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
                else => |void_command| blk: {
                    _ = switch (void_command) {
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
                        .SAVE => db.SAVE(&logger),
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
                    exitProcedure(storage, &queue);
                    break;
                },
            };

            const response, const heap_allocated = content catch |err| blk: {
                @branchHint(.unlikely);
                if (err == error.OutOfMemory) return error.OutOfMemory;
                break :blk .{ ree.expandResolveError(err), false };
            };
            defer if (heap_allocated) allocator.free(response);

            client.stream.write(response) catch {};

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
    defer if (DEBUG_MODE_MEMORY) {
        std.debug.assert(!profiler.hasLeaks());
    };

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

    var args = std.process.argsWithAllocator(arenaAllocator) catch signal.OOM();
    errdefer args.deinit();

    var conf = options.parseOptions(arenaAllocator, &args) catch |err| {
        @branchHint(.unlikely);

        const msg = switch (err) {
            error.HelpFlag => return logger.stdout.print("{s}", .{options.usage()}) catch {},
            error.OutOfMemory => signal.OOM(),
            else => ree.expandOptionsError(err),
        };

        logger.critical("Options parser: {s}\n\n{s}", .{ msg, options.usage() });
    };
    args.deinit();
    defer conf.deinit(arenaAllocator);

    // if selected verbose is different than .noisy
    // (previously initialized with it), reinit logger
    if (conf.verbose != .noisy)
        logger = log.Logger.init(arenaAllocator, conf.verbose);

    // select capacity as ALL RAM if size
    // is not specified, else as fixed buffer
    profiler, const allocator, const zprof = if (conf.db_size) |size| blk: {
        const buf: []u8 = arenaAllocator.alloc(u8, size) catch signal.OOM();
        var fba = std.heap.FixedBufferAllocator.init(buf);
        var fbaAllocator = fba.allocator();

        // this allocator is wrapped with tracker Zprof
        const zprof = Zprof.init(&fbaAllocator, DEBUG_MODE_MEMORY) catch signal.OOM();
        break :blk .{ &zprof.profiler, zprof.allocator, zprof };
    } else blk: {
        // this allocator is wrapped with tracker Zprof
        const zprof = Zprof.init(&arenaAllocator, DEBUG_MODE_MEMORY) catch signal.OOM();
        break :blk .{ &zprof.profiler, zprof.allocator, zprof };
    };
    defer zprof.deinit();

    // handle server
    if (conf.mode == .server) {
        @branchHint(.likely);

        defer {
            std.time.sleep(1 * std.time.ns_per_s);
            logger.info("Quitted.", .{});
        }

        logger.info("Rapto {s} is starting.", .{RAPTO_VERSION});
        logger.info("Server db={s} pid={d} addr={}", .{ conf.name.?, std.os.linux.getpid(), conf.addr.? });

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
