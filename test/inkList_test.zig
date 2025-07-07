const std = @import("std");
const Allocator = std.mem.Allocator;
const testing = std.testing;

const Engine = @import("InkList_lib").Engine;
const Message = @import("InkList_lib").Message;

// Represents a stored message with sender information and payload.
const StoredMessage = struct {
    sender_id: u64,
    sequence_id: u64, // Tracks message order for sequencing.
    payload: []const u8,
};

// Defines a test actor that processes and stores messages.
const TestActor = struct {
    const Self = @This();

    allocator: Allocator,
    messages: std.ArrayList(StoredMessage),

    /// Creates a new actor with a pre-allocated message buffer.
    /// Returns a pointer to the initialized actor or an error if allocation fails.
    pub fn init(allocator: Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .messages = try std.ArrayList(StoredMessage).initCapacity(allocator, 2100),
        };
        return self;
    }

    /// Releases all stored messages and frees the actor's memory.
    pub fn deinit(self: *Self) void {
        for (self.messages.items) |item| {
            self.allocator.free(item.payload);
        }
        self.messages.deinit();
        self.allocator.destroy(self);
    }

    /// Processes an incoming message, storing custom payloads or executing functions.
    pub fn receive(self: *Self, allocator: Allocator, msg: *Message) void {
        switch (msg.instruction) {
            .custom => |str| {
                const copied_str = allocator.dupe(u8, str) catch {
                    std.log.err("Failed to duplicate string in receive", .{});
                    return;
                };
                const stored = StoredMessage{
                    .sender_id = msg.sender_id,
                    .sequence_id = 0,
                    .payload = copied_str,
                };
                self.messages.appendAssumeCapacity(stored);
                std.log.info("Received message from {d}: {s}", .{ stored.sender_id, str });
            },
            .func => |f| {
                f.call_fn(f.context, @ptrCast(self));
            },
        }
    }
};

// Handles message processing with custom behavior for actors.
const MessageHandler = struct {
    message: StoredMessage,

    /// Appends a message to the actor's message buffer.
    /// Called as part of function-based message processing.
    fn call(context: *anyopaque, actor_ptr: *anyopaque) void {
        const self = @as(*MessageHandler, @ptrCast(@alignCast(context)));
        const actor = @as(*TestActor, @ptrCast(@alignCast(actor_ptr)));

        const copied_str = actor.allocator.dupe(u8, self.message.payload) catch {
            std.log.err("Failed to duplicate string in handler", .{});
            return;
        };
        const stored = StoredMessage{
            .sender_id = self.message.sender_id,
            .sequence_id = self.message.sequence_id,
            .payload = copied_str,
        };
        actor.messages.appendAssumeCapacity(stored);
        std.log.info("Handler appended message from {d}", .{self.message.sender_id});
    }

    /// Frees the handler's stored payload and the handler itself.
    fn deinit(context: *anyopaque, allocator: Allocator) void {
        const self = @as(*MessageHandler, @ptrCast(@alignCast(context)));
        allocator.free(self.message.payload);
        allocator.destroy(self);
    }

    /// Creates a deep copy of the handler, duplicating its payload.
    /// Returns a pointer to the cloned handler or an error if allocation fails.
    fn clone(context: *anyopaque, allocator: Allocator) !*anyopaque {
        const self = @as(*MessageHandler, @ptrCast(@alignCast(context)));
        const new_self = try allocator.create(MessageHandler);
        new_self.* = .{
            .message = .{
                .sender_id = self.message.sender_id,
                .sequence_id = self.message.sequence_id,
                .payload = try allocator.dupe(u8, self.message.payload),
            },
        };
        return @ptrCast(new_self);
    }
};

// Tests the initialization of the engine with specified parameters.
test "Initialize engine" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();
}

// Verifies that an actor can be spawned successfully.
test "Spawn actor" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const actor_id = try engine.spawnActor(TestActor);
    std.log.info("Spawned actor with ID {d}", .{actor_id});

    // can poison actor, engine.deinit() would handle it
    try engine.poisonActor(TestActor, actor_id);
}

