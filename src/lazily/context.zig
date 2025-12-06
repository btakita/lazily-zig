const std = @import("std");

pub fn SlotStrategy(comptime T: type) enum { direct, indirect } {
    const type_info = @typeInfo(T);
    // Determine if T is a pointer type
    const is_pointer = type_info == .pointer;

    // Storage strategy: inline for pointers/slices, heap pointer for others
    return if (is_pointer) .direct else .indirect;
}

pub fn SlotValuePtr(comptime T: type) type {
    const strategy = SlotStrategy(T);
    return switch (strategy) {
        .indirect => *T,
        .direct => T,
    };
}

pub fn Slot(comptime T: type) type {
    const strategy = SlotStrategy(T);
    return struct {
        ctx: *Context,
        ptr: SlotValuePtr(T),
        deinit: ?*const fn (*Context, T) void,
        is_indirect: bool = strategy == .indirect,

        pub fn get(self: @This()) T {
            switch (strategy) {
                .indirect => return self.ptr.*,
                .direct => return self.ptr,
            }
        }

        pub fn to_cache(self: @This()) SlotCache {
            return .{
                .ctx = self.ctx,
                .ptr = @ptrCast(@constCast(self.ptr)),
                .deinit = @ptrCast(self.deinit),
                .is_indirect = self.is_indirect,
            };
        }
    };
}

pub const SlotCache = struct {
    ctx: *Context,
    ptr: *anyopaque,
    is_indirect: bool,
    deinit: ?*const fn (*Context, *anyopaque) void,
    free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,

    pub fn from_cache(self: @This(), comptime T: type) Slot(T) {
        const strategy = comptime SlotStrategy(T);
        return .{
            .ctx = self.ctx,
            .ptr = switch (strategy) {
                .indirect => @ptrCast(@alignCast(self.ptr)),
                .direct => blk: {
                    // For .inl (pointer types like []const u8), we need to:
                    // 1. Cast the opaque pointer back to the original const-correct type
                    // 2. Preserve the const qualifier from T
                    const ValueType = SlotValuePtr(T);
                    break :blk @as(ValueType, @ptrCast(@alignCast(self.ptr)));
                },
            },
            .deinit = @ptrCast(self.deinit),
            .is_indirect = self.is_indirect,
        };
    }
};

fn ptr_deinit_wrapper(
    comptime T: type,
    comptime user_deinit: ?*const fn (*Context, T) void,
) *const fn (*Context, T) void {
    return struct {
        pub fn deinit(ctx: *Context, val: T) void {
            if (user_deinit) |deinit_fn| {
                deinit_fn(ctx, val);
            }

            const strategy = comptime SlotStrategy(T);
            switch (strategy) {
                .indirect => {
                    ctx.allocator.destroy(@as(*T, @ptrCast(&val)));
                },
                .direct => unreachable,
            }
        }
    }.deinit;
}

// Context with lazy cache
pub const Context = struct {
    allocator: std.mem.Allocator,
    // Function pointer -> cached result
    cache: std.AutoHashMap(usize, SlotCache),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        ctx.* = .{
            .allocator = allocator,
            .cache = std.AutoHashMap(usize, SlotCache).init(allocator),
            .mutex = .{},
        };
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Clean up all cached values
        var iter = self.cache.iterator();
        while (iter.next()) |entry| {
            const slot_cache = entry.value_ptr;
            if (slot_cache.deinit) |deinit_fn| {
                deinit_fn(self, slot_cache.ptr);
            }
            if (slot_cache.is_indirect) {
                // Destroy the wrapper pointer itself using the type-aware free function
                slot_cache.free.?(self.allocator, slot_cache.ptr);
            }
        }
        self.cache.deinit();
        self.allocator.destroy(self);
    }
};

pub fn context_init() ?*Context {
    return Context.init(std.heap.page_allocator) catch null;
}

export fn lazily_context_init() ?*Context {
    return context_init();
}

pub fn context_deinit(ctx: *Context) void {
    ctx.deinit();
}

export fn lazily_context_deinit(ctx: *Context) void {
    context_deinit(ctx);
}
