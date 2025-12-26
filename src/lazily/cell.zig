const std = @import("std");
const ctx_mod = @import("context.zig");
const Context = ctx_mod.Context;
const currentSlotFor = ctx_mod.currentSlotFor;
const Owned = ctx_mod.Owned;
const OwnedString = ctx_mod.OwnedString;
const Slot = ctx_mod.Slot;
const String = ctx_mod.String;
const subscriberKey = ctx_mod.subscriberKey;
const SubscriberKey = ctx_mod.SubscriberKey;
const ValueFn = ctx_mod.ValueFn;
const valueFnCacheKey = ctx_mod.valueFnCacheKey;
const slot_mod = @import("slot.zig");
const deinitSlotValue = slot_mod.deinitSlotValue;
const slot = slot_mod.slot;
const slotKeyed = slot_mod.slotKeyed;
const initSlotFn = slot_mod.initSlotFn;
const DeinitPayloadFn = Slot.DeinitPayloadFn;
const test_mod = @import("test.zig");
const slotEventLog = test_mod.slotEventLog;
const expectEventLog = test_mod.expectEventLog;

pub fn DeinitCellValueFn(comptime T: type) type {
    return *const fn (*Cell(T)) void;
}
pub fn ChangeCallback(comptime T: type) type {
    return *const fn (*Cell(T)) void;
}

/// A mutable container to be stored as a slot via the cell function
pub fn Cell(comptime T: type) type {
    return struct {
        ctx: *Context,
        slot: *Slot,
        value: T,
        // TODO: Add before_change_subscribers
        change_subscribers: std.AutoHashMap(SubscriberKey, void),
        deinitCellValue: ?DeinitCellValueFn(T),

        pub const MissingCurrentSlotError = error{MissingCurrentSlot};

        pub fn init(
            ctx: *Context,
            comptime valueFn: *const ValueFn(T),
            comptime deinitCellValue: ?DeinitCellValueFn(T),
        ) !*@This() {
            // ) !*const @This() {
            const getCell = struct {
                fn call(_ctx: *Context) anyerror!Cell(T) {
                    const initial_value = try valueFn(_ctx);
                    const maybe_cell_slot = currentSlotFor(_ctx);
                    if (maybe_cell_slot) |cell_slot| {
                        return Cell(T){
                            .ctx = _ctx,
                            .slot = cell_slot,
                            .value = initial_value,
                            .change_subscribers = std.AutoHashMap(
                                SubscriberKey,
                                void,
                            ).init(_ctx.allocator),
                            .deinitCellValue = deinitCellValue,
                        };
                    } else return error.MissingCurrentSlot;
                }
            }.call;
            const self = try slotKeyed(
                Cell(T),
                ctx,
                valueFnCacheKey(valueFn),
                getCell,
                deinitSlotValue(Cell(T), struct {
                    fn deinitValue(
                        _ctx: *Context,
                        _getCell: *const ValueFn(Cell(T)),
                        _cell: Cell(T),
                    ) void {
                        _ = _ctx;
                        _ = _getCell;
                        var mutable_cell = _cell;
                        mutable_cell.deinit();
                    }
                }.deinitValue),
            );
            return self;
        }

        pub fn deinit(self: *@This()) void {
            if (self.deinitCellValue) |deinit_fn| {
                std.debug.print("Cell.deinit#1, deinit_fn={}\n", .{deinit_fn});
                deinit_fn(self);
            }
            self.change_subscribers.deinit();
        }

        pub fn get(self: *const @This()) T {
            return self.value;
        }

        pub fn set(self: *@This(), new_value: T) void {
            self.value = new_value;

            self.slot.emitChange();

            var iter = self.change_subscribers.iterator();
            while (iter.next()) |entry| {
                const subscriber_key = entry.key_ptr.*;
                const cb: ChangeCallback(T) = @ptrFromInt(subscriber_key.cb_ptr);
                cb(self);
            }
        }

        pub fn subscribe(self: *@This(), cb: ChangeCallback(T)) !bool {
            const subscriber_key = subscriberKey(self.ctx, cb);

            const gop = try self.change_subscribers.getOrPut(subscriber_key);
            if (gop.found_existing) return false; // duplicate, not added

            // Value type is void, nothing to store.
            return true; // newly added
        }

        pub fn unsubscribe(self: *@This(), cb: ChangeCallback(T)) bool {
            // Remove by swap-remove for O(1) erase (order not preserved).
            const subscriber_key = subscriberKey(self.ctx, cb);
            return self.change_subscribers.remove(subscriber_key);
        }
    };
}

