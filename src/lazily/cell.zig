const std = @import("std");
const ctx_mod = @import("context.zig");
const subscriber_mod = @import("subscriber.zig");
const slot_mod = @import("slot.zig");

/// A mutable container to be stored as a slot via the cell function
pub fn Cell(comptime T: type) type {
    return struct {
        ctx: *ctx_mod.Context,
        value: T,
        subscribers: std.AutoHashMap(subscriber_mod.SubscriberId, void),

        pub fn init(ctx: *ctx_mod.Context, initial_value: T) @This() {
            return .{
                .ctx = ctx,
                .value = initial_value,
                .subscribers = std.AutoHashMap(subscriber_mod.SubscriberId, void).init(ctx.allocator),
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
                const cb: subscriber_mod.Callback(T) = @ptrFromInt(id.cb_ptr);
                const sub_ctx: *ctx_mod.Context = @ptrFromInt(id.ctx_ptr);
                cb(sub_ctx, new_value, old);
            }
        }

        pub fn subscribe(self: *@This(), cb: subscriber_mod.Callback(T)) !bool {
            const key: subscriber_mod.SubscriberId = .{
                .cb_ptr = @intFromPtr(cb),
                .ctx_ptr = @intFromPtr(self.ctx),
            };

            const gop = try self.subscribers.getOrPut(key);
            if (gop.found_existing) return false; // duplicate, not added

            // Value type is void, nothing to store.
            return true; // newly added
        }

        pub fn unsubscribe(self: *@This(), cb: subscriber_mod.Callback(T)) bool {
            // Remove by swap-remove for O(1) erase (order not preserved).
            const key: subscriber_mod.SubscriberId = .{
                .cb_ptr = @intFromPtr(cb),
                .ctx_ptr = @intFromPtr(self.ctx),
            };
            return self.subscribers.remove(key);
        }
    };
}

test "Cell: get/set + subscribe dedup + notify" {
    const ctx = try ctx_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();

    var c = Cell(i32).init(ctx, 1);
    defer c.deinit();

    try std.testing.expectEqual(@as(i32, 1), c.get());

    const TestState = struct {
        var called = std.atomic.Value(usize).init(0);

        fn onChange(_: *ctx_mod.Context, _: i32, _: i32) void {
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

/// Init a slot that stores the Cell with the initial value defined by getValue.
/// deinit is called when Cell deinits.
pub fn cell(
    comptime T: type,
    ctx: *ctx_mod.Context,
    comptime getValue: *const slot_mod.SlotFn(T),
    comptime deinit: ?ctx_mod.DeinitFn,
) !Cell(T) {
    const getCell = struct {
        fn call(c: *ctx_mod.Context) anyerror!Cell(T) {
            // If you want the Cell to be created from the *slotted* T, use slot() here:
            const initial_value = try slot_mod.slot(T, c, getValue, deinit);
            return Cell(T).init(c, initial_value);
        }
    }.call;

    // Cache the Cell(T) itself. ContextSlot.destroyInCache handles deiniting a slot value.
    return try slot_mod.slot(Cell(T), ctx, getCell, null);
}

test "cell: returns Cell(T) with initial value and caches computation" {
    const ctx = try ctx_mod.Context.init(std.testing.allocator);
    defer ctx.deinit();

    const State = struct {
        var calls = std.atomic.Value(usize).init(0);

        fn getNumber(_: *ctx_mod.Context) anyerror!i32 {
            _ = calls.fetchAdd(1, .seq_cst);
            return 123;
        }
    };

    State.calls.store(0, .seq_cst);

    const c1 = try cell(i32, ctx, State.getNumber, null);
    try std.testing.expectEqual(@as(i32, 123), c1.get());

    const c2 = try cell(i32, ctx, State.getNumber, null);
    try std.testing.expectEqual(@as(i32, 123), c2.get());

    // The slot should compute the value once per Context for the same getter.
    try std.testing.expectEqual(@as(usize, 1), State.calls.load(.seq_cst));
}
