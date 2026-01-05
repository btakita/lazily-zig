const std = @import("std");
const Context = @import("context.zig").Context;
const ValueFn = @import("context.zig").ValueFn;
const String = @import("context.zig").String;
const deinitSlotValue = @import("slot.zig").deinitSlotValue;
const initSlotFn = @import("slot.zig").initSlotFn;

pub const List = std.array_list.Managed(String);

pub const slotEventLog = initSlotFn(*List, struct {
    fn call(_ctx: *Context) anyerror!*List {
        const list = try _ctx.allocator.create(List);
        list.* = List.init(_ctx.allocator);
        return list;
    }
}.call, deinitSlotValue(*List, struct {
    fn deinit(_ctx: *Context, valueFn: *const ValueFn(*List), value: *List) void {
        _ = valueFn;
        value.deinit();
        _ctx.allocator.destroy(value);
    }
}.deinit));

pub fn expectEventLog(ctx: *Context, expected: String) !void {
    const joined_items = try std.mem.join(
        ctx.allocator,
        "",
        (try slotEventLog(ctx)).items,
    );
    defer ctx.allocator.free(joined_items);
    try std.testing.expectEqualStrings(
        expected,
        joined_items,
    );
}
