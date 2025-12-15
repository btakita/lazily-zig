const std = @import("std");

const SlotError = error{SlotMissingPtr};

/// Context with lazy cache
pub const Context = struct {
    allocator: std.mem.Allocator,
    // Function pointer -> cached result
    cache: std.AutoHashMap(usize, *Slot),
    // mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) !*Context {
        const ctx = try allocator.create(Context);
        ctx.* = .{
            .allocator = allocator,
            // Not thread-safe
            .cache = std.AutoHashMap(
                usize,
                *Slot,
            ).init(allocator),
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
            const context_slot = entry.value_ptr.*;
            context_slot.destroy();
        }
        self.cache.deinit();
        self.allocator.destroy(self);
    }

    // Get a Slot. Slot.destroy() will deinit and remove the Slot from the Context.cache.
    pub fn getSlot(self: *Context, comptime fnc: anytype) ?*Slot {
        const key = valueFnCacheKey(fnc);
        return self.cache.get(key);
    }
};

pub fn Owned(comptime T: type) type {
    return struct {
        value: T,
        is_managed: bool,

        pub fn managed(value: T) @This() {
            return .{ .value = value, .is_managed = true };
        }

        pub fn literal(value: T) @This() {
            return .{ .value = value, .is_managed = false };
        }

        pub fn deinit(self: *@This(), ctx: *Context) void {
            if (!self.is_managed) return;

            const type_info = @typeInfo(T);
            if (type_info == .pointer) {
                ctx.allocator.free(self.value);
            } else if (type_info == .@"struct" and @hasDecl(T, "deinit")) {
                self.value.deinit(ctx);
            }
        }
    };
}

pub const String = []const u8;
pub const OwnedString = Owned(String);

pub fn valueFnCacheKey(valueFn: anytype) usize {
    const type_info = @typeInfo(@TypeOf(valueFn));

    return switch (type_info) {
        // If caller passes a function (not a pointer), take its address.
        .@"fn" => @intFromPtr(&valueFn),

        // If caller passes a function pointer, use it directly.
        .pointer => |p| blk: {
            if (@typeInfo(p.child) != .@"fn") {
                @compileError("Expected a function pointer");
            }
            break :blk @intFromPtr(valueFn);
        },

        else => @compileError("expected a function or function pointer"),
    };
}

