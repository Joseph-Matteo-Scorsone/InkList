const std = @import("std");
const Allocator = std.mem.Allocator;
const WaitGroup = std.Thread.WaitGroup;
const AtomicBool = std.atomic.Value(bool);
const Mutex = std.Thread.Mutex;

const LockFreeQueue = @import("lockFreeQueue.zig").LockFreeQueue;
const Message = @import("message.zig").Message;

/// Creates an actor for a given type TStruct, managing message processing and lifecycle.
pub fn Actor(comptime TStruct: type) type {
    comptime {
        if (!@hasDecl(TStruct, "receive")) {
            @compileError("TStruct must implement 'receive' method.");
        }
        if (!@hasDecl(TStruct, "init")) {
            @compileError("TStruct must implement 'init' method.");
        }
        if (!@hasDecl(TStruct, "deinit")) {
            @compileError("TStruct must implement 'deinit' method.");
        }
    }

    return struct {
        const Self = @This();

        actor_id: i32,
        allocator: Allocator,
        t_struct: *TStruct,
        message_queue: *LockFreeQueue(*Message),
        wg: WaitGroup,
        queue_mutex: Mutex,
        stop_flag: AtomicBool,
        thread_pool: *std.Thread.Pool,

        /// Initializes an actor with a lock-free message queue and thread pool.
        pub fn init(allocator: Allocator, t_struct: *TStruct, actor_id: i32, thread_pool: *std.Thread.Pool) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const queue = try LockFreeQueue(*Message).init(allocator);

            self.* = Self{
                .actor_id = actor_id,
                .allocator = allocator,
                .t_struct = t_struct,
                .message_queue = queue,
                .wg = .{}, // Initialize synchronization primitive
                .queue_mutex = .{},
                .stop_flag = AtomicBool.init(false),
                .thread_pool = thread_pool,
            };

            return self;
        }

        /// Enqueues a message for processing and spawns a worker thread.
        pub fn receive(self: *Self, msg: *Message) !void {
            try self.message_queue.enqueue(msg);
            self.wg.start(); // Mark task as active
            try self.thread_pool.spawn(processMessage, .{self});
        }

        /// Processes a single message from the queue, invoking the TStruct's receive method.
        fn processMessage(self: *Self) void {
            const msg = self.message_queue.dequeue() catch return;
            defer self.wg.finish(); // Signal task completion
            self.t_struct.receive(self.allocator, msg);
            msg.deinit(self.allocator);
        }

        /// Waits for all queued messages to be processed.
        pub fn wait(self: *Self) void {
            self.wg.wait();
        }

        /// Stops the actor, clearing the message queue and preventing further processing.
        pub fn stop(self: *Self) void {
            self.stop_flag.store(true, .release);

            while (true) {
                const msg = self.message_queue.dequeue() catch break;
                msg.deinit(self.allocator);
            }
        }

        /// Cleans up the actor, its message queue, and underlying TStruct.
        pub fn deinit(self: *Self) void {
            self.stop();
            self.t_struct.deinit();
            self.message_queue.deinit();
            self.allocator.destroy(self);
        }
    };
}
