# InkList

InkList is an actor model written in Zig. It is done in a way to provide a nice blueprint for consistent coding as well as performance.
Users can make their structs into actors and then send them messages through the engine.


- Engine: Manages a collection of actors, message delivery, and a thread pool.

- Actor: Encapsulates per-actor state, a lock-free message queue, and worker threads.

- Message: Supports both custom‐string payloads and function‐based payloads (handlers) with deep cloning.

- PeriodicSender: Sends cloned messages to an actor at fixed intervals.

- ConcurrentHashMap: A lock‐free, thread‐safe map used internally by the Engine.

# Features
- Actor Model:
  -   Spawn lightweight actors that process messages asynchronously.

Message Payloads:
  -   Custom‐string payloads (makeCustomPayload)

  -   Function‐call payloads (makeFuncPayload) with clone & cleanup support

Lock‐Free Data Structures:
  -   LockFreeQueue per actor for message buffering

  -   ConcurrentHashMap in the Engine to store actor handles

Thread Pool:
  -   All message processing is scheduled on a shared thread pool (std.Thread.Pool).

Periodic Messaging: 
  -   sendEvery allows you to send a cloned message to an actor at a fixed nanosecond interval.

Graceful Shutdown: 
  -   Actors can be stopped, their queues drained, and resources deallocated cleanly.

### This was made with Zig version 0.14.0

# Module Overview

## Engine

- Holds a ConcurrentHashMap(i32, *ActorHandle) mapping actor_id → ActorHandle.

- Maintains a shared std.Thread.Pool for dispatching work items (message processing).

### Provides:

- spawnActor(TStruct):

- Enforces that TStruct has init, receive, deinit.

- Initializes TStruct via TStruct.init(allocator).

- Wraps it in Actor(TStruct).init(...).

- Stores an ActorHandle in the map and returns a unique actor_id.

- sendMessage(actor_id, msg): Looks up the ActorHandle and invokes its send_fn.

- sendEvery(actor_id, msg, delay_ns): Creates a PeriodicSender to send a cloned msg every delay_ns nanoseconds.

- waitForActor(actor_id): Invokes the actor’s wait method, blocking until its work is done.

- getActorState(TStruct, actor_id): Returns a pointer to the inner TStruct.

- deinit(): Cleans up all actors (calling ActorHandle.deinit_fn), shuts down the thread pool, and deallocates resources.

## Actor

- Signature: pub fn Actor(comptime TStruct: type) type { ... }

- Key Fields:

- actor_id: i32

- t_struct: *TStruct

- message_queue: *LockFreeQueue(*Message)

- wg: std.Thread.WaitGroup (for pending tasks)

- stop_flag: AtomicBool (to indicate shutdown)

- thread_pool: *std.Thread.Pool

### Core Methods:

- init(allocator, t_struct, actor_id, thread_pool): Allocates itself and a LockFreeQueue; stores t_struct.

- receive(msg):

  - Enqueues msg into message_queue.

  - Calls wg.start(), then thread_pool.spawn(processMessage, .{self}).

- processMessage:

  - Dequeues a single message.

  - Calls t_struct.receive(allocator, msg).

  - Calls msg.deinit(allocator).

  - Calls wg.finish().

- wait(): Blocks until wg.wait(), meaning all queued messages are processed.

- stop(): Sets stop_flag = true and drains the queue (deinit each message).

- deinit(): Calls stop(), then t_struct.deinit(), message_queue.deinit(), and deallocates itself.

## Message

- pub const InstructionPayload = union(enum) { custom: []const u8, func: struct { ... } };

- pub const Message = struct { sender_id: i32, instruction: InstructionPayload, ... }

### Core Methods:

- init(allocator, sender_id, instruction): Allocates a Message and stores the payload.

- makeCustomPayload(allocator, sender_id, custom: []const u8):

  - Duplicates the provided string.

  - Returns a newly allocated Message with .instruction = .{ .custom = duped_str }.

  - makeFuncPayload(allocator, sender_id, call_fn, context, deinit_fn, clone_fn):

  - Stores a function pointer, a context pointer, and optional deinit_fn & clone_fn.

- clone(allocator):

  - Deep‐copies either the custom string or (if func) calls clone_fn(context, allocator) to duplicate the context.

- deinit(allocator):

  - If .custom, allocator.free(str).

  - If .func and deinit_fn != null, call deinit_fn(context, allocator).

  - Finally call allocator.destroy(self).

## PeriodicSender
Defined inside engine.zig.

- Periodically re‐sends a cloned message to a given actor_id.

- Internally spawns a thread from the Engine’s thread pool that:

- Sleeps for delay_ns.

- Clones the original msg (msg.clone(allocator)).

- Calls engine.sendMessage(actor_id, cloned_msg).

- Maintains an AtomicBool stop_flag so you can call stop(), which:

- Sets stop_flag = true

- Waits for the spawned thread to finish

- Cleans up the cloned message and itself.

## ConcurrentHashMap

#### Type: pub const ConcurrentHashMap(KeyType, ValueType, ContextType) = std.hash_map.HashMap(KeyType, ValueType, ContextType);

#### Usage:

- The Engine uses ConcurrentHashMap(i32, *ActorHandle, AutoContext(i32)):

- Key: actor_id: i32

- Value: *ActorHandle

- Context: std.hash_map.AutoContext(i32) to manage internal hashing and bucket logic.

## LockFreeQueue

#### Type: pub const LockFreeQueue(ItemType) = /* lock‐free linked queue implementation */;

#### Usage:

- Each Actor instantiates a LockFreeQueue(*Message):

- Allows multiple threads to call enqueue(msg) and dequeue() without blocking.

- dequeue() returns the next msg or returns an error if the queue is empty.

# Installation

Clone the repo:
```git clone https://github.com/Joseph-Matteo-Scorsone/InkList.git```

## Integrate into build.zig
```
const inklist_lib = b.createModule(.{
        .root_source_file = b.path("InkList/src/root.zig"),
    });

exe.addImport("InkList_lib", inklist_lib);
```

