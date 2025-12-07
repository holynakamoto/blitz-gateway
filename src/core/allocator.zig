const std = @import("std");

// Slab allocator for fixed-size allocations (connection buffers)
// This ensures zero allocations after startup for connection handling
pub const SlabAllocator = struct {
    const Node = struct {
        next: ?*Node,
    };

    arena: std.heap.ArenaAllocator,
    free_list: ?*Node,
    slot_size: usize,
    slots_per_chunk: usize,
    node_size: usize,

    pub fn init(backing_allocator: std.mem.Allocator, slot_size: usize, slots_per_chunk: usize) !SlabAllocator {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();

        const node_size = @sizeOf(Node);
        const node_align = @alignOf(Node);
        // Round up node_size to ensure proper alignment
        const aligned_node_size = std.mem.alignForward(usize, node_size, node_align);
        const total_slot_size = aligned_node_size + slot_size;

        // Pre-allocate initial chunk with embedded Node headers
        // Use aligned allocation to ensure first slot is properly aligned
        const chunk = try arena.allocator().allocAdvanced(u8, node_align, total_slot_size * slots_per_chunk, .exact);
        var free_list: ?*Node = null;

        // Build free list from back to front to maintain order
        var i: usize = slots_per_chunk;
        while (i > 0) {
            i -= 1;
            // Node is embedded at the start of each slot
            const slot_ptr = chunk.ptr + (i * total_slot_size);
            const node: *Node = @ptrCast(@alignCast(slot_ptr));
            node.next = free_list;
            free_list = node;
        }

        return SlabAllocator{
            .arena = arena,
            .free_list = free_list,
            .slot_size = slot_size,
            .slots_per_chunk = slots_per_chunk,
            .node_size = aligned_node_size,
        };
    }

    pub fn deinit(self: *SlabAllocator) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *SlabAllocator) ?[]u8 {
        if (self.free_list) |node| {
            self.free_list = node.next;
            // Return data portion (after Node header)
            const data_ptr = @as([*]u8, @ptrCast(node)) + self.node_size;
            return data_ptr[0..self.slot_size];
        }
        return null;
    }

    pub fn free(self: *SlabAllocator, buf: []u8) !void {
        // Recover Node by subtracting aligned Node size from data pointer
        const data_ptr = @intFromPtr(buf.ptr);
        const node_ptr = data_ptr - self.node_size;

        // Verify the pointer is properly aligned
        const node_align = @alignOf(Node);
        if (node_ptr % node_align != 0) {
            return error.InvalidPointer;
        }

        const node: *Node = @ptrFromInt(node_ptr);

        // Push node back onto free list
        node.next = self.free_list;
        self.free_list = node;
    }

    pub fn allocator(self: *SlabAllocator) std.mem.Allocator {
        return self.arena.allocator();
    }
};

