const std = @import("std");
const lazily = @import("lazily");

fn authenticate() []const u8 {
    std.debug.print("Authenticating...\n", .{});
    return "very_secret_token";
}

fn getAuthToken(ctx: *lazily.Context) !lazily.Computed([]const u8) {
    const token = authenticate();
    const owned = try ctx.allocator.dupe(u8, token);
    return .{
        .value = owned,
        .deinit = lazily.deinitValue([]const u8),
    };
}

pub fn lazyAuthToken(ctx: *lazily.Context) ![]const u8 {
    return try lazily.slot([]const u8, ctx, struct {
        fn call(call_ctx: *lazily.Context) !lazily.Computed([]const u8) {
            const token = authenticate();
            const owned = try call_ctx.allocator.dupe(u8, token);
            return lazily.Computed([]const u8){
                .value = owned,
                .deinit = lazily.deinitValue([]const u8),
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
