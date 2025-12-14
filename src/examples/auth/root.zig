const std = @import("std");
const lazily = @import("lazily");

const AuthToken = []const u8;

fn authenticate() AuthToken {
    std.debug.print("Authenticating...\n", .{});
    return "very_secret_token";
}

const deinitAuthToken = lazily.deinitValue(AuthToken);

fn getAuthToken(ctx: *lazily.Context) !AuthToken {
    const auth_token = authenticate();
    return try ctx.allocator.dupe(u8, auth_token);
}

// Lazily get an Auth Token using the lazily.slot function.
// Which accepts separate value getter function and optional deinit functions.
pub fn slotAuthToken(ctx: *lazily.Context) !AuthToken {
    return try lazily.slot(AuthToken, ctx, getAuthToken, deinitAuthToken);
}

fn getAuthTokenWithDeinit(ctx: *lazily.Context) !lazily.WithDeinit(AuthToken) {
    const auth_token = authenticate();
    return .{
        .value = try ctx.allocator.dupe(u8, auth_token),
        .deinit = deinitAuthToken,
    };
}

// Lazily get an Auth Token using the lazily.slotWithDeinit function.
// Which accepts a getter function for a lazily.WithDeinit(T) struct that holds the value and optional deinit functions.
pub fn slotAuthTokenWithDeinit(ctx: *lazily.Context) !AuthToken {
    return try lazily.slotWithDeinit(AuthToken, ctx, getAuthTokenWithDeinit);
}

pub const slotAuthToken_slotFn = lazily.slotFn(
    AuthToken,
    getAuthToken,
    deinitAuthToken,
);

export fn slotAuthTokenFFI(ctx: *lazily.Context) callconv(.c) lazily.StringView {
    const token = slotAuthTokenWithDeinit(ctx) catch |err| {
        return lazily.StringView{
            .ptr = &.{},
            .len = 0,
            .errno = 1,
            .errmsg = @errorName(err).ptr,
        };
    };
    return lazily.StringView.fromSlice(token);
}
comptime {
    // Support both camelCase and snake_case for FFI functions that target platforms with different name conventions.
    @export(&slotAuthTokenFFI, .{ .name = "slot_auth_token_ffi" });
}

test "slotAuthToken" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthToken(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
    try std.testing.expectEqualStrings("very_secret_token", try slotAuthToken(ctx));
}

test "slotAuthTokenWithDeinit" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthTokenWithDeinit(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
    try std.testing.expectEqualStrings("very_secret_token", try slotAuthTokenWithDeinit(ctx));
}

test "slotFn (slotAuthToken_slotFn)" {
    const ctx = try lazily.Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthToken_slotFn(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token);
    try std.testing.expectEqualStrings("very_secret_token", try slotAuthToken_slotFn(ctx));
}
