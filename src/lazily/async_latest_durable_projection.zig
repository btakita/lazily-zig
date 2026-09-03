//! Async-context latest-durable projection shell.
//!
//! Transitions stay synchronous; only publishing the context source can fail.
//! The caller performs sink I/O after `claim` and settles that I/O before ack or
//! retry, so no future is hidden inside the state machine.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const ac = @import("async_context.zig");
const core_mod = @import("latest_durable_projection_core.zig");

pub fn AsyncLatestDurableProjection(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Core = core_mod.LatestDurableProjectionCore(K, V);
        pub const KeyState = core_mod.LatestDurableKeyState(K, V);
        pub const Claim = core_mod.LatestDurableClaim(K, V);
        pub const Ctx = ac.AsyncContext(u64);

        ctx: *Ctx,
        mutex: ParkingMutex = ParkingMutex.init(),
        core: Core,
        state_source: ac.AsyncSource(u64),
        state_version: u64 = 0,

        pub fn init(ctx: *Ctx, initial_generation: u64) !Self {
            return .{
                .ctx = ctx,
                .core = Core.init(ctx.allocator, initial_generation),
                .state_source = try ctx.source(0),
            };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
        }

        fn publish(self: *Self, change: core_mod.LatestDurableChange) !void {
            if (!change.state) return;
            self.state_version += 1;
            try self.ctx.setSource(self.state_source, self.state_version);
        }

        pub fn upsert_desired(self: *Self, key: K, epoch: u64, value: V) !core_mod.LatestDurableUpsert {
            const transition = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.upsert_desired(key, epoch, value);
            };
            try self.publish(transition.change);
            return transition.outcome;
        }

        pub fn claim(self: *Self, key: K, actor_generation: u64) !Claim {
            const transition = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.claim(key, actor_generation);
            };
            try self.publish(transition.change);
            return transition.outcome;
        }

        pub fn ack_applied(self: *Self, key: K, actor_generation: u64, epoch: u64) !core_mod.LatestDurableAck {
            const transition = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.ack_applied(key, actor_generation, epoch);
            };
            try self.publish(transition.change);
            return transition.outcome;
        }

        pub fn fail_retryable(self: *Self, key: K, actor_generation: u64, epoch: u64) !core_mod.LatestDurableFailure {
            const transition = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk try self.core.fail_retryable(key, actor_generation, epoch);
            };
            try self.publish(transition.change);
            return transition.outcome;
        }

        pub fn reconnect(self: *Self, new_generation: u64) !core_mod.LatestDurableReconnect {
            const transition = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.core.reconnect(new_generation);
            };
            try self.publish(transition.change);
            return transition.outcome;
        }

        pub fn generation(self: *Self) u64 {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.generation();
        }

        pub fn count(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.count();
        }

        pub fn state(self: *Self, key: K) ?KeyState {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.core.state(key);
        }

        /// Reactive source version for consumers that need an aggregate state
        /// dependency; `setSource` invalidates its dependents on every transition.
        pub fn stateVersion(self: *Self) !u64 {
            return self.ctx.getSource(self.state_source);
        }
    };
}

test "async latest durable shell publishes state revisions" {
    const Ctx = ac.AsyncContext(u64);
    var context = Ctx.init(std.testing.allocator);
    defer context.deinit();
    var projection = try AsyncLatestDurableProjection([]const u8, []const u8).init(&context, 1);
    defer projection.deinit();
    _ = try projection.upsert_desired("doc", 1, "A");
    try std.testing.expectEqual(@as(u64, 1), try projection.stateVersion());
}
