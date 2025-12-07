const std = @import("std");

pub fn getSlotStrategy(comptime T: type) enum { direct, indirect } {
    const type_info = @typeInfo(T);
    const is_pointer = type_info == .pointer;
    // Storage strategy: .direct for pointers/slices, .indirect others
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

// Type-erased slice handler that works with any element type
pub const SliceValue = struct {
    ptr: *anyopaque,
    len: usize, // Number of elements (not bytes)
    element_size: usize, // @sizeOf(T)
    free: *const fn (std.mem.Allocator, *anyopaque, usize, usize) void,
};

// Create a SliceHandler for any slice type
pub fn sliceValue(comptime T: type, slice_data: T) SliceValue {
    const type_info = @typeInfo(T);
    if (type_info != .pointer) {
        @compileError("sliceValue requires a pointer/slice type");
    }
    const element_type = type_info.pointer.child;

    return .{
        .ptr = @ptrCast(@constCast(slice_data.ptr)),
        .len = slice_data.len,
        .element_size = @sizeOf(element_type),
        .free = struct {
            fn free(allocator: std.mem.Allocator, ptr: *anyopaque, len: usize, element_size: usize) void {
                _ = element_size; // For debugging/validation
                const slice: T = @as([*]element_type, @ptrCast(@alignCast(ptr)))[0..len];
                allocator.free(slice);
            }
        }.free,
    };
}

pub const DeinitValue = union(enum) {
    single_ptr: *anyopaque,
    slice: SliceValue,
};

pub const DeinitFn = *const fn (*Context, DeinitValue) void;

pub const ContextSlotPtr = union(enum) {
    single_ptr: *anyopaque,
    slice: SliceValue,
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
                .slice => |s| s.ptr,
            };
            free(self.ctx.allocator, ptr);
        }
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
            const context_slot = entry.value_ptr;
            context_slot.destroyInCache();
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
