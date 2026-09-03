//! Latest-value durable projection authority (`#lzlatestdurableprojection`).
//!
//! A projection converges each key to its newest desired epoch. It deliberately
//! does not promise delivery of every intermediate command: pending revisions
//! conflate, while the one in-flight envelope is fenced by `generation`.
//!
//! Contract: lazily-spec v0.38.0
//! (`conformance/egress/latest_durable_projection.json`). The matching corrected
//! model is lazily-formal v0.38.1, `LazilyFormal.LatestDurableProjection`.

const std = @import("std");

pub fn HashMapFor(comptime K: type, comptime V: type) type {
    if (K == []const u8) return std.StringHashMap(V);
    return std.AutoHashMap(K, V);
}

pub fn LatestDurableRevision(comptime V: type) type {
    return struct { epoch: u64, value: V };
}

pub fn LatestDurableEnvelope(comptime K: type, comptime V: type) type {
    return struct { generation: u64, key: K, epoch: u64, value: V };
}

pub fn LatestDurableKeyState(comptime K: type, comptime V: type) type {
    return struct {
        desired: ?LatestDurableRevision(V),
        inflight: ?LatestDurableEnvelope(K, V),
        durable_through: ?u64,
    };
}

pub fn LatestDurableSnapshot(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        pub const Item = struct { key: K, state: LatestDurableKeyState(K, V) };

        generation: u64,
        entries: []Item,

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.entries);
            self.* = undefined;
        }
    };
}

pub const LatestDurableUpsert = union(enum) {
    accepted,
    unchanged,
    already_durable: u64,
    stale_epoch: u64,
    epoch_conflict,
};

pub fn LatestDurableClaim(comptime K: type, comptime V: type) type {
    return union(enum) {
        claimed: LatestDurableEnvelope(K, V),
        empty,
        busy,
        stale_generation: u64,
    };
}

pub const LatestDurableAck = union(enum) {
    advanced: u64,
    unchanged: u64,
    unknown_epoch,
    stale_generation: u64,
};

pub const LatestDurableFailure = union(enum) {
    pending,
    superseded,
    unknown_epoch,
    stale_generation: u64,
};

pub const LatestDurableReconnect = union(enum) {
    advanced: struct { generation: u64, requeued: usize, superseded: usize },
    unchanged: u64,
    stale_generation: u64,
};

pub const LatestDurableChange = struct {
    state: bool = false,
};

pub fn LatestDurableTransition(comptime Outcome: type) type {
    return struct { change: LatestDurableChange, outcome: Outcome };
}

