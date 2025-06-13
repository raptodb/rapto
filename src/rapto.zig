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
pub const SEMANTIC_RAPTO_VERSION = std.SemanticVersion.parse(RAPTO_VERSION) catch unreachable;

const std = @import("std");

const log = @import("log.zig");
const options = @import("options.zig");
const snap = @import("snap.zig");
const signal = @import("signal.zig");
const utils = @import("utils.zig");
const ree = @import("ree.zig");
const socket = @import("socket.zig");

const Zprof = @import("zprof.zig").Zprof;
const Profiler = @import("zprof.zig").Profiler;
const Server = @import("server.zig").Server;
const Client = @import("server.zig").Client;
const Storage = @import("storage.zig").Storage;
const Query = @import("Query.zig");
const ThreadSafeQueue = @import("queue.zig").ThreadSafeQueue;

/// Alias of std.Thread.spawn. Just abbreviated and adapted to Rapto.
const spawn = struct {
    fn inner(comptime func: anytype, args: anytype) error{ThreadError}!std.Thread {
        return std.Thread.spawn(.{}, func, args) catch return error.ThreadError;
    }
}.inner;

pub var logger: log.Logger = undefined;
var profiler: *Profiler = undefined;
var quit: bool = false;

pub const RaptoConfig = struct {
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

    /// If enabled, encrypt server-client
    /// traffic with Diffie-Hellman handshake.
    /// It works as TLS without certificates.
    tls: bool = false,

    /// If enabled, client must be
    /// authenticated with a password.
    auth: ?[]const u8 = null,

    /// IPv4 address for client connection
    /// or server binding.
    addr: ?std.net.Ip4Address = null,

    /// Max database storage capacity. On server launch
    /// will be requested this memory on RAM. If database
    /// storage file is already created omits this
    /// parameter.
    db_cap: ?u64 = null,

    /// Deinits config.
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.name.?);
        allocator.free(self.db_path.?);

        if (self.auth) |passwd|
            allocator.free(passwd);
    }
};

/// Opens a file, if does not exist, creates it.
/// Returns `opened` and `std.fs.File`.
fn getStorageFile(path: []const u8) !struct { bool, std.fs.File } {
    return if (std.fs.cwd().openFile(path, .{ .mode = .read_write })) |f|
        .{ true, f }
    else |err| if (err == error.FileNotFound)
        .{ false, try std.fs.cwd().createFile(path, .{ .read = true }) }
    else
        err;
}

/// Loads items from storage file to RAM and prefetching it.
/// Can return count of objects loaded and time elapsed in seconds.
fn loadStorageFile(storage: *Storage) Storage.LoadError!struct { u64, f64 } {
    var elap = std.time.Timer.start() catch unreachable;

    // load items to RAM
    const obj_count = try storage.load();

    // prefetching storage with sorting
    storage.prefetch();

    const since = @as(f64, @floatFromInt(elap.read())) / std.time.ns_per_s;
    return .{ obj_count, since };
}

