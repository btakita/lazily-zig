const std = @import("std");
const ctx_mod = @import("./context.zig");
const Context = ctx_mod.Context;
const currentSlotFor = ctx_mod.currentSlotFor;
const popTracking = ctx_mod.popTracking;
const pushTracking = ctx_mod.pushTracking;
const Slot = ctx_mod.Slot;
const TrackingFrame = ctx_mod.TrackingFrame;
const ValueFn = ctx_mod.ValueFn;
const valueFnCacheKey = ctx_mod.valueFnCacheKey;
const DeinitPayloadFn = Slot.DeinitPayloadFn;
const Free = Slot.Free;
const Mode = Slot.Mode;
const Storage = Slot.Storage;
const StorageKind = Slot.StorageKind;
const StoredType = Slot.StoredType;

pub fn initSlotFn(
    comptime T: type,
    comptime valueFn: *const ValueFn(T),
    comptime deinit: ?DeinitPayloadFn,
) *const ValueFn(T) {
    return struct {
        fn call(ctx: *Context) !T {
            return try slot(T, ctx, valueFn, deinit);
        }
    }.call;
}

/// Accepts a separate value getter function and optional `deinit` function.
/// See `slotFn` for alternative api.
pub fn slot(
    comptime T: type,
    ctx: *Context,
    valueFn: *const ValueFn(T),
    deinit: ?DeinitPayloadFn,
) !T {
    const key = valueFnCacheKey(valueFn);

    // ctx.mutex.lock();
    // defer ctx.mutex.unlock();

    // Check cache
    if (ctx.cache.get(key)) |context_slot| {
        if (context_slot.storage != null) {
            return context_slot.get(T);
        }
    }

    // Create a free function that knows the type T
    var _slot = try Slot.init(
        T,
        ctx,
        valueFn,
        deinit,
    );
    try ctx.cache.put(key, _slot);

    return _slot.get(T);
}

pub fn DeinitValueFn(comptime T: type) type {
    return *const fn (*Context, *const ValueFn(T), T) void;
}

const SlotError = error{MissingStorage};

pub fn deinitValue(
    comptime T: type,
    comptime deinitValueFn: ?DeinitValueFn(T),
) DeinitPayloadFn {
    // If they try to use the default "free" on a raw pointer/slice, error out.
    if (deinitValueFn == null and (comptime Mode(T) == .direct)) {
        const message = std.fmt.comptimePrint(
            "To prevent accidental freeing of string literals or unowned memory, " ++
                "deinitValue cannot be used directly with raw slices/pointers. " ++
                "Please return an Owned(T) or provide a custom deinit function. " ++
                "Got {}",
            .{T},
        );
        @compileError(message);
    }
    const effective_deinitValueFn = deinitValueFn orelse struct {
        fn call(_ctx: *Context, valueFn: *const ValueFn(T), value: T) void {
            _ = valueFn;
            switch (comptime Mode(T)) {
                .direct => unreachable,
                .indirect => {
                    // T is not a pointer, check for deinit method
                    if (comptime @typeInfo(T) == .@"struct" and
                        @hasDecl(T, "deinit"))
                    {
                        // For indirect, val should be single_ptr pointing to T
                        var mutable_value = value;
                        mutable_value.deinit(_ctx);
                    }
                },
            }
        }
    }.call;
    return struct {
        pub fn deinit(_slot: *Slot) void {
            if (_slot.storage) |storage| {
                const actual_value: T = switch (comptime Mode(T)) {
                    .direct => switch (comptime Slot.PtrSize(T)) {
                        .slice => storage.payload.slice.toSlice(T),
                        .one, .many, .c => @as(T, @ptrCast(@alignCast(storage.payload.single_ptr))),
                    },
                    .indirect => @as(*T, @ptrCast(@alignCast(storage.payload.single_ptr))).*,
                };
                if (_slot.value_fn_ptr) |value_fn_ptr| {
                    const typed_value_fn_ptr: *ValueFn(T) = @ptrCast(@alignCast(value_fn_ptr));
                    effective_deinitValueFn(_slot.ctx, typed_value_fn_ptr, actual_value);
                }
            }
        }
    }.deinit;
}

pub const StringView = extern struct {
    ptr: [*]const u8, // Plain pointer for C ABI compatibility
    len: usize, // Byte length (excluding \0)
    errno: c_uint,
    errmsg: ?[*]const u8,

    pub fn fromSlice(slice: []const u8) StringView {
        return StringView{
            .ptr = slice.ptr,
            .len = slice.len,
            .errno = 0,
            .errmsg = &.{},
        };
    }
};

fn SlotAndValue(comptime T: type) type {
    return struct { slot: Slot, value: T };
}

fn deinitIndirect(comptime T: type, comptime deinitFromUser: ?DeinitPayloadFn) DeinitPayloadFn {
    return struct {
        pub fn deinit(ctx: *Context, val: Storage) void {
            if (deinitFromUser) {
                deinitFromUser(ctx, val);
            }

            switch (comptime Mode(T)) {
                .direct => unreachable,
                .indirect => {
                    ctx.allocator.destroy(
                        @as(
                            *T,
                            @ptrCast(@alignCast(val.single_ptr)),
                        ),
                    );
                },
            }
        }
    }.deinit;
}

test "Context.init, slotFn, Context.getSlot, Context.deinit" {
    const ctx = try Context.init(std.testing.allocator);
    defer ctx.deinit();
    const getFoo = struct {
        fn call(_: *Context) !u8 {
            return 1;
        }
    }.call;
    const lazyFoo = initSlotFn(u8, getFoo, null);

    try std.testing.expectEqual(null, ctx.getSlot(getFoo));
    try std.testing.expectEqual(1, lazyFoo(ctx));
    try std.testing.expect(ctx.getSlot(getFoo) != null);
}