// Tests sending and receiving a single custom message.
test "Send and receive one message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const actor_id = try engine.spawnActor(TestActor);

    const msg = try Message.makeCustomPayload(allocator, 42, "Hello");
    try engine.sendMessage(actor_id, msg);
    try engine.waitForActor(actor_id);

    const actor = try engine.getActorState(TestActor, actor_id);
    try std.testing.expectEqual(@as(usize, 1), actor.messages.items.len);
    try std.testing.expectEqualStrings("Hello", actor.messages.items[0].payload);
    
    // can poison actor, engine.deinit() would handle it
    try engine.poisonActor(TestActor, actor_id);
}

// Tests sending and receiving a message with a handler function.
test "Send and receive handler message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const actor_id = try engine.spawnActor(TestActor);

    const handler = try allocator.create(MessageHandler);
    handler.* = .{
        .message = StoredMessage{
            .sender_id = 42,
            .sequence_id = 0,
            .payload = try allocator.dupe(u8, "Func Hello"),
        },
    };

    const msg = try Message.makeFuncPayload(
        allocator,
        42,
        &MessageHandler.call,
        @ptrCast(handler),
        &MessageHandler.deinit,
        &MessageHandler.clone,
    );
    try engine.sendMessage(actor_id, msg);
    try engine.waitForActor(actor_id);

    const actor = try engine.getActorState(TestActor, actor_id);
    try std.testing.expectEqual(@as(usize, 1), actor.messages.items.len);
    try std.testing.expectEqualStrings("Func Hello", actor.messages.items[0].payload);
}

// Verifies the creation of a custom message with correct payload and sender ID.
test "Create custom message" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const msg = try Message.makeCustomPayload(allocator, 42, "Test Custom");
    defer msg.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), msg.sender_id);
    try std.testing.expectEqualStrings("Test Custom", msg.instruction.custom);
}

// Tests multiple actors receiving multiple messages concurrently.
test "Multiple actors and messages" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const actor1_id = try engine.spawnActor(TestActor);
    const actor2_id = try engine.spawnActor(TestActor);

    const payloads = [_][]const u8{ "msg1", "msg2", "msg3", "msg4" };
    for (payloads, 0..) |msg, i| {
        const m1 = try Message.makeCustomPayload(allocator, 100 + @as(u64, @intCast(i)), msg);
        try engine.sendMessage(actor1_id, m1);
        const m2 = try Message.makeCustomPayload(allocator, 200 + @as(u64, @intCast(i)), msg);
        try engine.sendMessage(actor2_id, m2);
    }

    try engine.waitForActor(actor1_id);
    try engine.waitForActor(actor2_id);

    const actor1 = try engine.getActorState(TestActor, actor1_id);
    const actor2 = try engine.getActorState(TestActor, actor2_id);
    try std.testing.expectEqual(payloads.len, actor1.messages.items.len);
    try std.testing.expectEqual(payloads.len, actor2.messages.items.len);
}

// Ensures messages are received by an actor in the correct order.
test "Actor receives messages in order" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const actor_id = try engine.spawnActor(TestActor);

    const size: u64 = 5;
    for (0..size) |i| {
        const msg = try Message.makeCustomPayload(allocator, @as(u64, @intCast(i)), "msg");
        try engine.sendMessage(actor_id, msg);
    }

    try engine.waitForActor(actor_id);

    const actor = try engine.getActorState(TestActor, actor_id);
    try std.testing.expectEqual(@as(usize, size), actor.messages.items.len);
}

