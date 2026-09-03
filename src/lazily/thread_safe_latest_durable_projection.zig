//! Thread-safe latest-durable projection shell.

const std = @import("std");
const ParkingMutex = @import("parking_mutex.zig").ParkingMutex;
const core_mod = @import("latest_durable_projection_core.zig");

/// Serializes the shared core and publishes a monotone atomic state version.
/// Sink I/O happens after `claim`, outside this lock.
pub fn ThreadSafeLatestDurableProjection(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Core = core_mod.LatestDurableProjectionCore(K, V);
        pub const KeyState = core_mod.LatestDurableKeyState(K, V);
        pub const Claim = core_mod.LatestDurableClaim(K, V);

        mutex: ParkingMutex = ParkingMutex.init(),
        core: Core,
        state_version: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        pub fn init(allocator: std.mem.Allocator, initial_generation: u64) Self {
            return .{ .core = Core.init(allocator, initial_generation) };
        }

        pub fn deinit(self: *Self) void {
            self.core.deinit();
        }

        fn publish(self: *Self, change: core_mod.LatestDurableChange) void {
            if (change.state) _ = self.state_version.fetchAdd(1, .monotonic);
        }

        pub fn upsert_desired(self: *Self, key: K, epoch: u64, value: V) !core_mod.LatestDurableUpsert {
            self.mutex.lock();
            defer self.mutex.unlock();
            const transition = try self.core.upsert_desired(key, epoch, value);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn claim(self: *Self, key: K, actor_generation: u64) !Claim {
            self.mutex.lock();
            defer self.mutex.unlock();
            const transition = try self.core.claim(key, actor_generation);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn ack_applied(self: *Self, key: K, actor_generation: u64, epoch: u64) !core_mod.LatestDurableAck {
            self.mutex.lock();
            defer self.mutex.unlock();
            const transition = try self.core.ack_applied(key, actor_generation, epoch);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn fail_retryable(self: *Self, key: K, actor_generation: u64, epoch: u64) !core_mod.LatestDurableFailure {
            self.mutex.lock();
            defer self.mutex.unlock();
            const transition = try self.core.fail_retryable(key, actor_generation, epoch);
            self.publish(transition.change);
            return transition.outcome;
        }

        pub fn reconnect(self: *Self, new_generation: u64) !core_mod.LatestDurableReconnect {
            self.mutex.lock();
            defer self.mutex.unlock();
            const transition = self.core.reconnect(new_generation);
            self.publish(transition.change);
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

        pub fn stateVersion(self: *const Self) u64 {
            return self.state_version.load(.monotonic);
        }
    };
}

test "thread-safe latest durable shell fences a stale generation" {
    var projection = ThreadSafeLatestDurableProjection([]const u8, []const u8).init(std.testing.allocator, 7);
    defer projection.deinit();
    _ = try projection.upsert_desired("doc", 1, "A");
    _ = try projection.claim("doc", 7);
    _ = try projection.reconnect(8);
    const stale = try projection.ack_applied("doc", 7, 1);
    try std.testing.expectEqual(@as(u64, 8), stale.stale_generation);
}
