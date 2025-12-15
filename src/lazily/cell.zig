const std = @import("std");
const ctx_mod = @import("context.zig");
const ValueCallback = ctx_mod.ValueCallback;
const Context = ctx_mod.Context;
const Owned = ctx_mod.Owned;
const OwnedString = ctx_mod.OwnedString;
const Slot = ctx_mod.Slot;
const String = ctx_mod.String;
const subscriberKey = ctx_mod.subscriberKey;
const SubscriberKey = ctx_mod.SubscriberKey;
const valueFnCacheKey = ctx_mod.valueFnCacheKey;
const ValueFn = ctx_mod.ValueFn;
const slot_mod = @import("slot.zig");
const deinitValue = slot_mod.deinitValue;
const slot = slot_mod.slot;
const initSlotFn = slot_mod.initSlotFn;
const DeinitPayloadFn = Slot.DeinitPayloadFn;

/// A mutable container to be stored as a slot via the cell function
pub fn Cell(comptime T: type) type {
    return struct {
        ctx: *Context,
        value: T,
        subscribers: std.AutoHashMap(SubscriberKey, void),

        pub fn init(ctx: *Context, initial_value: T) @This() {
            return .{
                .ctx = ctx,
                .value = initial_value,
                .subscribers = std.AutoHashMap(
                    SubscriberKey,
                    void,
                ).init(ctx.allocator),
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

            var iter = self.subscribers.iterator();
            while (iter.next()) |entry| {
                const subscriber_key = entry.key_ptr.*;
                const cb: ValueCallback(T) = @ptrFromInt(subscriber_key.cb_ptr);
                const sub_ctx: *Context = @ptrFromInt(subscriber_key.ctx_ptr);
                cb(sub_ctx, new_value, old);
            }
        }

        pub fn subscribe(self: *@This(), cb: ValueCallback(T)) !bool {
            const subscriber_key = subscriberKey(self.ctx, cb);

            const gop = try self.subscribers.getOrPut(subscriber_key);
            if (gop.found_existing) return false; // duplicate, not added

            // Value type is void, nothing to store.
            return true; // newly added
        }

        pub fn unsubscribe(self: *@This(), cb: ValueCallback(T)) bool {
            // Remove by swap-remove for O(1) erase (order not preserved).
            const subscriber_key = subscriberKey(self.ctx, cb);
            return self.subscribers.remove(subscriber_key);
        }
    };
}

test "Cell: subscribe dedup" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    var test_cell = Cell(i32).init(ctx, 1);
    defer test_cell.deinit();

    try std.testing.expectEqual(@as(i32, 1), test_cell.get());

    const TestState = struct {
        var called = std.atomic.Value(usize).init(0);

        fn onChange(_: *Context, _: i32, _: i32) void {
            _ = called.fetchAdd(1, .seq_cst);
        }
    };

    TestState.called.store(0, .seq_cst);

    // First subscription adds, second is rejected as duplicate (same ctx+cb).
    try std.testing.expect(try test_cell.subscribe(TestState.onChange));
    try std.testing.expect(!(try test_cell.subscribe(TestState.onChange)));

    test_cell.set(2);
    try std.testing.expectEqual(@as(i32, 2), test_cell.get());
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));

    // Unsubscribe and ensure no further notifications.
    try std.testing.expect(test_cell.unsubscribe(TestState.onChange));
    test_cell.set(3);
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
}

/// Init a slot that stores the `Cell(T)` with the initial value defined by `valueFn`.
/// `deinit` is called during `Cell.deinit`.
/// `valueFn` and `deinit` must be `comptime` because `cell()` generates a trampoline function
/// (Zig 0.15 has no runtime closures).
/// If you need a runtime `valueFn` or `deinit`, you can create a `slot` that returns a `Cell(T)`.
pub fn cell(
    comptime T: type,
    ctx: *Context,
    comptime valueFn: *const ValueFn(T),
    comptime deinit: ?DeinitPayloadFn,
) !Cell(T) {
    const getCell = struct {
        fn call(_ctx: *Context) anyerror!Cell(T) {
            const initial_value = try slot(T, _ctx, valueFn, deinit);
            return Cell(T).init(_ctx, initial_value);
        }
    }.call;

    // Cache the `Cell(T)` itself. `Slot.destroyInCache` handles deiniting the `Slot`.
    return try slot(Cell(T), ctx, getCell, null);
}

