const std = @import("std");
const Allocator = std.mem.Allocator;
const Mutex = std.Thread.Mutex;
const AtomicI32 = std.atomic.Value(i32);

const ConcurrentHashMap = @import("concurrentHashMap.zig").ConcurrentHashMap;
const Actor = @import("actor.zig").Actor;
const Message = @import("message.zig").Message;

/// Manages an actor's lifecycle with function pointers for sending messages, waiting, and cleanup.
const ActorHandle = struct {
    actor_ptr: *anyopaque,
    send_fn: *const fn (actor_ptr: *anyopaque, msg: *Message) anyerror!void,
    wait_fn: *const fn (actor_ptr: *anyopaque) void,
    deinit_fn: *const fn (actor_ptr: *anyopaque) void,

    /// Creates a handle for an actor of type TStruct, binding its methods.
    fn create(comptime TStruct: type, actor: *Actor(TStruct), allocator: Allocator) !*ActorHandle {
        const handle = try allocator.create(ActorHandle);
        handle.* = ActorHandle{
            .actor_ptr = actor,
            .send_fn = &struct {
                fn send(actor_ptr: *anyopaque, msg: *Message) anyerror!void {
                    const typed_actor = @as(*Actor(TStruct), @ptrCast(@alignCast(actor_ptr)));
                    try typed_actor.receive(msg);
                }
            }.send,
            .wait_fn = &struct {
                fn wait(actor_ptr: *anyopaque) void {
                    const typed_actor = @as(*Actor(TStruct), @ptrCast(@alignCast(actor_ptr)));
                    typed_actor.wait();
                }
            }.wait,
            .deinit_fn = &struct {
                fn deinit(actor_ptr: *anyopaque) void {
                    const typed_actor = @as(*Actor(TStruct), @ptrCast(@alignCast(actor_ptr)));
                    typed_actor.deinit();
                }
            }.deinit,
        };
        return handle;
    }
};

/// Periodically sends messages to an actor until stopped.
const PeriodicSender = struct {
    engine: *Engine,
    actor_id: i32,
    msg: *Message,
    delay_ns: u64,
    stop_flag: std.atomic.Value(bool),
    thread_pool: *std.Thread.Pool,
    wait_group: std.Thread.WaitGroup,

    /// Initializes a sender to periodically deliver a cloned message to an actor.
    pub fn init(allocator: Allocator, engine: *Engine, actor_id: i32, msg: *Message, delay_ns: u64) !*PeriodicSender {
        if (delay_ns == 0) return error.InvalidDelay;
        const self = try allocator.create(PeriodicSender);
        const cloned_msg = try msg.clone(allocator);
        self.* = PeriodicSender{
            .engine = engine,
            .actor_id = actor_id,
            .msg = cloned_msg,
            .delay_ns = delay_ns,
            .stop_flag = std.atomic.Value(bool).init(false),
            .thread_pool = engine.thread_pool,
            .wait_group = .{}, // Initialize synchronization primitive
        };
        return self;
    }

    /// Starts the periodic sender in a separate thread.
    pub fn start(self: *PeriodicSender) !void {
        self.wait_group.reset(); // Prepare synchronization
        self.wait_group.start(); // Mark task as active
        try self.thread_pool.spawn(run, .{self});
    }

    /// Runs the periodic sending loop, cloning and sending messages until stopped.
    fn run(self: *PeriodicSender) void {
        defer self.wait_group.finish(); // Signal completion when done
        while (!self.stop_flag.load(.acquire)) {
            std.time.sleep(self.delay_ns);
            if (self.stop_flag.load(.acquire)) break;
            const cloned_msg = self.msg.clone(self.engine.allocator) catch |err| {
                std.log.err("Failed to clone message: {}", .{err});
                continue;
            };
            self.engine.sendMessage(self.actor_id, cloned_msg) catch |err| {
                std.log.err("Failed to send periodic message to actor {d}: {}", .{ self.actor_id, err });
            };
        }
    }

    /// Stops the sender, waits for completion, and cleans up resources.
    pub fn stop(self: *PeriodicSender) void {
        self.stop_flag.store(true, .release);
        self.wait_group.wait(); // Ensure thread completes
        self.msg.deinit(self.engine.allocator);
        self.engine.allocator.destroy(self);
    }
};

