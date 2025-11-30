//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const ctx_mod = @import("./lazily/ctx.zig");
pub const LazyContext = ctx_mod.LazyContext;
pub const LazySlot = ctx_mod.LazySlot;
const ffi_mod = @import("./lazily/ffi.zig");
pub const lazy_context_create = ffi_mod.lazy_context_create;
pub const lazy_context_destroy = ffi_mod.lazy_context_destroy;
pub const LazyGraph = @import("./lazily/graph.zig").LazyGraph;
const lazy_mod = @import("./lazily/lazy.zig");
pub const deinit_value = lazy_mod.deinit_value;
pub const lazy = lazy_mod.lazy;
pub const Lazy = lazy_mod.Lazy;
pub const LazyComputed = lazy_mod.LazyComputed;
pub const StringView = lazy_mod.StringView;
pub const LazyProperty = @import("./lazily/prop.zig").LazyProperty;

pub fn bufferedPrint() !void {
    // Stdout is for the actual output of your application, for example if you
    // are implementing gzip, then only the compressed bytes should be sent to
    // stdout, not any debugging messages.
    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("Run `zig build test` to run the tests.\n", .{});

    try stdout.flush(); // Don't forget to flush!
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}
