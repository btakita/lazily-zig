//! Single-threaded reactive shell for the latest-durable projection core.

const std = @import("std");
const Context = @import("context.zig").Context;
const ReaderKind = @import("reader_kind.zig").ReaderKind;
const core_mod = @import("latest_durable_projection_core.zig");

pub const LatestDurableProjectionCore = core_mod.LatestDurableProjectionCore;

/// Owns one graph reader-kind. Every real state transition bumps it exactly
/// once; rejected/stale operations leave the graph clean.
pub fn LatestDurableProjection(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Core = core_mod.LatestDurableProjectionCore(K, V);
        pub const KeyState = core_mod.LatestDurableKeyState(K, V);
        pub const Snapshot = core_mod.LatestDurableSnapshot(K, V);
        pub const Claim = core_mod.LatestDurableClaim(K, V);

        ctx: *Context,
        core: Core,
        state_reader: ReaderKind,

        pub fn init(ctx: *Context, initial_generation: u64) !Self {
            return .{
                .ctx = ctx,
                .core = Core.init(ctx.allocator, initial_generation),
                .state_reader = try ReaderKind.init(ctx),
            };
        }

        pub fn deinit(self: *Self) void {
            self.state_reader.dispose();
            self.core.deinit();
        }

        fn publish(self: *Self, change: core_mod.LatestDurableChange) void {
            if (change.state) self.state_reader.bump();
        }

        pub fn upsert_desired(self: *Self, key: K, epoch: u64, value: V) !core_mod.LatestDurableUpsert {
            const transition = try self.core.upsert_desired(key, epoch, value);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn claim(self: *Self, key: K, actor_generation: u64) !Claim {
            const transition = try self.core.claim(key, actor_generation);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn ack_applied(self: *Self, key: K, actor_generation: u64, epoch: u64) !core_mod.LatestDurableAck {
            const transition = try self.core.ack_applied(key, actor_generation, epoch);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn fail_retryable(self: *Self, key: K, actor_generation: u64, epoch: u64) !core_mod.LatestDurableFailure {
            const transition = try self.core.fail_retryable(key, actor_generation, epoch);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn reconnect(self: *Self, new_generation: u64) !core_mod.LatestDurableReconnect {
            const transition = self.core.reconnect(new_generation);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn generation(self: *const Self) u64 {
            return self.core.generation();
        }

        pub fn count(self: *const Self) usize {
            return self.core.count();
        }

        pub fn state(self: *const Self, key: K) ?KeyState {
            return self.core.state(key);
        }

        pub fn snapshot(self: *const Self, allocator: std.mem.Allocator) !Snapshot {
            return self.core.snapshot(allocator);
        }

        /// Reading this value registers the projection-wide dependency.
        pub fn stateVersion(self: *const Self) u64 {
            return self.state_reader.version();
        }

        pub fn stateSlot(self: *const Self) *@import("context.zig").Slot {
            return self.state_reader.slot();
        }
    };
}

test "reactive latest durable shell invalidates only on transitions" {
    const context = try Context.init(std.testing.allocator);
    defer context.deinit();
    var projection = try LatestDurableProjection([]const u8, []const u8).init(context, 1);
    defer projection.deinit();

    try std.testing.expectEqual(@as(u64, 0), projection.stateVersion());
    _ = try projection.upsert_desired("doc", 1, "A");
    try std.testing.expectEqual(@as(u64, 1), projection.stateVersion());
    _ = try projection.upsert_desired("doc", 1, "A");
    try std.testing.expectEqual(@as(u64, 1), projection.stateVersion());
}