/// Manages a collection of actors, handling their creation, messaging, and cleanup.
pub const Engine = struct {
    const Self = @This();
    const ActorMap = ConcurrentHashMap(i32, *ActorHandle, std.hash_map.AutoContext(i32));

    allocator: Allocator,
    actors: ActorMap,
    next_actor_id: AtomicI32,
    mutex: Mutex,
    thread_pool: *std.Thread.Pool,

    /// Initializes the engine with a thread pool and actor storage.
    pub fn init(allocator: Allocator, thread_pool_options: std.Thread.Pool.Options, initial_size: u64) !Self {
        const thread_pool = try allocator.create(std.Thread.Pool);
        errdefer allocator.destroy(thread_pool);

        try thread_pool.init(thread_pool_options);
        errdefer thread_pool.deinit();

        // Set up actor storage with initial capacity
        const actors = try ActorMap.init(allocator, initial_size, .{});

        return Self{
            .allocator = allocator,
            .actors = actors,
            .next_actor_id = AtomicI32.init(0),
            .mutex = .{},
            .thread_pool = thread_pool,
        };
    }

    /// Spawns a new actor of type TStruct, assigning a unique ID.
    pub fn spawnActor(self: *Self, comptime TStruct: type) !i32 {
        comptime {
            if (!@hasDecl(TStruct, "init")) @compileError("TStruct must implement 'init' method.");
            if (!@hasDecl(TStruct, "deinit")) @compileError("TStruct must implement 'deinit' method.");
            if (!@hasDecl(TStruct, "receive")) @compileError("TStruct must implement 'receive' method.");
        }

        const actor_id = self.next_actor_id.fetchAdd(1, .monotonic);

        const t_struct = try TStruct.init(self.allocator);
        errdefer t_struct.deinit();

        const actor = try Actor(TStruct).init(self.allocator, t_struct, actor_id, self.thread_pool);
        const handle = try ActorHandle.create(TStruct, actor, self.allocator);

        try self.actors.put(actor_id, handle);

        return actor_id;
    }

    /// Sends a message to the actor with the specified ID.
    pub fn sendMessage(self: *Self, actor_id: i32, msg: *Message) !void {
        if (self.actors.get(actor_id)) |handle_ptr| {
            try handle_ptr.send_fn(handle_ptr.actor_ptr, msg);
        } else {
            return error.ActorNotFound;
        }
    }

    /// Starts a periodic sender to deliver messages to an actor at regular intervals.
    pub fn sendEvery(self: *Self, actor_id: i32, msg: *Message, delay_ns: u64) !*PeriodicSender {
        const sender = try PeriodicSender.init(self.allocator, self, actor_id, msg, delay_ns);
        try sender.start();
        return sender;
    }

    /// Waits for the specified actor to complete processing.
    pub fn waitForActor(self: *Self, actor_id: i32) !void {
        if (self.actors.get(actor_id)) |handle_ptr| {
            handle_ptr.wait_fn(handle_ptr.actor_ptr);
        } else {
            return error.ActorNotFound;
        }
    }

    /// Retrieves the state of the actor with the specified ID.
    pub fn getActorState(self: *Self, comptime TStruct: type, actor_id: i32) !*TStruct {
        if (self.actors.get(actor_id)) |handle_ptr| {
            const actor = @as(*Actor(TStruct), @ptrCast(@alignCast(handle_ptr.actor_ptr)));
            return actor.t_struct;
        } else {
            return error.ActorNotFound;
        }
    }

    /// Cleans up all actors by deinitializing and removing them.
    fn poisonAll(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = self.actors.iterator();
        defer iter.deinit();

        while (iter.next()) |entry| {
            entry.value.deinit_fn(entry.value.actor_ptr);
            self.allocator.destroy(entry.value);
            _ = self.actors.remove(entry.key);
        }
    }

    /// Deinitializes the engine, cleaning up all resources.
    pub fn deinit(self: *Self) void {
        self.poisonAll();
        self.thread_pool.deinit();
        self.allocator.destroy(self.thread_pool);
        self.actors.deinit();
    }
};
