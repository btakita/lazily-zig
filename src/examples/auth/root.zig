const std = @import("std");
const lazily = @import("lazily");
const lazy = lazily.lazy;
const deinit_value = lazily.deinit_value;
const LazyComputed = lazily.LazyComputed;
const LazyContext = lazily.LazyContext;
const StringView = lazily.StringView;

fn authenticate() []const u8 {
    std.debug.print("Authenticating...\n", .{});
    return "very_secret_token";
}

// FFI-safe lazy computation
const LazyHandle = opaque {};

fn get_auth_token(ctx: *LazyContext) !LazyComputed([]const u8) {
    const token = authenticate();
    const owned = try ctx.allocator.dupe(u8, token);
    return .{
        .value = owned,
        .deinit = deinit_value([]const u8),
    };
}

pub fn lazy_auth_token(ctx: *LazyContext) ![]const u8 {
    return try lazy([]const u8, ctx, struct {
        fn call(call_ctx: *LazyContext) !LazyComputed([]const u8) {
            const token = authenticate();
            const owned = try call_ctx.allocator.dupe(u8, token);
            return LazyComputed([]const u8){
                .value = owned,
                .deinit = deinit_value([]const u8),
            };
        }
    }.call);
}

export fn ffi_lazy_auth_token(ctx: *LazyContext) callconv(.c) StringView {
    const token = lazy_auth_token(ctx) catch |err| {
        return StringView{
            .ptr = &.{},
            .len = 0,
            .errno = 1,
            .errmsg = @errorName(err).ptr,
        };
    };
    return StringView.from_slice(token);
}
