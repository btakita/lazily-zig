const std = @import("std");
const lazily = @import("lazily");

const Token = []const u8;

fn authenticate() Token {
    std.debug.print("Authenticating...\n", .{});
    return "very_secret_token";
}

fn getAuthToken(ctx: *lazily.Context) !Token {
    const token = authenticate();
    const owned = try ctx.allocator.dupe(u8, token);
    return owned;
}

pub const lazyAuthToken2 = (lazily.Slot(Token){ .call = struct {
    fn call(ctx: *lazily.Context) !lazily.Computed(Token) {
        const token = authenticate();
        const owned = try ctx.allocator.dupe(u8, token);
        ctx.deinitValue(lazily.deinitValue([]const u8));
        return owned;
    }
}.call }).def();

pub fn lazyAuthToken3(ctx: *lazily.Context) !Token {
    return try lazily.slot2(Token, ctx){ .def = getAuthToken };
}

pub fn lazyAuthToken(ctx: *lazily.Context) !Token {
    return try lazily.slot(Token, ctx, struct {
        fn call(call_ctx: *lazily.Context) !lazily.Computed(Token) {
            const token = authenticate();
            const owned = try call_ctx.allocator.dupe(u8, token);
            return lazily.Computed([]const u8){
                .value = owned,
                .deinit = lazily.deinitValue(Token),
            };
        }
    }.call);
}

export fn lazyAuthTokenFFI(ctx: *lazily.Context) callconv(.c) lazily.StringView {
    const token = lazyAuthToken(ctx) catch |err| {
        return lazily.StringView{
            .ptr = &.{},
            .len = 0,
            .errno = 1,
            .errmsg = @errorName(err).ptr,
        };
    };
    return lazily.StringView.fromSlice(token);
}

test "lazyAuthToken" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try lazyAuthToken(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
}

// test "lazyAuthToken2" {
//     const ctx = lazily.Context.init(std.testing.allocator);
//     const token = try lazyAuthToken3(ctx);
//     try std.testing.expectEqualStrings("very_secret_token", token);
// }