pub const Slot = struct {
    ctx: *Context,
    value_fn_ptr: ?*anyopaque,
    storage: ?Storage,
    mode: Modes,
    /// Pointer classification for the cached value type (std.builtin.Type.Pointer.Size): .one, .many, .slice, .c
    ptr_size: std.builtin.Type.Pointer.Size,
    subscribers: std.AutoHashMap(*Slot, void),
    parents: std.AutoHashMap(*Slot, void),
    deinit: ?*const fn (*Slot) void,
    free: ?*const fn (std.mem.Allocator, *anyopaque) void = null,

    pub const DeinitPayloadFn = *const fn (*Slot) void;

    pub const Modes = enum { direct, indirect };
    pub fn Mode(comptime T: type) Modes {
        const type_info = @typeInfo(T);
        const is_pointer = type_info == .pointer;
        // Storage strategy: .direct for pointers/slices, .indirect others
        return if (is_pointer) .direct else .indirect;
    }

    pub fn StoredType(comptime T: type) type {
        return switch (comptime Mode(T)) {
            .direct => T,
            .indirect => *T,
        };
    }

    pub fn PtrSize(comptime T: type) std.builtin.Type.Pointer.Size {
        return @typeInfo(Slot.StoredType(T)).pointer.size;
    }

    pub fn StorageKind(comptime T: type) enum { single_ptr, slice } {
        return switch (comptime Mode(T)) {
            .direct => switch (comptime PtrSize(T)) {
                .slice => .slice,
                .one, .many, .c => .single_ptr,
            },
            .indirect => .single_ptr,
        };
    }

    pub const Storage = struct {
        pub const Payload = union(enum) {
            single_ptr: *anyopaque,
            slice: SliceStorage,
        };

        payload: Payload,
        pub fn init(payload: Payload) Storage {
            return .{ .payload = payload };
        }

        /// Converts a computed value `T` into the storage representation `StoredType(T)`.
        /// - `.direct`: no allocation, returns the value as-is
        /// - `.indirect`: allocates `T` in `ctx.allocator` and returns `*T`
        pub fn toStoredType(comptime T: type, ctx: *Context, value: T) !StoredType(T) {
            return switch (comptime Mode(T)) {
                .direct => value,
                .indirect => blk: {
                    const p = try ctx.allocator.create(T);
                    p.* = value;
                    break :blk p;
                },
            };
        }
    };

    /// Type-erased slice handler that works with any element type
    pub const SliceStorage = struct {
        ptr: *anyopaque,
        len: usize, // Number of elements (not bytes)
        mode: Slot.Modes,
        element_size: usize, // @sizeOf(T)
        free: *const fn (std.mem.Allocator, *anyopaque, usize, usize) void,

        /// Create a `SliceStorage` for any slice type
        pub fn init(comptime T: type, value: T) SliceStorage {
            const type_info = @typeInfo(T);
            if (type_info != .pointer) {
                @compileError("SliceStorage.init requires a pointer/slice type");
            }
            const element_type = type_info.pointer.child;

            return .{
                .ptr = @ptrCast(@constCast(value.ptr)),
                .len = value.len,
                .mode = Mode(element_type),
                .element_size = @sizeOf(element_type),
                .free = struct {
                    fn free(
                        allocator: std.mem.Allocator,
                        ptr: *anyopaque,
                        len: usize,
                        element_size: usize,
                    ) void {
                        _ = element_size; // For debugging/validation
                        const slice: T = @as([*]element_type, @ptrCast(@alignCast(ptr)))[0..len];
                        allocator.free(slice);
                    }
                }.free,
            };
        }

        /// Reconstruct the original slice type `T` from this storage.
        /// `T` must be a slice type (pointer size `.slice`), e.g. `[]u8`, `[]const u8`, `[]MyType`.
        pub fn toSlice(self: SliceStorage, comptime T: type) T {
            const type_info = @typeInfo(T);
            if (type_info != .pointer or type_info.pointer.size != .slice) {
                const message = std.fmt.comptimePrint(
                    "SliceStorage.unpack requires a slice type (e.g. []u8, []const u8). Got {}",
                    .{T},
                );
                @compileError(message);
            }

            const element_type = type_info.pointer.child;

            // Best-effort validation: helps catch mismatched T at runtime in Debug/ReleaseSafe.
            std.debug.assert(self.element_size == @sizeOf(element_type));

            return @as([*]element_type, @ptrCast(@alignCast(self.ptr)))[0..self.len];
        }
    };

    pub fn init(
        comptime T: type,
        ctx: *Context,
        valueFn: *const ValueFn(T),
        deinit: ?DeinitPayloadFn,
    ) !*@This() {
        const mode = comptime Mode(T);
        const ptr_size = comptime Slot.PtrSize(T);
        const free = comptime Free(T);
        const slot = try ctx.allocator.create(Slot);
        slot.* = Slot{
            .ctx = ctx,
            .value_fn_ptr = null,
            .mode = mode,
            .storage = null,
            .ptr_size = ptr_size,
            .subscribers = std.AutoHashMap(
                *Slot,
                void,
            ).init(ctx.allocator),
            .parents = std.AutoHashMap(
                *Slot,
                void,
            ).init(ctx.allocator),
            .deinit = deinit,
            .free = if (mode == .indirect) free else null,
        };

        const current_slot: ?*Slot = currentSlotFor(ctx);
        if (current_slot) |parent_slot| {
            _ = try parent_slot.subscribers.getOrPut(slot);
            _ = try slot.parents.getOrPut(parent_slot);
        }

        var frame = TrackingFrame{
            .prev = null,
            .ctx = ctx,
            .slot = slot,
        };
        pushTracking(&frame);
        defer popTracking(&frame);

        const value = try valueFn(ctx);
        const stored_value = try Storage.toStoredType(T, ctx, value);
        slot.value_fn_ptr = @ptrCast(@constCast(valueFn));

        slot.storage = Storage.init(
            switch (comptime Mode(T)) {
                .direct => switch (comptime Slot.PtrSize(T)) {
                    .slice => Slot.Storage.Payload{
                        .slice = SliceStorage.init(T, stored_value),
                    },
                    .one, .many, .c => Slot.Storage.Payload{
                        .single_ptr = @ptrCast(@constCast(stored_value)),
                    },
                },
                .indirect => Slot.Storage.Payload{
                    .single_ptr = @ptrCast(stored_value),
                },
            },
        );
        return slot;
    }

    pub fn get(self: Slot, comptime T: type) !T {
        const payload = if (self.storage) |storage| blk: {
            break :blk storage.payload;
        } else {
            return error.SlotMissingPtr;
        };

        return switch (comptime Mode(T)) {
            .direct => switch (comptime Slot.PtrSize(T)) {
                .slice => blk: {
                    const slice_storage = payload.slice;
                    break :blk slice_storage.toSlice(T);
                },
                .one, .many, .c => @as(T, @ptrCast(@alignCast(payload.single_ptr))),
            },
            .indirect => @as(*T, @ptrCast(@alignCast(payload.single_ptr))).*,
        };
    }

    pub fn getPtr(self: Slot, comptime T: type) !*T {
        const payload = if (self.storage) |storage| storage.payload else return error.SlotMissingPtr;
        return switch (comptime Mode(T)) {
            .direct => return error.CannotGetPtrOfDirectMode,
            .indirect => @as(*T, @ptrCast(@alignCast(payload.single_ptr))),
        };
    }

    pub fn destroy(self: *Slot) void {
        self.destroyInCache();
        var iter = self.parents.iterator();
        while (iter.next()) |entry| {
            const parent_slot = entry.key_ptr.*;
            _ = parent_slot.subscribers.remove(self);
        }
        self.parents.deinit();
        if (self.value_fn_ptr != null) {
            _ = self.ctx.cache.remove(@intFromPtr(self.value_fn_ptr));
        }
        self.ctx.allocator.destroy(self);
    }

    /// Destroys the value and its subscribers recursively.
    /// Used for cache invalidation.
    pub fn destroyInCache(self: *Slot) void {
        if (self.storage) |storage| {
            var iter = self.subscribers.iterator();
            while (iter.next()) |entry| {
                const dependent_slot = entry.key_ptr.*;
                dependent_slot.destroy();
            }
            if (self.deinit) |deinit_fn| {
                deinit_fn(self);
            }
            if (self.mode == .indirect) {
                if (self.free) |free_fn| {
                    free_fn(self.ctx.allocator, storage.payload.single_ptr);
                }
            }
            self.storage = null;
            self.subscribers.deinit();
        }
    }

    /// Create a free function that knows the type `T`
    pub fn Free(comptime T: type) ?*const fn (std.mem.Allocator, *anyopaque) void {
        return switch (comptime Slot.Mode(T)) {
            .direct => null,
            .indirect => struct {
                fn free(allocator: std.mem.Allocator, ptr: *anyopaque) void {
                    allocator.destroy(@as(*T, @ptrCast(@alignCast(ptr))));
                }
            }.free,
        };
    }
};

