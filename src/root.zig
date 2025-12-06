//! By convention, root.zig is the root source file when making a library.
const std = @import("std");
const ctx_mod = @import("./lazily/context.zig");
pub const Context = ctx_mod.Context;
pub const Graph = @import("./lazily/graph.zig").Graph;
const slot_mod = @import("./lazily/slot.zig");
pub const deinitValue = slot_mod.deinitValue;
pub const slot = slot_mod.slot;
pub const Lazy = slot_mod.Lazy;
pub const Computed = slot_mod.Computed;
pub const StringView = slot_mod.StringView;
