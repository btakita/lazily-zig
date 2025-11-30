const LazyContext = @import("./ctx.zig").LazyContext;
const std = @import("std");

// Export for FFI
pub fn lazy_context_create() ?*LazyContext {
    return LazyContext.init(std.heap.page_allocator) catch null;
}

fn ffi_lazy_context_create() ?*LazyContext {
    return lazy_context_create();
}
comptime {
    @export(&ffi_lazy_context_create, .{ .name = "lazy_context_create" });
}

pub fn lazy_context_destroy(ctx: *LazyContext) void {
    ctx.deinit();
}

fn ffi_lazy_context_destroy(ctx: *LazyContext) void {
    lazy_context_destroy(ctx);
}
comptime {
    @export(&ffi_lazy_context_destroy, .{ .name = "lazy_context_destroy" });
}
