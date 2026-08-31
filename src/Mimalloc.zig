const Mimalloc = @This();

const std = @import("std");

extern fn mi_malloc_aligned(size: usize, alignment: usize) ?*anyopaque;
extern fn mi_expand(p: *anyopaque, new_size: usize) ?*anyopaque;
extern fn mi_realloc_aligned(p: *anyopaque, new_size: usize, alignment: usize) ?*anyopaque;
extern fn mi_free_aligned(p: *anyopaque, alignment: usize) void;

extern fn mi_option_set(option: mi_option_t, value: c_long) void;

const mi_option_t = enum(c_int) {
    mi_option_show_errors,
    mi_option_show_stats,
    mi_option_verbose,

    mi_option_deprecated_eager_commit,
    mi_option_arena_eager_commit,
    mi_option_purge_decommits,
    mi_option_allow_large_os_pages,
    mi_option_reserve_huge_os_pages,
    mi_option_reserve_huge_os_pages_at,
    mi_option_reserve_os_memory,
    mi_option_deprecated_segment_cache,
    mi_option_deprecated_page_reset,
    mi_option_deprecated_abandoned_page_purge,
    mi_option_deprecated_segment_reset,
    mi_option_deprecated_eager_commit_delay,
    mi_option_purge_delay,
    mi_option_use_numa_nodes,
    mi_option_disallow_os_alloc,
    mi_option_os_tag,
    mi_option_max_errors,
    mi_option_max_warnings,
    mi_option_deprecated_max_segment_reclaim,
    mi_option_destroy_on_exit,
    mi_option_arena_reserve,
    mi_option_arena_purge_mult,
    mi_option_deprecated_purge_extend_delay,
    mi_option_disallow_arena_alloc,
    mi_option_retry_on_oom,
    mi_option_deprecated_visit_abandoned,
    mi_option_guarded_min,
    mi_option_guarded_max,
    mi_option_guarded_precise,
    mi_option_guarded_sample_rate,
    mi_option_guarded_sample_seed,
    mi_option_generic_collect,
    mi_option_page_reclaim_on_free,
    mi_option_page_full_retain,
    mi_option_page_max_candidates,
    mi_option_max_vabits,
    mi_option_pagemap_commit,
    mi_option_page_commit_on_demand,
    mi_option_page_max_reclaim,
    mi_option_page_cross_thread_max_reclaim,
    mi_option_allow_thp,
    mi_option_minimal_purge_size,
    mi_option_arena_max_object_size,
    mi_option_arena_is_numa_local,

    _mi_option_last,
};

config: Config,

pub const Config = struct {
    arena_purge_mult: ?c_long = null,
    page_full_retain: ?c_long = null,
};

pub fn allocator(self: Mimalloc) std.mem.Allocator {
    if (self.config.arena_purge_mult) |mult| mi_option_set(.mi_option_arena_purge_mult, mult);
    if (self.config.page_full_retain) |retain| mi_option_set(.mi_option_page_full_retain, retain);
    return .{ .ptr = undefined, .vtable = &vtable };
}

pub const vtable: std.mem.Allocator.VTable = .{
    .alloc = &alloc,
    .remap = &remap,
    .resize = &resize,
    .free = &free,
};

fn alloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const ptr = mi_malloc_aligned(len, alignment.toByteUnits()) orelse return null;
    return @ptrCast(ptr);
}

fn resize(_: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    return mi_expand(memory.ptr, new_len) != null;
}

fn remap(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    const ptr = mi_realloc_aligned(memory.ptr, new_len, alignment.toByteUnits()) orelse return null;
    return @ptrCast(ptr);
}

fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, _: usize) void {
    mi_free_aligned(memory.ptr, alignment.toByteUnits());
}