pub fn ValueFn(comptime T: type) type {
    return fn (*Context) anyerror!T;
}

pub const SubscriberKey = struct {
    ctx_ptr: usize, // @intFromPtr(ctx) or 0 if null
    cb_ptr: usize, // @intFromPtr(callback)
};

pub fn subscriberKey(ctx: *Context, valueFn: anytype) SubscriberKey {
    return .{
        .ctx_ptr = @intFromPtr(ctx),
        .cb_ptr = @intFromPtr(valueFn),
    };
}

pub const SubscriberSet = std.AutoHashMap(SubscriberKey, void);

const SlotCallback = *const fn (ctx: *Context, slot: *Slot) void;

pub fn ValueCallback(comptime T: type) type {
    return *const fn (ctx: *Context, new: T, old: T) void;
}

pub fn Subscriber(comptime T: type) type {
    return struct {
        id: SubscriberKey,
        ctx: *Context,
        cb: ValueCallback(T),
    };
}

pub const TrackingFrame = struct {
    prev: ?*TrackingFrame,
    ctx: *Context,
    slot: *Slot,
};

threadlocal var tracking_top: ?*TrackingFrame = null;

pub fn pushTracking(frame: *TrackingFrame) void {
    frame.prev = tracking_top;
    tracking_top = frame;
}

pub fn popTracking(frame: *TrackingFrame) void {
    // In debug builds you can assert(frame == tracking_top.?).
    tracking_top = frame.prev;
}

// TODO: Use an AutoHashMap for faster lookup
pub fn currentSlotFor(ctx: *Context) ?*Slot {
    var it = tracking_top;
    while (it) |f| : (it = f.prev) {
        if (f.ctx == ctx) return f.slot;
    }
    return null;
}
export fn initContext() ?*Context {
    return Context.init(std.heap.page_allocator) catch null;
}
comptime {
    @export(&initContext, .{ .name = "init_context" });
}

export fn deinitContext(ctx: *Context) void {
    ctx.deinit();
}
comptime {
    @export(&deinitContext, .{ .name = "deinit_context" });
}
