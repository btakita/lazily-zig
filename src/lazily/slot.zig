const std = @import("std");
const ctx_mod = @import("./context.zig");
const Context = ctx_mod.Context;
const DeinitFn = ctx_mod.DeinitFn;
const ContextSlot = ctx_mod.ContextSlot;
const ContextSlotPtr = ctx_mod.ContextSlotPtr;
const DeinitValue = ctx_mod.DeinitValue;
const getSlotStrategy = ctx_mod.getSlotStrategy;
const isSlice = ctx_mod.isSlice;
const sliceValue = ctx_mod.sliceValue;

// Macro-like lazy wrapper using comptime
// TODO: Keep or rename?
pub fn Lazy(comptime T: type) type {
    return struct {
        ctx: *Context,
        compute: *const fn (*Context) T,

        pub fn get(self: @This()) !T {
            return slot(T, self.ctx, self.compute);
        }

        pub fn reset(self: @This()) void {
            const key = @intFromPtr(self.compute_fn);
            // self.ctx.mutex.lock();
            // defer self.ctx.mutex.unlock();

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

pub fn Slot(comptime T: type) type {
    return struct {
        call: *const fn (*Context) anyerror!Computed(T),
        deinit: ?DeinitFn = null,
        pub fn end(self: @This()) *const fn (*Context) anyerror!Computed(T) {
            return struct {
                fn end() *const fn (*Context) anyerror!Computed(T) {
                    return self.value;
                }
            }.end();
        }
    };
}

pub fn slot(
    comptime T: type,
    ctx: *Context,
    compute: *const fn (*Context) anyerror!Computed(T),
) !T {
    const key = @intFromPtr(compute);

    // ctx.mutex.lock();
    // defer ctx.mutex.unlock();

    // Check cache
    if (ctx.cache.get(key)) |lazy_slot| {
        const strategy = comptime getSlotStrategy(T);
        return switch (strategy) {
            .indirect => @as(T, @ptrCast(@alignCast(lazy_slot.ptr.single_ptr))).*,
            .direct => switch (lazy_slot.pointer_size) {
                .slice => blk: {
                    const slice_value = lazy_slot.ptr.slice;
                    const slice: T = @as(
                        [*]std.meta.Elem(T),
                        @ptrCast(@alignCast(slice_value.ptr)),
                    )[0..slice_value.len];
                    break :blk slice;
                },
                .one, .many, .c => @as(T, @ptrCast(@alignCast(lazy_slot.ptr.single_ptr))),
            },
        };
    }

    // Compute value
    // ctx.mutex.unlock();
    const computed = try compute(ctx);
    // ctx.mutex.lock();

    const strategy = comptime getSlotStrategy(T);

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

    const pointer_size = switch (strategy) {
        .direct => @typeInfo(T).pointer.size,
        .indirect => @typeInfo(*T).pointer.size,
    };
    const deinit = switch (strategy) {
        .direct => @as(?DeinitFn, @ptrCast(computed.deinit)),
        .indirect => deinitIndirect(T, computed.deinit),
    };
    const context_slot = ContextSlot{
        .ctx = ctx,
        .ptr = switch (strategy) {
            .direct => switch (pointer_size) {
                .slice => .{ .slice = sliceValue(T, computed.value) },
                .one, .many, .c => .{ .single_ptr = @ptrCast(@constCast(computed.value)) },
            },
            .indirect => blk: {
                const stored = try ctx.allocator.create(T);
                stored.* = computed.value;
                break :blk .{ .single_ptr = @ptrCast(stored) };
            },
        },
        .is_indirect = strategy == .indirect,
        .pointer_size = pointer_size,
        .deinit = deinit,
        .free = if (strategy == .indirect) free else null,
    };
    try ctx.cache.put(key, context_slot);

    return computed.value;
}

pub fn slot2(comptime T: type, ctx: *Context) type {
    return struct {
        ctx: *Context = ctx,
        def: *const fn (*Context) anyerror!T,
        deinit: ?DeinitFn = null,
        pub fn call(self: @This()) !T {
            const key = @intFromPtr(self.def);

            // ctx.mutex.lock();
            // defer ctx.mutex.unlock();

            // Check cache
            if (ctx.cache.get(key)) |lazy_slot| {
                const strategy = comptime getSlotStrategy(T);
                return switch (strategy) {
                    .indirect => @as(T, @ptrCast(@alignCast(lazy_slot.ptr))).*,
                    .direct => @as(T, @ptrCast(@alignCast(lazy_slot.ptr))),
                };
            }

            // Compute value
            // ctx.mutex.unlock();
            const value = try self.def(ctx);
            // ctx.mutex.lock();

            const strategy = comptime getSlotStrategy(T);

            // Create a free function that knows the type T
            // const free: ?*const fn (std.mem.Allocator, *anyopaque) void =
            //     if (strategy == .indirect)
            //         struct {
            //             fn free(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            //                 allocator.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
            //             }
            //         }.free
            //     else
            //         null;

            const context_slot = ContextSlot{
                .ctx = ctx,
                .ptr = switch (strategy) {
                    .direct => @ptrCast(@constCast(value)),
                    .indirect => blk: {
                        const stored = try ctx.allocator.create(T);
                        stored.* = value;
                        break :blk stored;
                    },
                },
                .is_indirect = strategy == .indirect,
                .deinit = blk: {
                    if (self.deinit) |deinitFromUser| {
                        break :blk switch (strategy) {
                            .direct => @as(?DeinitFn, @ptrCast(deinitFromUser)),
                            .indirect => @as(?DeinitFn, @ptrCast(deinitIndirect(T, deinitFromUser))),
                        };
                    } else {
                        break :blk null;
                    }
                },
                // .free = free,
                .free = null,
            };
            try ctx.cache.put(key, context_slot);

            return value.value;
        }
    };
}

fn deinitIndirect(comptime T: type, comptime deinitFromUser: ?DeinitFn) DeinitFn {
    return struct {
        pub fn deinit(ctx: *Context, val: DeinitValue) void {
            if (deinitFromUser) {
                deinitFromUser(ctx, val);
            }

            const strategy = comptime getSlotStrategy(T);
            switch (strategy) {
                .indirect => {
                    ctx.allocator.destroy(
                        @as(
                            *T,
                            @ptrCast(@alignCast(val.single_ptr)),
                        ),
                    );
                },
                .direct => unreachable,
            }
        }
    }.deinit;
}

pub fn deinitValue(comptime T: type) DeinitFn {
    return struct {
        pub fn deinit(ctx: *Context, val: DeinitValue) void {
            const strategy = comptime getSlotStrategy(T);

            switch (strategy) {
                .indirect => {
                    // T is not a pointer, check for deinit method
                    if (comptime @typeInfo(T) == .@"struct" and @hasDecl(T, "deinit")) {
                        // For indirect, val should be single_ptr pointing to T
                        const t_ptr = @as(*T, @ptrCast(@alignCast(val.single_ptr)));
                        t_ptr.deinit();
                    }
                },
                .direct => {
                    // T is a pointer/slice type
                    switch (val) {
                        .single_ptr => |p| {
                            const ptr_val = @as(T, @ptrCast(@alignCast(p)));
                            ctx.allocator.free(ptr_val);
                        },
                        .slice => |sv| {
                            sv.free(ctx.allocator, sv.ptr, sv.len, sv.element_size);
                        },
                    }
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

pub fn Compute(comptime T: type) type {
    return struct {
        call: *const fn (*Context) anyerror!T,
        deinit: ?DeinitFn,
    };
}

pub fn Computed(comptime T: type) type {
    return struct {
        value: T,
        deinit: ?DeinitFn,
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
