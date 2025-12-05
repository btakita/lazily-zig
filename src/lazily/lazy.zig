const std = @import("std");
const ctx_mod = @import("./ctx.zig");
const LazyContext = ctx_mod.LazyContext;
const LazySlot = ctx_mod.LazySlot;
const LazySlotStrategy = ctx_mod.LazySlotStrategy;

// Macro-like lazy wrapper using comptime
pub fn Lazy(comptime T: type) type {
    return struct {
        ctx: *LazyContext,
        compute: *const fn (*LazyContext) T,

        pub fn get(self: @This()) !T {
            return lazy(self.ctx, T, self.compute);
        }

        pub fn reset(self: @This()) void {
            const key = @intFromPtr(self.compute_fn);
            self.ctx.mutex.lock();
            defer self.ctx.mutex.unlock();

            if (self.ctx.cache.fetchRemove(key)) |entry| {
                const lazy_slot = entry.value;
                if (lazy_slot.deinit) |deinit| {
                    if (lazy_slot.ptr) |data| {
                        deinit(self.ctx, data);
                    }
                }
            }
        }
    };
}

pub fn lazy(
    comptime T: type,
    ctx: *LazyContext,
    compute: *const fn (*LazyContext) anyerror!LazyComputed(T),
) !T {
    const key = @intFromPtr(compute);

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    // Check cache
    if (ctx.cache.get(key)) |lazy_slot| {
        const strategy = comptime LazySlotStrategy(T);
        return switch (strategy) {
            .indirect => @as(T, @ptrCast(@alignCast(lazy_slot.ptr))).*,
            .direct => @as(T, @ptrCast(@alignCast(lazy_slot.ptr))),
        };
    }

    // Compute value
    ctx.mutex.unlock();
    const computed = try compute(ctx);
    ctx.mutex.lock();

    const strategy = comptime LazySlotStrategy(T);
    const slot = LazySlot(T){
        .ctx = ctx,
        .ptr = switch (strategy) {
            .indirect => blk: {
                const stored = try ctx.allocator.create(T);
                stored.* = computed.value;
                break :blk stored;
            },
            .direct => computed.value,
        },
        .deinit = switch (strategy) {
            .indirect => ptr_deinit_wrapper(T, computed.deinit),
            .direct => computed.deinit,
        },
    };
    try ctx.cache.put(key, slot.to_cache());

    return computed.value;
}

fn ptr_deinit_wrapper(
    comptime T: type,
    comptime user_deinit: *const fn (*LazyContext, T) void,
) *const fn (*LazyContext, T) void {
    return struct {
        pub fn deinit(ctx: *LazyContext, val: T) void {
            user_deinit(ctx, val);

            const strategy = comptime LazySlotStrategy(T);
            switch (strategy) {
                .indirect => {
                    ctx.allocator.destroy(&val);
                },
                .direct => unreachable,
            }
        }
    }.deinit;
}

fn deferred_deinit(ctx: *LazyContext, data: *anyopaque) void {
    ctx.allocator.destroy(data);
}

pub fn deinit_value(comptime T: type) *const fn (*LazyContext, T) void {
    return struct {
        pub fn deinit(ctx: *LazyContext, val: T) void {
            ctx.mutex.lock();
            defer ctx.mutex.unlock();

            const strategy = comptime LazySlotStrategy(T);
            switch (strategy) {
                .indirect => {
                    // T is not a pointer, check for deinit method
                    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
                        val.deinit();
                    }
                },
                .direct => {
                    // T is a pointer/slice type, free the memory
                    ctx.allocator.free(val);
                },
            }
        }
    }.deinit;
}

fn LazyDeferredWrapper(comptime T: type) type {
    return struct {
        value: T,
        deinit: *const fn (*LazyContext, T) void,
        allocator: std.mem.Allocator,
    };
}

pub fn LazyComputed(comptime T: type) type {
    return struct { value: T, deinit: *const fn (*LazyContext, T) void };
}

pub const StringView = extern struct {
    ptr: [*]const u8, // Plain pointer for C ABI compatibility
    len: usize, // Byte length (excluding \0)
    errno: c_uint,
    errmsg: ?[*]const u8,

    pub fn from_slice(slice: []const u8) StringView {
        return StringView{
            .ptr = slice.ptr,
            .len = slice.len,
            .errno = 0,
            .errmsg = &.{},
        };
    }
};
