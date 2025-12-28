const std = @import("std");
const lazily = @import("lazily");

const Context = lazily.Context;
const deinitSlotValue = lazily.deinitSlotValue;
const expectEventLog = lazily.expectEventLog;
const initCellFn = lazily.initCellFn;
const initSlotFn = lazily.initSlotFn;
const OwnedString = lazily.OwnedString;
const slotEventLog = lazily.slotEventLog;
const String = lazily.String;

const hello = initCellFn(String, struct {
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

const name = initCellFn(
    String,
    getName,
    null,
);

const getGreeting = struct {
    fn call(_ctx: *Context) !OwnedString {
        try (try slotEventLog(_ctx)).append("greeting|");

        const greeting_string = std.fmt.allocPrint(
            _ctx.allocator,
            "{s} {s}!",
            .{ (try hello(_ctx)).get(), (try name(_ctx)).get() },
        ) catch unreachable;
        return OwnedString.managed(greeting_string);
    }
}.call;
const greeting = initSlotFn(
    OwnedString,
    getGreeting,
    deinitSlotValue(OwnedString, null),
);

const response = initCellFn(String, struct {
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
const greetingAndResponse = initSlotFn(
    OwnedString,
    getGreetingAndResponse,
    deinitSlotValue(OwnedString, null),
);

test "initCellFn and initSlotFn with dependencies example" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();

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
