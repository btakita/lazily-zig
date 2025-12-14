const std = @import("std");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;

pub const SubscriberId = struct {
    cb_ptr: usize, // @intFromPtr(callback)
    ctx_ptr: usize, // @intFromPtr(ctx) or 0 if null
};

pub const SubscriberSet = std.AutoHashMap(SubscriberId, void);

pub fn Callback(comptime T: type) type {
    return *const fn (ctx: *Context, new: T, old: T) void;
}

pub fn Subscriber(comptime T: type) type {
    return struct {
        id: SubscriberId,
        ctx: *Context,
        cb: Callback(T),
    };
}
