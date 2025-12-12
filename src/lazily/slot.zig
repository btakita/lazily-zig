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

pub fn SlotFn(comptime T: type) type {
    return fn (*Context) anyerror!T;
}

pub fn slotFn(comptime T: type, comptime getValue: *const SlotFn(T), comptime deinit: ?DeinitFn) *const SlotFn(T) {
    return struct {
        fn call(ctx: *Context) anyerror!T {
            return slot(T, ctx, getValue, deinit);
        }
    }.call;
}

// Accepts a separate value getter function and optional deinit function.
// See slotWithDeinit or slotFn for alternative apis.
pub fn slot(
    comptime T: type,
    ctx: *Context,
    getValue: *const SlotFn(T),
    deinit: ?DeinitFn,
) !T {
    const key = @intFromPtr(getValue);

    // ctx.mutex.lock();
    // defer ctx.mutex.unlock();

    // Check cache
    if (ctx.cache.get(key)) |context_slot| {
        const strategy = comptime getSlotStrategy(T);
        return switch (strategy) {
            .direct => switch (context_slot.pointer_size) {
                .slice => blk: {
                    const slice_value = context_slot.ptr.slice;
                    const slice: T = @as(
                        [*]std.meta.Elem(T),
                        @ptrCast(@alignCast(slice_value.ptr)),
                    )[0..slice_value.len];
                    break :blk slice;
                },
                .one, .many, .c => @as(T, @ptrCast(@alignCast(context_slot.ptr.single_ptr))),
            },
            .indirect => @as(*T, @ptrCast(@alignCast(context_slot.ptr.single_ptr))).*,
        };
    }

    // Compute value
    const value = try getValue(ctx);

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
    const context_slot = ContextSlot{
        .ctx = ctx,
        .ptr = switch (strategy) {
            .direct => switch (pointer_size) {
                .slice => .{ .slice = sliceValue(T, value) },
                .one, .many, .c => .{ .single_ptr = @ptrCast(@constCast(value)) },
            },
            .indirect => blk: {
                const stored = try ctx.allocator.create(T);
                stored.* = value;
                break :blk .{ .single_ptr = @ptrCast(stored) };
            },
        },
        .is_indirect = strategy == .indirect,
        .pointer_size = pointer_size,
        .deinit = deinit,
        .free = if (strategy == .indirect) free else null,
    };
    try ctx.cache.put(key, context_slot);

    return value;
}

pub fn WithDeinitFn(comptime T: type) type {
    return *const fn (*Context) anyerror!WithDeinit(T);
}

pub fn WithDeinit(comptime T: type) type {
    return struct {
        value: T,
        deinit: ?DeinitFn,
    };
}

// Accepts a getter function for a lazily.WithDeinit struct that holds the value and optional deinit functions.
// See slot or slotFn for alternative apis.
pub fn slotWithDeinit(
    comptime T: type,
    ctx: *Context,
    withDeinitFn: WithDeinitFn(T),
) !T {
    const key = @intFromPtr(withDeinitFn);

    // ctx.mutex.lock();
    // defer ctx.mutex.unlock();

    // Check cache
    if (ctx.cache.get(key)) |context_slot| {
        const strategy = comptime getSlotStrategy(T);
        return switch (strategy) {
            .direct => switch (context_slot.pointer_size) {
                .slice => blk: {
                    const slice_value = context_slot.ptr.slice;
                    const slice: T = @as(
                        [*]std.meta.Elem(T),
                        @ptrCast(@alignCast(slice_value.ptr)),
                    )[0..slice_value.len];
                    break :blk slice;
                },
                .one, .many, .c => @as(T, @ptrCast(@alignCast(context_slot.ptr.single_ptr))),
            },
            .indirect => @as(*T, @ptrCast(@alignCast(context_slot.ptr.single_ptr))).*,
        };
    }

    // Compute value
    const with_deinit = try withDeinitFn(ctx);

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
        .direct => @as(?DeinitFn, @ptrCast(with_deinit.deinit)),
        .indirect => deinitIndirect(T, with_deinit.deinit),
    };
    const context_slot = ContextSlot{
        .ctx = ctx,
        .ptr = switch (strategy) {
            .direct => switch (pointer_size) {
                .slice => .{ .slice = sliceValue(T, with_deinit.value) },
                .one, .many, .c => .{ .single_ptr = @ptrCast(@constCast(with_deinit.value)) },
            },
            .indirect => blk: {
                const stored = try ctx.allocator.create(T);
                stored.* = with_deinit.value;
                break :blk .{ .single_ptr = @ptrCast(stored) };
            },
        },
        .is_indirect = strategy == .indirect,
        .pointer_size = pointer_size,
        .deinit = deinit,
        .free = if (strategy == .indirect) free else null,
    };
    try ctx.cache.put(key, context_slot);

    return with_deinit.value;
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

test "Context.init, slotFn, Context.getContextSlot, Context.deinit" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const getFoo = struct {
        fn call(_: *Context) !u8 {
            return 1;
        }
    }.call;
    const lazyFoo = slotFn(u8, getFoo, null);

    try std.testing.expectEqual(null, ctx.getContextSlot(getFoo));
    try std.testing.expectEqual(1, lazyFoo(ctx));
    try std.testing.expect(ctx.getContextSlot(getFoo) != null);
}
