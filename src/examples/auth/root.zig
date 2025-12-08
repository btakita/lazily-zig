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

pub fn lazyAuthToken(ctx: *lazily.Context) !Token {
    return try lazily.slot(Token, ctx, getAuthToken, deinitToken);
}

fn getAuthToken2(ctx: *lazily.Context) !lazily.Computed(Token) {
    const token = authenticate();
    const owned = try ctx.allocator.dupe(u8, token);
    return .{
        .value = owned,
        .deinit = deinitToken,
    };
}

pub fn lazyAuthToken2(ctx: *lazily.Context) !Token {
    return try lazily.slot2(Token, ctx, getAuthToken2);
}

export fn lazyAuthTokenFFI(ctx: *lazily.Context) callconv(.c) lazily.StringView {
    const token = lazyAuthToken2(ctx) catch |err| {
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
    try std.testing.expectEqualStrings("very_secret_token", try lazyAuthToken(ctx));
}

test "lazyAuthToken2" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try lazyAuthToken2(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
    try std.testing.expectEqualStrings("very_secret_token", try lazyAuthToken2(ctx));
}
