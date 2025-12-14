//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const cell_mod = @import("./lazily/cell.zig");
pub const Cell = cell_mod.Cell;
const ctx_mod = @import("./lazily/context.zig");
pub const Context = ctx_mod.Context;
pub const Graph = @import("./lazily/graph.zig").Graph;
const slot_mod = @import("./lazily/slot.zig");
pub const Compute = slot_mod.WithDeinitFn;
pub const deinitValue = slot_mod.deinitValue;
pub const SlotFn = slot_mod.SlotFn;
pub const slot = slot_mod.slot;
pub const slotWithDeinit = slot_mod.slotWithDeinit;
pub const slotFn = slot_mod.slotFn;
pub const StringView = slot_mod.StringView;
pub const WithDeinit = slot_mod.WithDeinit;
pub const WithDeinitFn = slot_mod.WithDeinitFn;

test {
	std.testing.refAllDecls(@This());
}
