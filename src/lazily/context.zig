const std = @import("std");

pub fn getSlotStrategy(comptime T: type) enum { direct, indirect } {
    const type_info = @typeInfo(T);
    // Determine if T is a pointer type
    const is_pointer = type_info == .pointer;

    // Storage strategy: inline for pointers/slices, heap pointer for others
    return if (is_pointer) .direct else .indirect;
}

pub fn isSlice(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .pointer) return false;
    return type_info.pointer.size == .Slice;
}

pub fn isPointer(comptime T: type) bool {
    const type_info = @typeInfo(T);
    if (type_info != .pointer) return false;
    return type_info.pointer.size == .One;
}

pub fn SliceValue(comptime T: type) type {
    return struct {
        ptr: [*]const T,
        len: usize,
    };
}

pub const DeinitValue = union(enum) {
    single_ptr: *anyopaque,
    slice: SliceValue(u8),
};

pub const DeinitFn = *const fn (*Context, DeinitValue) void;

pub const ContextSlotPtr = union(enum) {
    single_ptr: *anyopaque,
    slice: SliceValue(u8),
};

pub const ContextSlot = struct {
    ctx: *Context,
    ptr: ContextSlotPtr,
    is_indirect: bool,
    pointer_size: std.builtin.Type.Pointer.Size,
    deinit: ?DeinitFn,
    free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,

    pub fn destroy(self: @This()) void {
        self.destroyInCache();
        self.ctx.cache.remove(@intFromPtr(self));
    }

    pub fn destroyInCache(self: @This()) void {
        if (self.deinit) |deinit| {
            const value = switch (self.ptr) {
                .single_ptr => |p| DeinitValue{ .single_ptr = p },
                .slice => |s| DeinitValue{ .slice = s },
            };
            deinit(self.ctx, value);
        }
        if (self.free) |free| {
            const ptr = switch (self.ptr) {
                .single_ptr => |p| p,
                .slice => |s| @as(*anyopaque, @ptrCast(@constCast(s.ptr))),
            };
            free(self.ctx.allocator, ptr);
        }
        // Handle slices directly without deinit callback
        // if (self.pointer_size == .slice) {
        //     const s = self.ptr.slice;
        //     const slice_val: []const u8 = s.ptr[0..s.len];
        //     self.ctx.allocator.free(slice_val);
        // } else if (self.deinit) |deinit| {
        //     // Handle non-slice direct pointers and indirect types
        //     const ptr = self.ptr.single_ptr;
        //     deinit(self.ctx, ptr);
        // }
        // if (self.free) |free| {
        //     const ptr = self.ptr.single_ptr;
        //     free(self.ctx.allocator, ptr);
        // }
        // if (self.deinit) |deinit| {
        //     switch (self.ptr) {
        //         .single_ptr => |p| {
        //             deinit(self.ctx, p);
        //         },
        //         .slice => |s| {
        //             // For slices, reconstruct and pass to deinit
        //             const slice_val: []const u8 = s.ptr[0..s.len];
        //             deinit(self.ctx, @as(*anyopaque, @ptrCast(@constCast(&slice_val))));
        //         },
        //     }
        // }
        // if (self.free) |free| {
        //     const ptr = switch (self.ptr) {
        //         .single_ptr => |p| p,
        //         .slice => unreachable,
        //     };
        //     free(self.ctx.allocator, ptr);
        // }
    }
};

// Context with lazy cache
pub const Context = struct {
    allocator: std.mem.Allocator,
    // Function pointer -> cached result
    cache: std.AutoHashMap(usize, ContextSlot),
    // mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        ctx.* = .{
            .allocator = allocator,
            .cache = std.AutoHashMap(usize, ContextSlot).init(allocator),
            // .mutex = .{},
        };
        return ctx;
    }

    pub fn deinit(self: *Context) void {
        // self.mutex.lock();
        // defer self.mutex.unlock();

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