/// Pure keyed state machine. Slice keys and values are borrowed and must outlive
/// the core, matching the ownership convention of the other Zig collection
/// cores.
pub fn LatestDurableProjectionCore(comptime K: type, comptime V: type) type {
    return struct {
        const Self = @This();
        const Revision = LatestDurableRevision(V);
        const Envelope = LatestDurableEnvelope(K, V);
        const KeyState = LatestDurableKeyState(K, V);

        const Entry = struct {
            desired: ?Revision = null,
            inflight: ?Envelope = null,
            durable_through: ?u64 = null,

            fn state(self: Entry) KeyState {
                return .{
                    .desired = self.desired,
                    .inflight = self.inflight,
                    .durable_through = self.durable_through,
                };
            }
        };

        allocator: std.mem.Allocator,
        current_generation: u64,
        entries: HashMapFor(K, Entry),

        pub fn init(allocator: std.mem.Allocator, initial_generation: u64) Self {
            return .{
                .allocator = allocator,
                .current_generation = initial_generation,
                .entries = HashMapFor(K, Entry).init(allocator),
            };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit();
        }

        pub fn generation(self: *const Self) u64 {
            return self.current_generation;
        }

        pub fn count(self: *const Self) usize {
            return self.entries.count();
        }

        pub fn state(self: *const Self, key: K) ?KeyState {
            const stored = self.entries.get(key) orelse return null;
            return stored.state();
        }

        pub fn durableThrough(self: *const Self, key: K) ?u64 {
            return if (self.entries.get(key)) |stored| stored.durable_through else null;
        }

        pub fn pending(self: *const Self, key: K) bool {
            return if (self.entries.get(key)) |stored|
                stored.inflight == null and stored.desired != null
            else
                false;
        }

        pub fn snapshot(self: *const Self, allocator: std.mem.Allocator) !LatestDurableSnapshot(K, V) {
            var result = LatestDurableSnapshot(K, V){
                .generation = self.current_generation,
                .entries = try allocator.alloc(LatestDurableSnapshot(K, V).Item, self.entries.count()),
            };
            errdefer result.deinit(allocator);
            var iterator = self.entries.iterator();
            var index: usize = 0;
            while (iterator.next()) |item| : (index += 1) {
                result.entries[index] = .{ .key = item.key_ptr.*, .state = item.value_ptr.state() };
            }
            return result;
        }

        fn ensureEntry(self: *Self, key: K) !*Entry {
            const slot = try self.entries.getOrPut(key);
            if (!slot.found_existing) slot.value_ptr.* = .{};
            return slot.value_ptr;
        }

        pub fn upsert_desired(
            self: *Self,
            key: K,
            epoch: u64,
            value: V,
        ) !LatestDurableTransition(LatestDurableUpsert) {
            const target = try self.ensureEntry(key);
            if (target.durable_through) |durable| {
                if (epoch <= durable) return .{
                    .change = .{},
                    .outcome = .{ .already_durable = durable },
                };
            }

            var newest_epoch: ?u64 = null;
            var newest_value: ?V = null;
            if (target.desired) |desired| {
                newest_epoch = desired.epoch;
                newest_value = desired.value;
            }
            if (target.inflight) |inflight| {
                if (newest_epoch == null or inflight.epoch > newest_epoch.?) {
                    newest_epoch = inflight.epoch;
                    newest_value = inflight.value;
                }
            }
            if (newest_epoch) |current| {
                if (epoch < current) return .{
                    .change = .{},
                    .outcome = .{ .stale_epoch = current },
                };
                if (epoch == current) return .{
                    .change = .{},
                    .outcome = if (std.meta.eql(newest_value.?, value)) .unchanged else .epoch_conflict,
                };
            }

            target.desired = .{ .epoch = epoch, .value = value };
            return .{ .change = .{ .state = true }, .outcome = .accepted };
        }

        pub fn claim(
            self: *Self,
            key: K,
            generation_: u64,
        ) !LatestDurableTransition(LatestDurableClaim(K, V)) {
            if (generation_ != self.current_generation) return .{
                .change = .{},
                .outcome = .{ .stale_generation = self.current_generation },
            };
            const target = try self.ensureEntry(key);
            if (target.inflight != null) return .{ .change = .{}, .outcome = .busy };
            const desired = target.desired orelse return .{ .change = .{}, .outcome = .empty };
            const envelope = Envelope{
                .generation = self.current_generation,
                .key = key,
                .epoch = desired.epoch,
                .value = desired.value,
            };
            target.desired = null;
            target.inflight = envelope;
            return .{ .change = .{ .state = true }, .outcome = .{ .claimed = envelope } };
        }

        pub fn ack_applied(
            self: *Self,
            key: K,
            generation_: u64,
            epoch: u64,
        ) !LatestDurableTransition(LatestDurableAck) {
            if (generation_ != self.current_generation) return .{
                .change = .{},
                .outcome = .{ .stale_generation = self.current_generation },
            };
            const target = try self.ensureEntry(key);
            if (target.inflight == null or target.inflight.?.epoch != epoch) {
                if (target.durable_through) |durable| {
                    if (epoch <= durable) return .{
                        .change = .{},
                        .outcome = .{ .unchanged = durable },
                    };
                }
                return .{ .change = .{}, .outcome = .unknown_epoch };
            }

            target.inflight = null;
            if (target.durable_through == null or epoch > target.durable_through.?) {
                target.durable_through = epoch;
                return .{
                    .change = .{ .state = true },
                    .outcome = .{ .advanced = epoch },
                };
            }
            return .{
                .change = .{ .state = true },
                .outcome = .{ .unchanged = target.durable_through.? },
            };
        }

        pub fn fail_retryable(
            self: *Self,
            key: K,
            generation_: u64,
            epoch: u64,
        ) !LatestDurableTransition(LatestDurableFailure) {
            if (generation_ != self.current_generation) return .{
                .change = .{},
                .outcome = .{ .stale_generation = self.current_generation },
            };
            const target = try self.ensureEntry(key);
            const inflight = target.inflight orelse return .{
                .change = .{},
                .outcome = .unknown_epoch,
            };
            if (inflight.epoch != epoch) return .{ .change = .{}, .outcome = .unknown_epoch };

            target.inflight = null;
            if (target.desired) |desired| {
                if (desired.epoch > inflight.epoch) return .{
                    .change = .{ .state = true },
                    .outcome = .superseded,
                };
            }
            target.desired = .{ .epoch = inflight.epoch, .value = inflight.value };
            return .{ .change = .{ .state = true }, .outcome = .pending };
        }

        pub fn reconnect(
            self: *Self,
            new_generation: u64,
        ) LatestDurableTransition(LatestDurableReconnect) {
            if (new_generation < self.current_generation) return .{
                .change = .{},
                .outcome = .{ .stale_generation = self.current_generation },
            };
            if (new_generation == self.current_generation) return .{
                .change = .{},
                .outcome = .{ .unchanged = self.current_generation },
            };

            var requeued: usize = 0;
            var superseded: usize = 0;
            var iterator = self.entries.valueIterator();
            while (iterator.next()) |target| {
                const inflight = target.inflight orelse continue;
                if (target.desired != null and target.desired.?.epoch > inflight.epoch) {
                    superseded += 1;
                } else {
                    target.desired = .{ .epoch = inflight.epoch, .value = inflight.value };
                    requeued += 1;
                }
                target.inflight = null;
            }
            self.current_generation = new_generation;
            return .{
                .change = .{ .state = true },
                .outcome = .{ .advanced = .{
                    .generation = new_generation,
                    .requeued = requeued,
                    .superseded = superseded,
                } },
            };
        }
    };
}

test "latest durable core preserves newer desire across old acknowledgement" {
    const Core = LatestDurableProjectionCore([]const u8, []const u8);
    var core = Core.init(std.testing.allocator, 1);
    defer core.deinit();

    _ = try core.upsert_desired("doc", 2, "B");
    const claimed = try core.claim("doc", 1);
    try std.testing.expect(claimed.outcome == .claimed);
    _ = try core.upsert_desired("doc", 3, "C");
    const acked = try core.ack_applied("doc", 1, 2);
    try std.testing.expectEqual(@as(u64, 2), acked.outcome.advanced);
    const state = core.state("doc").?;
    try std.testing.expectEqual(@as(u64, 3), state.desired.?.epoch);
    try std.testing.expectEqual(@as(u64, 2), state.durable_through.?);
}
