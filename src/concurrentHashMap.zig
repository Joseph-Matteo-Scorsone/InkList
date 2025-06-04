const std = @import("std");
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;

// Defines a generic Node structure for the hashmap, holding a key-value pair and a pointer to the next node in the chain.
pub fn Node(comptime K: type, comptime V: type) type {
    return struct {
        key: K, // The key associated with this node
        value: V, // The value associated with this node
        next: ?*Node(K, V), // Pointer to the next node in case of collisions (chaining)
    };
}

// Defines a generic ConcurrentHashMap with thread-safe operations and dynamic resizing.
pub fn ConcurrentHashMap(comptime K: type, comptime V: type, comptime Context: type) type {
    return struct {
        const Self = @This();
        buckets: Atomic(*[]?*Node(K, V)), // Atomic pointer to the array of buckets for thread-safe access
        allocator: Allocator, // Memory allocator for dynamic memory management
        mutex: std.Thread.Mutex, // Mutex to synchronize resizing and iteration
        size: Atomic(usize), // Number of buckets in the hashmap
        count: Atomic(usize), // Number of key-value pairs stored
        resizing: Atomic(bool), // Flag to indicate if resizing is in progress
        ctx: Context, // Context for hashing and equality comparison

        // Iterator structure for safely traversing the hashmap's key-value pairs.
        pub const Iterator = struct {
            map: *Self, // Reference to the hashmap being iterated
            bucket_index: usize, // Current bucket index being processed
            current_node: ?*Node(K, V), // Current node in the bucket's linked list

            // Initializes an iterator for the hashmap, locking the mutex to ensure thread safety during iteration.
            pub fn init(map: *Self) Iterator {
                map.mutex.lock(); // Prevent modifications during iteration
                return Iterator{
                    .map = map,
                    .bucket_index = 0,
                    .current_node = null,
                };
            }

            // Releases the mutex when iteration is complete, ensuring thread safety.
            pub fn deinit(self: *Iterator) void {
                self.map.mutex.unlock(); // Allow modifications after iteration
            }

            // Retrieves the next key-value pair in the iteration, or null if none remain.
            pub fn next(self: *Iterator) ?struct { key: K, value: V } {
                // Process nodes in the current bucket's linked list
                if (self.current_node) |node| {
                    self.current_node = node.next; // Move to the next node
                    return .{ .key = node.key, .value = node.value };
                }

                // Move to the next non-empty bucket
                const buckets_ptr = self.map.buckets.load(.seq_cst);
                while (self.bucket_index < buckets_ptr.*.len) {
                    if (buckets_ptr.*[self.bucket_index]) |node| {
                        self.current_node = node.next; // Prepare for next node in chain
                        self.bucket_index += 1; // Move to next bucket
                        return .{ .key = node.key, .value = node.value };
                    }
                    self.bucket_index += 1; // Skip empty bucket
                }

                // No more entries; mutex remains locked until deinit
                return null;
            }
        };

        // Initializes a new ConcurrentHashMap with the specified size and allocator.
        pub fn init(allocator: Allocator, size: usize, ctx: Context) !Self {
            // Allocate bucket array and initialize to null
            const bucket_array = try allocator.alloc(?*Node(K, V), size);
            @memset(bucket_array, null);
            const buckets_ptr = try allocator.create([]?*Node(K, V));
            buckets_ptr.* = bucket_array;

            return Self{
                .buckets = Atomic(*[]?*Node(K, V)).init(buckets_ptr),
                .allocator = allocator,
                .mutex = .{},
                .size = Atomic(usize).init(size),
                .count = Atomic(usize).init(0),
                .resizing = Atomic(bool).init(false),
                .ctx = ctx,
            };
        }

        // Computes the hash index for a key using the provided context and current size.
        fn hash(self: *Self, key: K) usize {
            return @intCast(self.ctx.hash(key) % self.size.load(.seq_cst));
        }

        // Computes the hash index for a key with a specified size (used during resizing).
        fn hashWithSize(self: *Self, key: K, size: usize) usize {
            return @intCast(self.ctx.hash(key) % size);
        }

        // Compares two keys for equality using the provided context.
        fn eql(self: *Self, a: K, b: K) bool {
            return self.ctx.eql(a, b);
        }

        // Creates an iterator for traversing the hashmap's key-value pairs.
        pub fn iterator(self: *Self) Iterator {
            return Iterator.init(self);
        }

        // Inserts or updates a key-value pair in the hashmap, handling concurrency and resizing.
        pub fn put(self: *Self, key: K, value: V) !void {
            while (true) {
                // Capture current state to ensure consistency
                const buckets_ptr = self.buckets.load(.seq_cst);
                const size = self.size.load(.seq_cst);
                const bucket_idx = self.hash(key);

                // Retry if resizing is in progress or state has changed
                if (self.resizing.load(.seq_cst) or self.buckets.load(.seq_cst) != buckets_ptr or self.size.load(.seq_cst) != size) {
                    continue;
                }

                // Ensure bucket index is valid
                if (bucket_idx >= buckets_ptr.*.len) {
                    continue; // Retry if index is out of bounds
                }
                const bucket = &buckets_ptr.*[bucket_idx];

                // Check for existing key to update value
                var current = @atomicLoad(?*Node(K, V), bucket, .seq_cst);
                while (current) |node| {
                    if (self.eql(node.key, key)) {
                        @atomicStore(V, &node.value, value, .seq_cst); // Update value atomically
                        return;
                    }
                    current = node.next;
                }

                // Allocate and initialize a new node for insertion
                const new_node = try self.allocator.create(Node(K, V));
                new_node.* = Node(K, V){ .key = key, .value = value, .next = null };

                // Verify state before insertion
                if (self.buckets.load(.seq_cst) != buckets_ptr or self.size.load(.seq_cst) != size or self.resizing.load(.seq_cst)) {
                    self.allocator.destroy(new_node);
                    continue;
                }

                // Attempt atomic insertion at the head of the bucket
                new_node.next = @atomicLoad(?*Node(K, V), bucket, .seq_cst);
                if (@cmpxchgStrong(?*Node(K, V), bucket, new_node.next, new_node, .seq_cst, .seq_cst) == null) {
                    // Insertion successful, increment count
                    const new_count = self.count.fetchAdd(1, .seq_cst) + 1;
                    const load_factor = @as(f64, @floatFromInt(new_count)) / @as(f64, @floatFromInt(size));

                    // Check if resizing is needed based on load factor
                    if (load_factor > 0.75 and !self.resizing.load(.seq_cst)) {
                        // Attempt to set resizing flag atomically
                        if (@cmpxchgStrong(bool, &self.resizing.raw, false, true, .seq_cst, .seq_cst) == null) {
                            self.mutex.lock();
                            defer self.mutex.unlock();
                            // Recheck size and load factor to confirm resize necessity
                            const current_size = self.size.load(.seq_cst);
                            if (current_size == size and @as(f64, @floatFromInt(self.count.load(.seq_cst))) / @as(f64, @floatFromInt(current_size)) > 0.75) {
                                try self.resize(current_size * 2);
                            }
                            self.resizing.store(false, .seq_cst); // Reset resizing flag
                        }
                    }
                    return;
                }

                // Insertion failed, clean up and retry
                self.allocator.destroy(new_node);
                if (self.buckets.load(.seq_cst) != buckets_ptr or self.size.load(.seq_cst) != size or self.resizing.load(.seq_cst)) {
                    continue;
                }
            }
        }

        // Retrieves the value associated with a key, or null if not found.
        pub fn get(self: *Self, key: K) ?V {
            while (true) {
                // Capture current state for consistency
                const buckets_ptr = self.buckets.load(.seq_cst);
                const size = self.size.load(.seq_cst);
                const bucket_idx = self.hash(key);

                // Retry if resizing or state has changed
                if (self.resizing.load(.seq_cst) or self.buckets.load(.seq_cst) != buckets_ptr or self.size.load(.seq_cst) != size) {
                    continue;
                }

                // Ensure bucket index is valid
                if (bucket_idx >= buckets_ptr.*.len) {
                    continue;
                }
                const bucket = &buckets_ptr.*[bucket_idx];

                // Search the bucket's linked list for the key
                var current = @atomicLoad(?*Node(K, V), bucket, .seq_cst);
                while (current) |node| {
                    if (self.eql(node.key, key)) {
                        return @atomicLoad(V, &node.value, .seq_cst); // Return value atomically
                    }
                    current = node.next;
                }

                // Retry if state changed, otherwise key not found
                if (self.buckets.load(.seq_cst) != buckets_ptr or self.size.load(.seq_cst) != size or self.resizing.load(.seq_cst)) {
                    continue;
                }
                return null;
            }
        }

        // Removes a key-value pair from the hashmap, returning true if successful.
        pub fn remove(self: *Self, key: K) bool {
            while (true) {
                // Capture current state for consistency
                const buckets_ptr = self.buckets.load(.seq_cst);
                const size = self.size.load(.seq_cst);
                const bucket_idx = self.hash(key);

                // Retry if resizing or state has changed
                if (self.resizing.load(.seq_cst) or self.buckets.load(.seq_cst) != buckets_ptr or self.size.load(.seq_cst) != size) {
                    continue;
                }

                // Ensure bucket index is valid
                if (bucket_idx >= buckets_ptr.*.len) {
                    continue;
                }
                const bucket = &buckets_ptr.*[bucket_idx];

                const current_head = @atomicLoad(?*Node(K, V), bucket, .seq_cst);
                if (current_head == null) return false;

                // Check if the key is at the head of the bucket
                if (self.eql(current_head.?.key, key)) {
                    const next = current_head.?.next;
                    if (@cmpxchgStrong(?*Node(K, V), bucket, current_head, next, .seq_cst, .seq_cst) == null) {
                        self.allocator.destroy(current_head.?); // Free removed node
                        _ = self.count.fetchSub(1, .seq_cst); // Decrement count
                        return true;
                    }
                    continue;
                }

                // Search the linked list for the key
                var prev = current_head;
                var cur = prev.?.next;
                while (cur) |node| {
                    if (self.eql(node.key, key)) {
                        const next = node.next;
                        if (@cmpxchgStrong(?*Node(K, V), &prev.?.next, node, next, .seq_cst, .seq_cst) == null) {
                            self.allocator.destroy(node); // Free removed node
                            _ = self.count.fetchSub(1, .seq_cst); // Decrement count
                            return true;
                        }
                        continue;
                    }
                    prev = cur;
                    cur = node.next;
                }

                // Retry if state changed, otherwise key not found
                if (self.buckets.load(.seq_cst) != buckets_ptr or self.size.load(.seq_cst) != size or self.resizing.load(.seq_cst)) {
                    continue;
                }
                return false;
            }
        }

        // Resizes the hashmap to a new size, rehashing all existing entries.
        pub fn resize(self: *Self, new_size: usize) !void {
            // Assumes mutex is held and resizing flag is set
            const current_size = self.size.load(.seq_cst);
            if (new_size <= current_size) return; // No resize needed if new size is smaller or equal

            // Allocate new bucket array
            const new_bucket_array = try self.allocator.alloc(?*Node(K, V), new_size);
            @memset(new_bucket_array, null);
            const new_buckets_ptr = try self.allocator.create([]?*Node(K, V));
            new_buckets_ptr.* = new_bucket_array;

            const old_buckets_ptr = self.buckets.load(.seq_cst);

            // Rehash all nodes into the new bucket array
            for (old_buckets_ptr.*) |bucket| {
                var current = bucket;
                while (current) |node| {
                    const next = node.next;
                    const new_idx = self.hashWithSize(node.key, new_size);
                    node.next = new_buckets_ptr.*[new_idx]; // Insert at head of new bucket
                    new_buckets_ptr.*[new_idx] = node;
                    current = next;
                }
            }

            // Update size and buckets atomically
            self.size.store(new_size, .seq_cst);
            self.buckets.store(new_buckets_ptr, .seq_cst);

            // Free old bucket array and pointer
            self.allocator.free(old_buckets_ptr.*);
            self.allocator.destroy(old_buckets_ptr);
        }

        // Deallocates all resources used by the hashmap.
        pub fn deinit(self: *Self) void {
            const buckets_ptr = self.buckets.load(.seq_cst);
            // Free all nodes in each bucket
            for (buckets_ptr.*) |bucket| {
                var current = bucket;
                while (current) |node| {
                    const next = node.next;
                    self.allocator.destroy(node); // Free each node
                    current = next;
                }
            }
            // Free bucket array and pointer
            self.allocator.free(buckets_ptr.*);
            self.allocator.destroy(buckets_ptr);
        }
    };
}
