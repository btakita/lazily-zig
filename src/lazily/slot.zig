const std = @import("std");
const ctx_mod = @import("./context.zig");
const Context = ctx_mod.Context;
const DeinitFn = ctx_mod.DeinitFn;
const Slot = ctx_mod.ContextSlot;
const SlotStrategy = ctx_mod.SlotStrategy;

// Macro-like lazy wrapper using comptime
// TODO: Keep or rename?
pub fn Lazy(comptime T: type) type {
    return struct {
        ctx: *Context,
        compute: *const fn (*Context) T,

        pub fn get(self: @This()) !T {
            return slot(self.ctx, T, self.compute);
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

pub fn slot(
    comptime T: type,
    ctx: *Context,
    compute: *const fn (*Context) anyerror!Computed(T),
) !T {
    const key = @intFromPtr(compute);

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    // Check cache
    if (ctx.cache.get(key)) |lazy_slot| {
        const strategy = comptime SlotStrategy(T);
        return switch (strategy) {
            .indirect => @as(T, @ptrCast(@alignCast(lazy_slot.ptr))).*,
            .direct => @as(T, @ptrCast(@alignCast(lazy_slot.ptr))),
        };
    }

    // Compute value
    ctx.mutex.unlock();
    const computed = try compute(ctx);
    ctx.mutex.lock();

    const strategy = comptime SlotStrategy(T);

    // Create a free function that knows the type T
    const free: ?*const fn (std.mem.Allocator, *anyopaque) void =
        if (strategy == .indirect)
            struct {
                fn free(allocator: std.mem.Allocator, ptr: *anyopaque) void {
                    allocator.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
                }
            }.free
        else
            null;

    const context_slot = Slot{
        .ctx = ctx,
        .ptr = switch (strategy) {
            .direct => @ptrCast(@constCast(computed.value)),
            .indirect => blk: {
                const stored = try ctx.allocator.create(T);
                stored.* = computed.value;
                break :blk stored;
            },
        },
        .is_indirect = strategy == .indirect,
        .deinit = blk: {
            if (computed.deinit) |user_deinit| {
                break :blk switch (strategy) {
                    .direct => @as(DeinitFn, @ptrCast(user_deinit)),
                    .indirect => @as(DeinitFn, @ptrCast(deinitIndirect(T, user_deinit))),
                };
            } else {
                break :blk null;
            }
        },
        .free = free,
    };
    try ctx.cache.put(key, context_slot);

    return computed.value;
}

fn deinitIndirect(
    comptime T: type,
    comptime user_deinit: *const fn (*Context, T) void,
) *const fn (*Context, T) void {
    return struct {
        pub fn deinit(ctx: *Context, val: T) void {
            user_deinit(ctx, val);

            const strategy = comptime SlotStrategy(T);
            switch (strategy) {
                .indirect => {
                    ctx.allocator.destroy(&val);
                },
                .direct => unreachable,
            }
        }
    }.deinit;
}

pub fn deinitValue(comptime T: type) *const fn (*Context, T) void {
    return struct {
        pub fn deinit(ctx: *Context, val: T) void {
            ctx.mutex.lock();
            defer ctx.mutex.unlock();

            const strategy = comptime SlotStrategy(T);
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
        deinit: *const fn (*Context, T) void,
        allocator: std.mem.Allocator,
    };
}

pub fn Computed(comptime T: type) type {
    return struct {
        value: T,
        deinit: ?*const fn (*Context, T) void,
    };
}

pub const StringView = extern struct {
    ptr: [*]const u8, // Plain pointer for C ABI compatibility
    len: usize, // Byte length (excluding \0)
    errno: c_uint,
    errmsg: ?[*]const u8,

    pub fn fromSlice(slice: []const u8) StringView {
        return StringView{
            .ptr = slice.ptr,
            .len = slice.len,
            .errno = 0,
            .errmsg = &.{},
        };
    }
};
