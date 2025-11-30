const LazyContext = @import("./ctx.zig").LazyContext;
const LazySlot = @import("./ctx.zig").LazySlot;

pub const LazyProperty = struct {
    pub fn define(comptime T: type, comptime compute_fn: fn (*LazyContext) T) type {
        return struct {
            ctx: *LazyContext,

            const cache_key = @intFromPtr(&compute_fn);

            pub fn get(self: @This()) !T {
                self.ctx.mutex.lock();
                defer self.ctx.mutex.unlock();

                // Check if already computed
                if (self.ctx.cache.get(cache_key)) |lazy_val| {
                    return @as(*T, @ptrCast(@alignCast(lazy_val.value))).*;
                }

                // Compute and cache
                const value = compute_fn(self.ctx);
                const stored = try self.ctx.allocator.create(T);
                stored.* = value;

                try self.ctx.cache.put(cache_key, LazySlot(T){
                    .ctx = self.ctx,
                    .value = @ptrCast(stored),
                    .deinit = null,
                });

                return value;
            }
        };
    }
};