test "cell: returns Cell(T) with initial value and caches computation" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const State = struct {
        var calls = std.atomic.Value(usize).init(0);

        fn getNumber(_: *Context) anyerror!i32 {
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

pub fn CellFn(comptime T: type) type {
    return fn (*Context) anyerror!Cell(T);
}

pub fn cellFn(comptime T: type, comptime valueFn: ValueFn(T), comptime deinit: ?DeinitPayloadFn) *const CellFn(T) {
    return struct {
        fn call(ctx: *Context) anyerror!Cell(T) {
            return cell(T, ctx, valueFn, deinit);
        }
    }.call;
}

test "cellFn: get/set + invalidate cache" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    var test_cell = Cell(i32).init(ctx, 1);
    defer test_cell.deinit();

    try std.testing.expectEqual(@as(i32, 1), test_cell.get());

    const List = std.array_list.Managed(String);

    // Return by value for a mutable copy.
    const slotEvents = comptime initSlotFn(*List, struct {
        fn call(_ctx: *Context) anyerror!*List {
            const list = try _ctx.allocator.create(List);
            list.* = List.init(_ctx.allocator);
            return list;
        }
    }.call, deinitValue(*List, struct {
        fn deinit(_ctx: *Context, valueFn: *const ValueFn(*List), value: *List) void {
            _ = _ctx;
            _ = valueFn;
            value.deinit();
        }
    }.deinit));

    const hello = comptime initSlotFn(Cell(OwnedString), struct {
        fn call(_ctx: *Context) anyerror!Cell(OwnedString) {
            const events = try slotEvents(_ctx);
            try events.append("hello|");
            return Cell(OwnedString).init(_ctx, OwnedString.literal("Hello"));
        }
    }.call, null);

    const name = comptime cellFn(OwnedString, struct {
        fn call(_ctx: *Context) !OwnedString {
            const slot_events = try slotEvents(_ctx);
            try slot_events.append("name|");
            return OwnedString.literal("World");
        }
    }.call, deinitValue(OwnedString, null));

    const getGreeting = struct {
        fn call(_ctx: *Context) !OwnedString {
            const slot_events = try slotEvents(_ctx);
            try slot_events.append("greeting|");
            return OwnedString.managed(
                std.fmt.allocPrint(
                    _ctx.allocator,
                    "{s} {s}!",
                    .{ (try hello(_ctx)).get().value, (try name(_ctx)).get().value },
                ) catch unreachable,
            );
        }
    }.call;
    const greeting = comptime initSlotFn(
        OwnedString,
        getGreeting,
        deinitValue(OwnedString, null),
    );

    const response = comptime cellFn(OwnedString, struct {
        fn call(_ctx: *Context) !OwnedString {
            try (try slotEvents(_ctx)).append("response|");
            return OwnedString.literal("How are you?");
        }
    }.call, deinitValue(OwnedString, null));

    const greetingAndResponse = comptime initSlotFn(OwnedString, struct {
        fn call(_ctx: *Context) !OwnedString {
            try (try slotEvents(_ctx)).append("greetingAndResponse|");
            return OwnedString.managed(
                std.fmt.allocPrint(
                    _ctx.allocator,
                    "{s} {s}",
                    .{ (try greeting(_ctx)).value, (try response(_ctx)).get().value },
                ) catch unreachable,
            );
        }
    }.call, deinitValue(OwnedString, null));

    try std.testing.expectEqual(ctx.cache.get(valueFnCacheKey(getGreeting)), null);
    try std.testing.expectEqual(0, (try slotEvents(ctx)).items.len);
    try std.testing.expectEqualStrings(
        "Hello World!",
        (try greeting(ctx)).value,
    );
    try std.testing.expect(ctx.cache.get(valueFnCacheKey(getGreeting)) != null);
    try struct {
        fn call(_ctx: *Context) !void {
            const joined_items = try std.mem.join(
                _ctx.allocator,
                "",
                (try slotEvents(_ctx)).items,
            );
            defer _ctx.allocator.free(joined_items);
            try std.testing.expectEqualStrings(
                "greeting|hello|name|",
                joined_items,
            );
        }
    }.call(ctx);
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try struct {
        fn call(_ctx: *Context) !void {
            const joined_items = try std.mem.join(
                _ctx.allocator,
                "",
                (try slotEvents(_ctx)).items,
            );
            defer _ctx.allocator.free(joined_items);
            try std.testing.expectEqualStrings(
                "greeting|hello|name|greetingAndResponse|response|",
                joined_items,
            );
        }
    }.call(ctx);
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try struct {
        fn call(_ctx: *Context) !void {
            const joined_items = try std.mem.join(
                _ctx.allocator,
                "",
                (try slotEvents(_ctx)).items,
            );
            defer _ctx.allocator.free(joined_items);
            try std.testing.expectEqualStrings(
                "greeting|hello|name|greetingAndResponse|response|",
                joined_items,
            );
        }
    }.call(ctx);

    var n = try name(ctx);
    n.set(OwnedString.literal("You"));
    try std.testing.expectEqual(
        ctx.cache.get(valueFnCacheKey(getGreeting)),
        null,
    );
    try struct {
        fn call(_ctx: *Context) !void {
            const joined_items = try std.mem.join(
                _ctx.allocator,
                "",
                (try slotEvents(_ctx)).items,
            );
            defer _ctx.allocator.free(joined_items);
            try std.testing.expectEqualStrings(
                "greeting|hello|name|greetingAndResponse|response|",
                joined_items,
            );
        }
    }.call(ctx);
    try std.testing.expectEqualStrings(
        "Hello You! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try struct {
        fn call(_ctx: *Context) !void {
            const joined_items = try std.mem.join(
                _ctx.allocator,
                "",
                (try slotEvents(_ctx)).items,
            );
            defer _ctx.allocator.free(joined_items);
            try std.testing.expectEqualStrings(
                "greeting|hello|name|greetingAndResponse|response|greetingAndResponse|response|greeting|",
                joined_items,
            );
        }
    }.call(ctx);
}
