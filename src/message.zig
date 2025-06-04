const std = @import("std");
const Allocator = std.mem.Allocator;

/// Errors that can occur when working with Messages.
pub const MessageError = error{
    AllocationFailed,
    CannotCloneFuncPayload,
    InvalidPayload,
};

/// Represensts the payload for each message.
/// Either custom or function call, func
/// The func is stored as a function pointer with a call_fn, context, deinit, and clone
pub const InstructionPayload = union(enum) {
    custom: []const u8,
    func: struct {
        call_fn: *const fn (*anyopaque, *anyopaque) void,
        context: *anyopaque,
        deinit_fn: ?*const fn (*anyopaque, Allocator) void = null,
        clone_fn: ?*const fn (*anyopaque, Allocator) Allocator.Error!*anyopaque = null,
    },
};

/// Messages contain sender id and instruction payloads to process
pub const Message = struct {
    const Self = @This();
    sender_id: i32,
    instruction: InstructionPayload,

    /// Creates a new Message with the given sender ID and instruction.
    /// Allocates memory using the provided allocator
    pub fn init(allocator: Allocator, sender_id: i32, instruction: InstructionPayload) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .sender_id = sender_id, .instruction = instruction };
        return self;
    }

    /// Deinitializes the Message, freeing associated resources.
    pub fn deinit(self: *Self, allocator: Allocator) void {
        switch (self.instruction) {
            .custom => |str| allocator.free(str), // Free the duplicated string
            .func => |f| {
                if (f.deinit_fn) |df| {
                    df(f.context, allocator);
                }
            },
        }
        allocator.destroy(self);
    }

    /// Creates a deep copy of the Message using the provided allocator.
    pub fn clone(self: *const Self, allocator: Allocator) !*Self {
        const new_msg = try allocator.create(Self);
        new_msg.sender_id = self.sender_id;
        new_msg.instruction = switch (self.instruction) {
            .custom => |str| InstructionPayload{ .custom = try allocator.dupe(u8, str) }, // Duplicate the string
            .func => |f| blk: {
                if (f.clone_fn) |cf| {
                    const new_context = try cf(f.context, allocator);
                    break :blk InstructionPayload{
                        .func = .{
                            .call_fn = f.call_fn,
                            .context = new_context,
                            .deinit_fn = f.deinit_fn,
                            .clone_fn = f.clone_fn,
                        },
                    };
                } else {
                    allocator.destroy(new_msg);
                    return error.CannotCloneFuncPayload;
                }
            },
        };
        return new_msg;
    }

    /// Creates a Message with a function-based payload.
    pub fn makeFuncPayload(
        allocator: Allocator,
        sender_id: i32,
        call_fn: *const fn (*anyopaque, *anyopaque) void,
        context: *anyopaque,
        deinit_fn: ?*const fn (*anyopaque, Allocator) void,
        clone_fn: ?*const fn (*anyopaque, Allocator) Allocator.Error!*anyopaque,
    ) !*Self {
        const msg = try allocator.create(Self);
        msg.* = .{
            .sender_id = sender_id,
            .instruction = InstructionPayload{
                .func = .{
                    .call_fn = call_fn,
                    .context = context,
                    .deinit_fn = deinit_fn,
                    .clone_fn = clone_fn,
                },
            },
        };
        return msg;
    }

    /// Creates a Message with a custom string payload.
    pub fn makeCustomPayload(allocator: Allocator, sender_id: i32, custom: []const u8) !*Self {
        const msg = try allocator.create(Self);
        const duped_custom = try allocator.dupe(u8, custom); // Duplicate the string
        msg.* = .{
            .sender_id = sender_id,
            .instruction = InstructionPayload{ .custom = duped_custom },
        };
        return msg;
    }
};