// Tests the system's ability to handle a high volume of concurrent messages.
test "High volume of concurrent messages" {
    const NUM_MESSAGES = 1000;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const actor_id = try engine.spawnActor(TestActor);
    const actor_id_two = try engine.spawnActor(TestActor);

    for (0..NUM_MESSAGES) |i| {
        const msg = try Message.makeCustomPayload(allocator, @as(u64, @intCast(i)), "bulk");
        try engine.sendMessage(actor_id, msg);

        const msg_two = try Message.makeCustomPayload(allocator, @as(u64, @intCast(i)), "bulk");
        try engine.sendMessage(actor_id_two, msg_two);
    }

    try engine.waitForActor(actor_id);
    try engine.waitForActor(actor_id_two);

    const actor = try engine.getActorState(TestActor, actor_id);
    const actor_two = try engine.getActorState(TestActor, actor_id_two);
    try std.testing.expectEqual(@as(usize, NUM_MESSAGES), actor.messages.items.len);
    try std.testing.expectEqual(@as(usize, NUM_MESSAGES), actor_two.messages.items.len);
}

// Tests sending multiple handler-based messages and verifies order.
test "Send multiple handler messages" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var engine = try Engine.init(allocator, .{ .allocator = allocator, .n_jobs = 4 }, 16);
    defer engine.deinit();

    const actor_id = try engine.spawnActor(TestActor);

    const payloads = [_][]const u8{ "msgA", "msgB", "msgC" };
    for (payloads, 0..) |p, i| {
        const handler = try allocator.create(MessageHandler);
        handler.* = .{
            .message = StoredMessage{
                .sender_id = @as(u64, @intCast(i)),
                .sequence_id = i,
                .payload = try allocator.dupe(u8, p),
            },
        };

        const msg = try Message.makeFuncPayload(
            allocator,
            @as(u64, @intCast(i)),
            &MessageHandler.call,
            @ptrCast(handler),
            &MessageHandler.deinit,
            &MessageHandler.clone,
        );
        try engine.sendMessage(actor_id, msg);
    }

    try engine.waitForActor(actor_id);

    const actor = try engine.getActorState(TestActor, actor_id);
    try std.testing.expectEqual(@as(usize, payloads.len), actor.messages.items.len);

    // Sorts messages by sequence_id to verify correct ordering.
    std.sort.heap(StoredMessage, actor.messages.items, {}, struct {
        fn lessThan(_: void, a: StoredMessage, b: StoredMessage) bool {
            return a.sequence_id < b.sequence_id;
        }
    }.lessThan);

    for (payloads, 0..) |p, i| {
        try std.testing.expectEqualStrings(p, actor.messages.items[i].payload);
    }
}

// Tests direct invocation of a handler function.
test "Direct handler call" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const actor = try TestActor.init(allocator);
    defer actor.deinit();

    const payload = StoredMessage{
        .sender_id = 99,
        .sequence_id = 0,
        .payload = try allocator.dupe(u8, "direct"),
    };

    const handler = try allocator.create(MessageHandler);
    defer allocator.free(payload.payload);
    defer allocator.destroy(handler);
    handler.* = .{ .message = payload };

    MessageHandler.call(@ptrCast(handler), @ptrCast(actor));

    try std.testing.expectEqual(@as(usize, 1), actor.messages.items.len);
    try std.testing.expectEqualStrings("direct", actor.messages.items[0].payload);
}

// Verifies that handler cloning correctly duplicates all fields.
test "Handler clone duplicates correctly" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const original = try allocator.create(MessageHandler);
    original.* = .{
        .message = .{
            .sender_id = 1,
            .sequence_id = 0,
            .payload = try allocator.dupe(u8, "clone test"),
        },
    };

    const clone_ptr = try MessageHandler.clone(@ptrCast(original), allocator);
    defer MessageHandler.deinit(clone_ptr, allocator);

    const clone = @as(*MessageHandler, @ptrCast(@alignCast(clone_ptr)));
    try std.testing.expectEqualStrings("clone test", clone.message.payload);
    try std.testing.expectEqual(@as(u64, 1), clone.message.sender_id);
    try std.testing.expectEqual(@as(u64, 0), clone.message.sequence_id);

    MessageHandler.deinit(@ptrCast(original), allocator);
}