/// Procedure of normal quitting.
fn exitProcedure(storage: *Storage, queue: *ThreadSafeQueue(Query)) void {
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

pub const ServerSessionError = error{
    NoCapacity,
    CorruptedStat,
    ThreadError,
    OpenError,
} || Server.BindError || Storage.LoadError || signal.SignalError || socket.Stream.WriteError;
fn serverSession(allocator: std.mem.Allocator, conf: *RaptoConfig) ServerSessionError!void {
    // try to get storage file.
    // if does not exist, creates it
    const exist, const storage_file = getStorageFile(conf.db_path.?) catch return error.OpenError;
    defer storage_file.close();

    // check if storage file is already created
    if (exist) {
        const stat = storage_file.stat() catch return error.CorruptedStat;

        // replace database capacity from
        // file size if it is greater.
        conf.db_cap = @max(stat.size, conf.db_cap.?);
    } else if (conf.db_cap == null) {
        // try to remove created file
        std.fs.cwd().deleteFile(conf.db_path.?) catch {};
        return error.NoCapacity;
    }
    // adjust bytes in correlation of item size
    if (conf.db_cap.? == 0) return error.NoCapacity;

    // initialize storage
    var storage = Storage.init(allocator, storage_file, conf.db_cap.?);
    defer storage.deinit();

    // create queue for queries
    var queue = ThreadSafeQueue(Query){};
    defer queue.deinit(allocator);

    // if database exist load items
    // and prefetch from RAM
    if (exist) {
        logger.info("Opened storage file '{s}'. Loading and prefetching have started.", .{conf.db_path.?});

        const obj_count: u64, const since: f64 = try loadStorageFile(&storage);

        logger.info("Loaded and optimized {d} items in {d:.6}s.", .{ obj_count, since });
    }
    // if database not exist do nothing.
    // database is created
    else logger.info("Created storage file '{s}'.", .{conf.db_path.?});

    var modc = std.atomic.Value(u64).init(0);

    // if save is enabled, start Auto-snap
    // with configuration
    if (conf.save) |*save| {
        const t0 = try spawn(snap.autosnap, .{ &storage, &logger, save, &modc });
        t0.detach();

        logger.info("Auto-snap: enabled with delay={d} count={d}.", .{ save.delay, save.count });
    }
    // if save is not enabled warn
    // to say that Auto-snap is disabled.
    // items will not be saved persistently.
    else logger.warning("Auto-snap: disabled.", .{});

    // bind server
    var session = try Server.bind(allocator, &logger, conf.addr.?, &queue, conf);
    defer session.deinit();
    // listen server
    const t1 = try spawn(Server.listen, .{&session});
    t1.detach();

    // start handler for actions
    const t2 = try spawn(footerActions, .{ &storage, &queue });
    t2.detach();
    // enable footer for server,
    // if conf is set, footer is enabled
    if (!DEBUG_MODE_MEMORY) {
        logger.conf = conf;
        logger.stdout.writeByte('\n') catch unreachable;
    }

    logger.info("Started {s} server addr={}; LISTENING...", .{ if (conf.tls) "TLS" else "OPEN", conf.addr.? });

    while (queue.waitAndPop(allocator)) |task| if (task.client) |client| {
        defer task.free(allocator);

        if (utils.advancedCompare(task.command, "DOWN")) {
            @branchHint(.cold);
            exitProcedure(&storage, &queue);
            break;
        }

        const resp, const is_heap = task.resolve(
            &storage,
            &logger,
            profiler,
        ) catch |err| .{ ree.expandResolveError(err), false };
        defer if (is_heap) allocator.free(resp);

        if (client.tls_stream) |*tls| {
            // send response with encryption.
            // this increases the latency
            try tls.write(allocator, resp);
        }
        // if TLS is disabled,
        // send response without encryption
        else try client.stream.write(resp);

        // increment counter of storage modifies
        if (conf.save != null)
            _ = modc.fetchAdd(1, .seq_cst);
    }
    // if client is null,
    // quit is detected
    else break;
}

pub fn main() void {
    // start handler for signals
    signal.hsignal();

    // using ArenaAllocator with parent allocator c_allocator
    // is the best combination for fast alloc/dealloc of small
    // and medium objects.
    var arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer arena.deinit();
    var arenaAllocator = arena.allocator();

    // this allocator is wrapped with tracker Zprof
    const zprof = Zprof.init(&arenaAllocator, DEBUG_MODE_MEMORY) catch signal.OOM();
    profiler = &zprof.profiler;
    const allocator = zprof.allocator;

    // setting raw term and reset on exit
    const old_termios = signal.toRawTermios();
    defer _ = std.c.tcsetattr(0, .FLUSH, &old_termios);

    // get logger with max level of verbosity
    logger = log.Logger.init(allocator, .noisy);

    var args = std.process.argsWithAllocator(allocator) catch signal.OOM();
    errdefer args.deinit();

    var conf = options.parseOptions(allocator, &args) catch |err| {
        const msg = if (err == error.OutOfMemory) {
            @branchHint(.unlikely);
            signal.OOM();
        } else ree.expandOptionsError(err);

        logger.critical("Options parser: {s}\n\n{s}", .{ msg, options.usage() });
    };
    args.deinit();
    defer conf.deinit(allocator);

    // if selected verbose is different than .noisy
    // (previously initialized with it), reinit logger
    if (conf.verbose != .noisy)
        logger = log.Logger.init(allocator, conf.verbose);

    // handle server
    if (conf.mode == .server) {
        defer {
            std.time.sleep(1 * std.time.ns_per_s);
            logger.info("Quitted.", .{});
        }

        logger.info("Rapto {s} is starting.", .{RAPTO_VERSION});
        logger.info("Server db={s} pid={d} addr={}", .{conf.name.?, std.os.linux.getpid(), conf.addr.?});

        serverSession(allocator, &conf) catch |err| {
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

    if (DEBUG_MODE_MEMORY) {
        // check memory leak,
        // 53 bytes will be freed
        // out of this branch.
        std.debug.assert(profiler.live_bytes == 53);
    }
}