test "Cell: subscribe dedup" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    var test_cell = try Cell(i32).init(ctx, struct {
        fn call(_ctx: *Context) !i32 {
            _ = _ctx;
            return 1;
        }
    }.call, null);

    try std.testing.expectEqual(@as(i32, 1), test_cell.get());

    const TestState = struct {
        var called = std.atomic.Value(usize).init(0);
        var value = std.atomic.Value(i32).init(-1);

        fn onChange(_cell: *Cell(i32)) void {
            _ = called.fetchAdd(1, .seq_cst);
            _ = value.swap(_cell.get(), .seq_cst);
        }
    };

    TestState.called.store(0, .seq_cst);

    // First subscription adds, second is rejected as duplicate (same ctx+cb).
    try std.testing.expect(try test_cell.subscribe(TestState.onChange));
    try std.testing.expect(!(try test_cell.subscribe(TestState.onChange)));
    try std.testing.expectEqual(@as(i32, -1), TestState.value.load(.seq_cst));

    test_cell.set(2);
    try std.testing.expectEqual(@as(i32, 2), test_cell.get());
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 2), TestState.value.load(.seq_cst));

    // Unsubscribe and ensure no further notifications.
    try std.testing.expect(test_cell.unsubscribe(TestState.onChange));
    test_cell.set(3);
    try std.testing.expectEqual(@as(usize, 1), TestState.called.load(.seq_cst));
    try std.testing.expectEqual(@as(i32, 2), TestState.value.load(.seq_cst));
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
    comptime deinitFn: ?DeinitCellValueFn(T),
) !*Cell(T) {
    if (ctx.getSlot(valueFn)) |cell_slot| {
        return cell_slot.get(Cell(T));
    }
    const _cell = try Cell(T).init(
        ctx,
        valueFn,
        deinitFn,
    );
    return _cell;
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
    return fn (*Context) anyerror!*Cell(T);
}

pub fn initCellFn(
    comptime T: type,
    comptime valueFn: ValueFn(T),
    comptime deinitCellValue: ?DeinitCellValueFn(T),
) *const CellFn(T) {
    return struct {
        fn call(ctx: *Context) anyerror!*Cell(T) {
            return cell(T, ctx, valueFn, deinitCellValue);
        }
    }.call;
}

test "cellFn: get/set + invalidate cache" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

    const hello = comptime initCellFn(String, struct {
        fn call(_ctx: *Context) anyerror!String {
            try (try slotEventLog(_ctx)).append("hello|");
            return "Hello";
        }
    }.call, null);

    const getName = struct {
        fn call(_ctx: *Context) !String {
            try (try slotEventLog(_ctx)).append("name|");
            return "World";
        }
    }.call;

    const name = comptime initCellFn(
        String,
        getName,
        null,
    );

    const getGreeting = struct {
        fn call(_ctx: *Context) !OwnedString {
            try (try slotEventLog(_ctx)).append("greeting|");

            const greeting = std.fmt.allocPrint(
                _ctx.allocator,
                "{s} {s}!",
                .{ (try hello(_ctx)).get(), (try name(_ctx)).get() },
            ) catch unreachable;
            return OwnedString.managed(greeting);
        }
    }.call;
    const greeting = comptime initSlotFn(
        OwnedString,
        getGreeting,
        deinitSlotValue(OwnedString, null),
    );

    const response = comptime initCellFn(String, struct {
        fn call(_ctx: *Context) !String {
            try (try slotEventLog(_ctx)).append("response|");
            return "How are you?";
        }
    }.call, null);

    const getGreetingAndResponse = struct {
        fn call(_ctx: *Context) !OwnedString {
            try (try slotEventLog(_ctx)).append("greetingAndResponse|");
            return OwnedString.managed(
                std.fmt.allocPrint(
                    _ctx.allocator,
                    "{s} {s}",
                    .{ (try greeting(_ctx)).value, (try response(_ctx)).get() },
                ) catch unreachable,
            );
        }
    }.call;
    const greetingAndResponse = comptime initSlotFn(
        OwnedString,
        getGreetingAndResponse,
        deinitSlotValue(OwnedString, null),
    );

    try std.testing.expectEqual(null, ctx.getSlot(getName));
    try std.testing.expectEqual(null, ctx.getSlot(getGreeting));
    try std.testing.expectEqual(null, ctx.getSlot(getGreetingAndResponse));
    try std.testing.expectEqual(0, (try slotEventLog(ctx)).items.len);

    try std.testing.expectEqualStrings(
        "Hello World!",
        (try greeting(ctx)).value,
    );
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expect(ctx.getSlot(getGreeting) != null);
    try std.testing.expectEqual(null, ctx.getSlot(getGreetingAndResponse));

    try expectEventLog(ctx, "greeting|hello|name|");
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expect(ctx.getSlot(getGreeting) != null);
    try std.testing.expect(ctx.getSlot(getGreetingAndResponse) != null);

    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");
    try std.testing.expectEqualStrings(
        "Hello World! How are you?",
        (try greetingAndResponse(ctx)).value,
    );

    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");
    try struct {
        fn call(_ctx: *Context) !void {
            var name_cell = try name(_ctx);
            name_cell.set("You");
            try std.testing.expectEqualStrings("You", name_cell.get());
            try std.testing.expectEqualStrings("You", (try name(_ctx)).get());
        }
    }.call(ctx);
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expectEqual(null, ctx.getSlot(getGreeting));
    try std.testing.expectEqual(null, ctx.getSlot(getGreetingAndResponse));
    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|");

    var greeting_slot = try getGreeting(ctx);
    defer greeting_slot.deinit(ctx);
    try std.testing.expectEqualStrings("Hello You!", greeting_slot.value);

    try std.testing.expectEqualStrings("Hello You!", (try greeting(ctx)).value);

    try std.testing.expectEqualStrings(
        "Hello You! How are you?",
        (try greetingAndResponse(ctx)).value,
    );
    try std.testing.expect(ctx.getSlot(getName) != null);
    try std.testing.expect(ctx.getSlot(getGreeting) != null);
    try std.testing.expect(ctx.getSlot(getGreetingAndResponse) != null);
    try expectEventLog(ctx, "greeting|hello|name|greetingAndResponse|response|greeting|greeting|greetingAndResponse|");
}
