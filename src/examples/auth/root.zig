const std = @import("std");
const lazily = @import("lazily");
const Context = lazily.Context;
const slot = lazily.slot;
const deinitSlotValue = lazily.deinitSlotValue;
const initSlotFn = lazily.initSlotFn;
const Owned = lazily.Owned;
const OwnedString = lazily.OwnedString;
const StringView = lazily.StringView;

const AuthToken = OwnedString;

fn authenticate() []const u8 {
    return "very_secret_token";
}

fn getAuthToken(ctx: *Context) !AuthToken {
    const auth_token = authenticate();
    return AuthToken.managed(try ctx.allocator.dupe(u8, auth_token));
}

const deinitAuthToken = deinitSlotValue(
    AuthToken,
    null,
);

/// Lazily get an Auth Token using the lazily.slot function.
/// Which accepts separate value getter function and optional deinit functions.
pub fn slotAuthToken(ctx: *Context) !*AuthToken {
    return try slot(AuthToken, ctx, getAuthToken, deinitAuthToken);
}
test "examples/auth: slotAuthToken" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthToken(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token.value);
    try std.testing.expectEqualStrings(
        "very_secret_token",
        (try slotAuthToken(ctx)).value,
    );
}

pub const slotAuthToken_initSlotFn = initSlotFn(
    AuthToken,
    getAuthToken,
    deinitAuthToken,
);
test "examples/auth: initSlotFn (slotAuthToken_initSlotFn)" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const token = try slotAuthToken_initSlotFn(ctx);
    try std.testing.expectEqualStrings("very_secret_token", token.value);
    try std.testing.expectEqualStrings(
        "very_secret_token",
        (try slotAuthToken_initSlotFn(ctx)).value,
    );
}

export fn slotAuthTokenFFI(ctx: *Context) callconv(.c) StringView {
    const token = slotAuthToken(ctx) catch |err| {
        return StringView{
            .ptr = &.{},
            .len = 0,
            .errno = 1,
            .errmsg = @errorName(err).ptr,
        };
    };
    return StringView.fromSlice(token.value);
}
comptime {
    // Support both camelCase and snake_case for FFI functions...
    // that target platforms with different name conventions.
    @export(
        &slotAuthTokenFFI,
        .{ .name = "slot_auth_token_ffi" },
    );
}
