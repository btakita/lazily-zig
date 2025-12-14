const std = @import("std");
const lazily = @import("lazily");

const Token = []const u8;

fn authenticate() Token {
    std.debug.print("Authenticating...\n", .{});
    return "very_secret_token";
}

const deinitToken = lazily.deinitValue(Token);

fn getAuthToken(ctx: *lazily.Context) !Token {
    const token = authenticate();
    const owned = try ctx.allocator.dupe(u8, token);
    return owned;
}

// Lazily get an Auth Token using the lazily.slot function.
// Which accepts separate value getter function and optional deinit functions.
pub fn slotAuthToken(ctx: *lazily.Context) !Token {
    return try lazily.slot(Token, ctx, getAuthToken, deinitToken);
}

fn getAuthToken2(ctx: *lazily.Context) !lazily.WithDeinit(Token) {
    const token = authenticate();
    const owned = try ctx.allocator.dupe(u8, token);
    return .{
        .value = owned,
        .deinit = deinitToken,
    };
}

// Lazily get an Auth Token using the lazily.slotWithDeinit function.
// Which accepts a getter function for a lazily.WithDeinit(T) struct that holds the value and optional deinit functions.
pub fn slotAuthToken2(ctx: *lazily.Context) !Token {
    return try lazily.slotWithDeinit(Token, ctx, getAuthToken2);
}

pub const slotAuthToken_slotFn = lazily.slotFn(
    Token,
    getAuthToken,
    deinitToken,
);

export fn slotAuthTokenFFI(ctx: *lazily.Context) callconv(.c) lazily.StringView {
    const token = slotAuthToken2(ctx) catch |err| {
        return lazily.StringView{
            .ptr = &.{},
            .len = 0,
            .errno = 1,
            .errmsg = @errorName(err).ptr,
        };
    };
    return lazily.StringView.fromSlice(token);
}

test "slotAuthToken" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthToken(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
    try std.testing.expectEqualStrings("very_secret_token", try slotAuthToken(ctx));
}

test "slotAuthToken2" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthToken2(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
    try std.testing.expectEqualStrings("very_secret_token", try slotAuthToken2(ctx));
}

test "slotFn (slotAuthToken_slotFn)" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthToken_slotFn(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
    try std.testing.expectEqualStrings("very_secret_token", try slotAuthToken_slotFn(ctx));
}
