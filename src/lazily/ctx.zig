const std = @import("std");

pub fn LazySlotStrategy(comptime T: type) enum { direct, indirect } {
    const type_info = @typeInfo(T);
    // Determine if T is a pointer type
    const is_pointer = type_info == .pointer;

    // Storage strategy: inline for pointers/slices, heap pointer for others
    return if (is_pointer) .direct else .indirect;
}

pub fn LazySlotValuePtr(comptime T: type) type {
    const strategy = LazySlotStrategy(T);
    return switch (strategy) {
        .indirect => *T,
        .direct => T,
    };
}

pub fn LazySlot(comptime T: type) type {
    const strategy = LazySlotStrategy(T);
    return struct {
        ctx: *LazyContext,
        ptr: LazySlotValuePtr(T),
        deinit: *const fn (*LazyContext, T) void,
        is_indirect: bool = strategy == .indirect,

        pub fn get(self: @This()) T {
            switch (strategy) {
                .indirect => return self.ptr.*,
                .direct => return self.ptr,
            }
        }

        pub fn to_cache(self: @This()) LazySlotCache {
            return .{
                .ctx = self.ctx,
                .ptr = @ptrCast(@constCast(self.ptr)),
                .deinit = @ptrCast(self.deinit),
                .is_indirect = self.is_indirect,
            };
        }
    };
}

pub const LazySlotCache = struct {
    ctx: *LazyContext,
    ptr: *anyopaque,
    deinit: *const fn (*LazyContext, *anyopaque) void,
    is_indirect: bool,

    pub fn from_cache(self: @This(), comptime T: type) LazySlot(T) {
        const strategy = comptime LazySlotStrategy(T);
        return .{
            .ctx = self.ctx,
            .ptr = switch (strategy) {
                .indirect => @ptrCast(@alignCast(self.ptr)),
                .direct => blk: {
                    // For .inl (pointer types like []const u8), we need to:
                    // 1. Cast the opaque pointer back to the original const-correct type
                    // 2. Preserve the const qualifier from T
                    const ValueType = LazySlotValuePtr(T);
                    break :blk @as(ValueType, @ptrCast(@alignCast(self.ptr)));
                },
            },
            .deinit = @ptrCast(self.deinit),
            .is_indirect = self.is_indirect,
        };
    }
};

// Context with lazy cache
pub const LazyContext = struct {
    allocator: std.mem.Allocator,
    // Function pointer -> cached result
    cache: std.AutoHashMap(usize, LazySlotCache),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*LazyContext {
        const ctx = try allocator.create(LazyContext);
        ctx.* = .{
            .allocator = allocator,
            .cache = std.AutoHashMap(usize, LazySlotCache).init(allocator),
            .mutex = .{},
        };
        return ctx;
    }

    pub fn deinit(self: *LazyContext) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all cached values
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            const slot_opaque = entry.value_ptr;
            if (slot_opaque.deinit) |deinit_fn| {
                if (slot_opaque.ptr) |data| {
                    deinit_fn(self, data);
                }
            }
            if (slot_opaque.is_indirect) {
                // Then destroy the wrapper pointer itself (for .wrap strategy values)
                self.allocator.destroy(@as(*anyopaque, @ptrCast(slot_opaque.ptr)));
            }
        }
        self.cache.deinit();
        self.allocator.destroy(self);
    }
};
