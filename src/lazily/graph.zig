const std = @import("std");
const Context = @import("./context.zig").Context;

pub const Graph = struct {
    dependencies: std.AutoHashMap(usize, std.ArrayList(usize)),

    pub fn invalidate(self: *Graph, ctx: *Context, key: usize) void {
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
