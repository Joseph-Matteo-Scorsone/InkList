const std = @import("std");
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;

pub const QueueError = error{
    QueueCorrupted,
    QueueEmpty,
};

pub fn Node(comptime T: type) type {
    return struct {
        const Self = @This();
        data: T,
        next: ?*Self,

        pub fn init(allocator: Allocator, T_data: ?T) !*Node(T) {
            const node = try allocator.create(Node(T));
            node.* = .{
                .data = T_data orelse undefined,
                .next = null,
            };
            return node;
        }
    };
}

pub fn LockFreeQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        head: Atomic(?*Node(T)),
        tail: Atomic(?*Node(T)),
        allocator: Allocator,

        pub fn init(allocator: Allocator) !*LockFreeQueue(T) {
            const initial_null = try Node(T).init(allocator, null);
            const queue = try allocator.create(LockFreeQueue(T));
            queue.* = .{
                .head = Atomic(?*Node(T)).init(initial_null),
                .tail = Atomic(?*Node(T)).init(initial_null),
                .allocator = allocator,
            };
            return queue;
        }

        pub fn deinit(self: *Self) void {
            var current: ?*Node(T) = self.head.load(.seq_cst);
            while (current) |node| {
                const next = node.next;
                self.allocator.destroy(node);
                current = next;
            }
            self.allocator.destroy(self);
        }

        pub fn enqueue(self: *Self, T_data: T) !void {
            const node = try Node(T).init(self.allocator, T_data);
            while (true) {
                const tail = self.tail.load(.seq_cst) orelse return error.QueueCorrupted;
                const next = tail.next;
                if (tail == self.tail.load(.acquire)) {
                    if (next == null) {
                        if (@cmpxchgStrong(?*Node(T), &tail.next, null, node, .seq_cst, .acquire) == null) {
                            _ = self.tail.cmpxchgStrong(tail, node, .seq_cst, .acquire);
                            return;
                        }
                    } else {
                        _ = self.tail.cmpxchgStrong(tail, next, .seq_cst, .acquire);
                    }
                }
            }
        }

        pub fn dequeue(self: *Self) !T {
            while (true) {
                const head = self.head.load(.seq_cst) orelse return error.QueueCorrupted;
                const next = head.next orelse return error.QueueEmpty;

                if (self.head.cmpxchgStrong(head, next, .seq_cst, .acquire) == null) {
                    const data = next.data;
                    self.allocator.destroy(head);
                    return data;
                }
            }
        }
    };
}
