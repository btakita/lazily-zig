const std = @import("std");
const LazyContext = @import("./ctx").LazyContext;

pub const LazyGraph = struct {
    dependencies: std.AutoHashMap(usize, std.ArrayList(usize)),

    pub fn invalidate(self: *LazyGraph, ctx: *LazyContext, key: usize) void {
        // Remove this key
        ctx.cache.remove(key);

        // Invalidate all dependencies
        if (self.dependencies.get(key)) |deps| {
            for (deps.items) |dep_key| {
                self.invalidate(ctx, dep_key);
            }
        }
    }
};
