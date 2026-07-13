const std = @import("std");
const Allocator = std.mem.Allocator;

/// An amortized O(1) unbounded first-in, first-out (FIFO) dynamic circular ring buffer queue.
pub fn UnboundedFifo(comptime T: type) type {
    return struct {
        const Self = @This();

        buf: []T = &.{},
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.buf);
            self.* = undefined;
        }

        /// Pushes an item to the back of the FIFO, dynamically growing if full.
        pub fn addOne(self: *Self, item: T, allocator: Allocator) !void {
            if (self.count == self.buf.len) {
                try self.grow(allocator);
            }

            std.debug.assert(self.buf.len > 0 and (self.buf.len & (self.buf.len - 1)) == 0);
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) & (self.buf.len - 1);
            self.count += 1;
        }

        /// Pops an item from the front of the FIFO. Returns null if empty.
        pub fn pop(self: *Self) ?T {
            if (self.count == 0) return null;
            std.debug.assert(self.buf.len > 0 and (self.buf.len & (self.buf.len - 1)) == 0);

            const item = self.buf[self.head];
            self.head = (self.head + 1) & (self.buf.len - 1);
            self.count -= 1;

            // Reset indices if empty to keep memory linear
            if (self.count == 0) {
                self.head = 0;
                self.tail = 0;
            }

            return item;
        }

        /// Internal growth algorithm that doubles capacity and unwraps the ring buffer.
        fn grow(self: *Self, allocator: Allocator) !void {
            const old_capacity = self.buf.len;
            const new_capacity = if (old_capacity == 0) 8 else old_capacity * 2;

            // try to resize the existing buffer in-place
            if (old_capacity > 0 and allocator.resize(self.buf, new_capacity)) {
                self.buf = self.buf.ptr[0..new_capacity];

                if (self.head > 0) {
                    const first_part_len = old_capacity - self.head;
                    const second_part_len = self.head;

                    if (second_part_len < first_part_len) {
                        // copy the smaller second part to the new space to unwrap the ring
                        @memcpy(self.buf[old_capacity .. old_capacity + second_part_len], self.buf[0..second_part_len]);
                        self.tail = old_capacity + second_part_len;
                    } else {
                        // copy the smaller first part to the end of the new space
                        const dst_idx = new_capacity - first_part_len;
                        @memcpy(self.buf[dst_idx..new_capacity], self.buf[self.head..old_capacity]);
                        self.head = dst_idx;
                    }
                } else {
                    // No copying needed if data was not wrapped
                    self.tail = old_capacity;
                }
                return;
            }

            // Instead, just make new memory and copy if in-place resizing fails
            const new_buf = try allocator.alloc(T, new_capacity);

            if (self.count > 0) {
                if (self.head == 0) {
                    @memcpy(new_buf[0..self.count], self.buf[0..self.count]);
                } else {
                    const first_part = self.buf[self.head..];
                    const second_part = self.buf[0..self.head];
                    @memcpy(new_buf[0..first_part.len], first_part);
                    @memcpy(new_buf[first_part.len..self.count], second_part);
                }
            }

            allocator.free(self.buf);
            self.buf = new_buf;
            self.head = 0;
            self.tail = self.count;
        }

        /// Iterates over every active element in the FIFO out-of-order.
        /// Passes a pointer to each item to the provided callback function.
        pub inline fn forEach(self: *Self, context: anytype, comptime callback: fn (ctx: @TypeOf(context), item: *T) void) void {
            if (self.count == 0) return;

            if (self.head < self.tail) {
                // Data is linear
                for (self.buf[self.head..self.tail]) |*item| {
                    callback(context, item);
                }
            } else {
                // Data is wrapped around the ring
                for (self.buf[self.head..]) |*item| {
                    callback(context, item);
                }
                for (self.buf[0..self.tail]) |*item| {
                    callback(context, item);
                }
            }
        }

        /// Clears the FIFO, resetting it to an empty state.
        /// If `T` owns resources, pass a deinitialization callback function.
        /// Pass null for primitives or basic structs.
        pub fn clear(self: *Self, deinit_item: ?fn (item: T) void) void {
            if (deinit_item) |cb| {
                if (self.count > 0) {
                    if (self.head < self.tail) {
                        // Elements are contiguous
                        for (self.buf[self.head..self.tail]) |item| {
                            cb(item);
                        }
                    } else {
                        // Elements wrap around the boundary
                        for (self.buf[self.head..]) |item| {
                            cb(item);
                        }
                        for (self.buf[0..self.tail]) |item| {
                            cb(item);
                        }
                    }
                }
            }

            // O(1) reset for the tracking state
            self.head = 0;
            self.tail = 0;
            self.count = 0;
        }
    };
}