// Fixed buffer pool for read/write operations
// Pre-allocates all buffers at startup, zero allocations during runtime
// Note: Single-threaded for now (io_uring event loop), mutex can be removed later
pub const BufferPool = struct {
    const Pool = struct {
        buffers: [][]u8,
        free_indices: std.ArrayList(usize),
        buffer_to_index: std.AutoHashMap(usize, usize), // ptr -> index mapping
        mutex: std.Thread.Mutex,
    };

    read_pool: Pool,
    write_pool: Pool,
    buffer_size: usize,
    pool_size: usize,
    backing_allocator: std.mem.Allocator,

    pub fn init(backing_allocator: std.mem.Allocator, buffer_size: usize, pool_size: usize) !BufferPool {
        // Pre-allocate all read buffers
        const read_buffers = try backing_allocator.alloc([]u8, pool_size);
        errdefer backing_allocator.free(read_buffers);

        var read_free = try std.ArrayList(usize).initCapacity(backing_allocator, pool_size);
        errdefer read_free.deinit(backing_allocator);

        var read_buffer_to_index = std.AutoHashMap(usize, usize).init(backing_allocator);
        errdefer read_buffer_to_index.deinit();

        var read_allocated: usize = 0;
        errdefer for (read_buffers[0..read_allocated]) |buf| {
            backing_allocator.free(buf);
        };

        for (0..pool_size) |i| {
            const buf = try backing_allocator.alloc(u8, buffer_size);
            read_buffers[i] = buf;
            read_allocated += 1;
            try read_free.append(backing_allocator, i);
            try read_buffer_to_index.put(@intFromPtr(buf.ptr), i);
        }

        // Pre-allocate all write buffers
        const write_buffers = try backing_allocator.alloc([]u8, pool_size);

        var write_free = try std.ArrayList(usize).initCapacity(backing_allocator, pool_size);

        var write_buffer_to_index = std.AutoHashMap(usize, usize).init(backing_allocator);
        errdefer write_buffer_to_index.deinit();

        var write_buffers_allocated: usize = 0;
        errdefer write_free.deinit(backing_allocator);
        errdefer backing_allocator.free(write_buffers);
        errdefer {
            // Free any partially-allocated buffers
            for (write_buffers[0..write_buffers_allocated]) |buf| {
                backing_allocator.free(buf);
            }
        }

        for (0..pool_size) |i| {
            const buf = try backing_allocator.alloc(u8, buffer_size);
            write_buffers[i] = buf;
            write_buffers_allocated += 1;
            try write_free.append(backing_allocator, i);
            try write_buffer_to_index.put(@intFromPtr(buf.ptr), i);
        }

        return BufferPool{
            .read_pool = Pool{
                .buffers = read_buffers,
                .free_indices = read_free,
                .buffer_to_index = read_buffer_to_index,
                .mutex = std.Thread.Mutex{},
            },
            .write_pool = Pool{
                .buffers = write_buffers,
                .free_indices = write_free,
                .buffer_to_index = write_buffer_to_index,
                .mutex = std.Thread.Mutex{},
            },
            .buffer_size = buffer_size,
            .pool_size = pool_size,
            .backing_allocator = backing_allocator,
        };
    }

    pub fn deinit(self: *BufferPool) void {
        // Free all buffers
        for (self.read_pool.buffers) |buf| {
            self.backing_allocator.free(buf);
        }
        self.backing_allocator.free(self.read_pool.buffers);
        self.read_pool.free_indices.deinit(self.backing_allocator);
        self.read_pool.buffer_to_index.deinit();

        for (self.write_pool.buffers) |buf| {
            self.backing_allocator.free(buf);
        }
        self.backing_allocator.free(self.write_pool.buffers);
        self.write_pool.free_indices.deinit(self.backing_allocator);
        self.write_pool.buffer_to_index.deinit();
    }

    pub fn acquireRead(self: *BufferPool) ?[]u8 {
        self.read_pool.mutex.lock();
        defer self.read_pool.mutex.unlock();

        // Check if list is empty before popping to avoid panic
        if (self.read_pool.free_indices.items.len == 0) {
            return null;
        }
        const idx = self.read_pool.free_indices.pop();
        return self.read_pool.buffers[idx.?];
    }

    pub fn releaseRead(self: *BufferPool, buf: []u8) void {
        self.read_pool.mutex.lock();
        defer self.read_pool.mutex.unlock();

        // Get buffer index directly from HashMap
        const buf_ptr = @intFromPtr(buf.ptr);
        const idx = self.read_pool.buffer_to_index.get(buf_ptr) orelse {
            // Invalid buffer pointer - this shouldn't happen in normal operation
            @panic("releaseRead: invalid buffer pointer");
        };

        // Ensure capacity is sufficient (pool_size is maximum possible)
        if (self.read_pool.free_indices.capacity < self.read_pool.free_indices.items.len + 1) {
            self.read_pool.free_indices.ensureTotalCapacity(self.backing_allocator, self.pool_size) catch |err| {
                // This should never fail since we're pre-allocating, but if it does, panic to prevent silent leak
                std.debug.panic("Failed to ensure capacity for free_indices: {}", .{err});
            };
        }

        // Use appendAssumeCapacity since we've ensured sufficient capacity
        self.read_pool.free_indices.appendAssumeCapacity(idx);
    }

    pub fn acquireWrite(self: *BufferPool) ?[]u8 {
        self.write_pool.mutex.lock();
        defer self.write_pool.mutex.unlock();

        // Check if list is empty before popping to avoid panic
        if (self.write_pool.free_indices.items.len == 0) {
            return null;
        }
        const idx = self.write_pool.free_indices.pop();
        return self.write_pool.buffers[idx.?];
    }

    pub fn releaseWrite(self: *BufferPool, buf: []u8) void {
        self.write_pool.mutex.lock();
        defer self.write_pool.mutex.unlock();

        // Get buffer index directly from HashMap
        const buf_ptr = @intFromPtr(buf.ptr);
        const idx = self.write_pool.buffer_to_index.get(buf_ptr) orelse {
            // Invalid buffer pointer - this shouldn't happen in normal operation
            @panic("releaseWrite: invalid buffer pointer");
        };

        // Ensure capacity is sufficient (pool_size is maximum possible)
        if (self.write_pool.free_indices.capacity < self.write_pool.free_indices.items.len + 1) {
            self.write_pool.free_indices.ensureTotalCapacity(self.backing_allocator, self.pool_size) catch |err| {
                // This should never fail since we're pre-allocating, but if it does, panic to prevent silent leak
                std.debug.panic("Failed to ensure capacity for free_indices: {}", .{err});
            };
        }

        // Use appendAssumeCapacity since we've ensured sufficient capacity
        self.write_pool.free_indices.appendAssumeCapacity(idx);
    }
};
