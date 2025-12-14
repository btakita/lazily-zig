const std = @import("std");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const subscriber_mod = @import("subscriber.zig");
const Callback = subscriber_mod.Callback;
const SubscriberKey = subscriber_mod.SubscriberId;

/// A mutable container to be used with slots
pub fn Cell(comptime T: type) type {
    return struct {
        ctx: *Context,
        value: T,
        subscribers: std.AutoHashMap(SubscriberKey, void),

        pub fn init(ctx: *Context, initial_value: T) @This() {
            return .{
                .ctx = ctx,
                .value = initial_value,
                .subscribers = std.AutoHashMap(SubscriberKey, void).init(ctx.allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.subscribers.deinit();
        }

        pub fn get(self: *const @This()) T {
            return self.value;
        }

        pub fn set(self: *@This(), new_value: T) void {
            const old = self.value;
            self.value = new_value;

            // Notify after updating (common choice). If you prefer "before",
            var iter = self.subscribers.iterator();
            while (iter.next()) |entry| {
                const id = entry.key_ptr.*;
                const cb: Callback(T) = @ptrFromInt(id.cb_ptr);
                const sub_ctx: *Context = @ptrFromInt(id.ctx_ptr);
                cb(sub_ctx, new_value, old);
            }
        }

        pub fn subscribe(self: *@This(), cb: Callback(T)) !bool {
            const key: SubscriberKey = .{
                .cb_ptr = @intFromPtr(cb),
                .ctx_ptr = @intFromPtr(self.ctx),
            };

            const gop = try self.subscribers.getOrPut(key);
            if (gop.found_existing) return false; // duplicate, not added

            // Value type is void, nothing to store.
            return true; // newly added
        }

        pub fn unsubscribe(self: *@This(), cb: Callback(T)) bool {
            // Remove by swap-remove for O(1) erase (order not preserved).
            const key: SubscriberKey = .{
                .cb_ptr = @intFromPtr(cb),
                .ctx_ptr = @intFromPtr(self.ctx),
            };
            return self.subscribers.remove(key);
        }
    };
}

pub fn cell(comptime T: type) !Cell(T) {}

test "Cell: get/set + subscribe dedup + notify" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    var c = Cell(i32).init(ctx, 1);
    defer c.deinit();

    try std.testing.expectEqual(@as(i32, 1), c.get());

    const TestState = struct {
        var called = std.atomic.Value(usize).init(0);

        fn onChange(_: *Context, _: i32, _: i32) void {
            _ = called.fetchAdd(1, .seq_cst);
        }
    };

    TestState.called.store(0, .seq_cst);

    // First subscription adds, second is rejected as duplicate (same ctx+cb).
    try std.testing.expect(try c.subscribe(TestState.onChange));
    try std.testing.expect(!(try c.subscribe(TestState.onChange)));

    c.set(2);
    try std.testing.expectEqual(@as(i32, 2), c.get());
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));

    // Unsubscribe and ensure no further notifications.
    try std.testing.expect(c.unsubscribe(TestState.onChange));
    c.set(3);
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
}
