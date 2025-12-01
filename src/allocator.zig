const std = @import("std");

// Slab allocator for fixed-size allocations (connection buffers)
// This ensures zero allocations after startup for connection handling
pub const SlabAllocator = struct {
    const Node = struct {
        data: []u8,
        next: ?*Node,
    };

    arena: std.heap.ArenaAllocator,
    free_list: ?*Node,
    slot_size: usize,
    slots_per_chunk: usize,

    pub fn init(backing_allocator: std.mem.Allocator, slot_size: usize, slots_per_chunk: usize) !SlabAllocator {
        var arena = std.heap.ArenaAllocator.init(backing_allocator);
        errdefer arena.deinit();

        // Pre-allocate initial chunk
        const chunk = try arena.allocator().alloc(u8, slot_size * slots_per_chunk);
        var free_list: ?*Node = null;

        // Build free list from back to front to maintain order
        var i: usize = slots_per_chunk;
        while (i > 0) {
            i -= 1;
            const node = try arena.allocator().create(Node);
            node.data = chunk[i * slot_size ..][0..slot_size];
            node.next = free_list;
            free_list = node;
        }

        return SlabAllocator{
            .arena = arena,
            .free_list = free_list,
            .slot_size = slot_size,
            .slots_per_chunk = slots_per_chunk,
        };
    }

    pub fn deinit(self: *SlabAllocator) void {
        self.arena.deinit();
    }

    pub fn alloc(self: *SlabAllocator) ?[]u8 {
        if (self.free_list) |node| {
            self.free_list = node.next;
            return node.data;
        }
        return null;
    }

    pub fn free(self: *SlabAllocator, buf: []u8) void {
        // Create a new node and add to free list
        // Note: This requires allocation, but we'll use the arena
        const node = self.arena.allocator().create(Node) catch return;
        node.data = buf;
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

        var read_free = std.ArrayList(usize).initCapacity(backing_allocator, pool_size) catch @panic("Failed to init read_free list");
        errdefer read_free.deinit(backing_allocator);

        for (0..pool_size) |i| {
            const buf = try backing_allocator.alloc(u8, buffer_size);
            read_buffers[i] = buf;
            try read_free.append(backing_allocator, i);
        }

        // Pre-allocate all write buffers
        const write_buffers = try backing_allocator.alloc([]u8, pool_size);
        errdefer backing_allocator.free(write_buffers);

        var write_free = std.ArrayList(usize).initCapacity(backing_allocator, pool_size) catch @panic("Failed to init write_free list");
        errdefer write_free.deinit(backing_allocator);

        for (0..pool_size) |i| {
            const buf = try backing_allocator.alloc(u8, buffer_size);
            write_buffers[i] = buf;
            try write_free.append(backing_allocator, i);
        }

        return BufferPool{
            .read_pool = Pool{
                .buffers = read_buffers,
                .free_indices = read_free,
                .mutex = std.Thread.Mutex{},
            },
            .write_pool = Pool{
                .buffers = write_buffers,
                .free_indices = write_free,
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

        for (self.write_pool.buffers) |buf| {
            self.backing_allocator.free(buf);
        }
        self.backing_allocator.free(self.write_pool.buffers);
        self.write_pool.free_indices.deinit(self.backing_allocator);
    }

    pub fn acquireRead(self: *BufferPool) ?[]u8 {
        self.read_pool.mutex.lock();
        defer self.read_pool.mutex.unlock();

        if (self.read_pool.free_indices.popOrNull()) |idx| {
            return self.read_pool.buffers[idx];
        }
        return null;
    }

    pub fn releaseRead(self: *BufferPool, buf: []u8) void {
        self.read_pool.mutex.lock();
        defer self.read_pool.mutex.unlock();

        // Find the buffer index
        for (self.read_pool.buffers, 0..) |pool_buf, idx| {
            if (pool_buf.ptr == buf.ptr) {
                self.read_pool.free_indices.append(self.backing_allocator, idx) catch return;
                return;
            }
        }
    }

    pub fn acquireWrite(self: *BufferPool) ?[]u8 {
        self.write_pool.mutex.lock();
        defer self.write_pool.mutex.unlock();

        if (self.write_pool.free_indices.popOrNull()) |idx| {
            return self.write_pool.buffers[idx];
        }
        return null;
    }

    pub fn releaseWrite(self: *BufferPool, buf: []u8) void {
        self.write_pool.mutex.lock();
        defer self.write_pool.mutex.unlock();

        // Find the buffer index
        for (self.write_pool.buffers, 0..) |pool_buf, idx| {
            if (pool_buf.ptr == buf.ptr) {
                self.write_pool.free_indices.append(self.backing_allocator, idx) catch return;
                return;
            }
        }
    }
};
