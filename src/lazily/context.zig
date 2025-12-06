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

pub const DeinitFn = ?*const fn (*Context, *anyopaque) void;

pub const ContextSlot = struct {
    ctx: *Context,
    ptr: *anyopaque,
    is_indirect: bool,
    deinit: DeinitFn,
    free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,

    pub fn destroy(self: @This()) void {
        self.destroyInCache();
        self.ctx.cache.remove(@intFromPtr(self));
    }

    pub fn destroyInCache(self: @This()) void {
        if (self.deinit) |deinit| {
            deinit(self.ctx, @ptrCast(self.ptr));
        }
        if (self.free) |free| {
            free(self.ctx.allocator, self.ptr);
        }
    }
};

// Context with lazy cache
pub const Context = struct {
    allocator: std.mem.Allocator,
    // Function pointer -> cached result
    cache: std.AutoHashMap(usize, ContextSlot),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        ctx.* = .{
            .allocator = allocator,
            .cache = std.AutoHashMap(usize, ContextSlot).init(allocator),
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
            slot_cache.destroyInCache();
        }
        self.cache.deinit();
        self.allocator.destroy(self);
    }
};

export fn lazily_context_init() ?*Context {
    return Context.init(std.heap.page_allocator) catch null;
}

export fn lazily_context_deinit(ctx: *Context) void {
    ctx.deinit();
}
