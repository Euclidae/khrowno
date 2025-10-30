// thread pool for parallel tasks
//! zig's threading is decent but mutex/condition patterns feel verbose

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const Condition = std.Thread.Condition;
const String = @import("../utils/types.zig").String;
const ansi = @import("../utils/ansi.zig");

pub const WorkItem = struct {
    id: u64,
    data: String,
    callback: *const fn (data: String) anyerror!void,

    allocator: Allocator,

    pub fn init(allocator: Allocator, id: u64, data: String, callback: *const fn (data: String) anyerror!void) !WorkItem {
        return WorkItem{
            .id = id,
            .data = try allocator.dupe(u8, data),
            .callback = callback,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *WorkItem) void {
        self.allocator.free(self.data);
    }

    pub fn execute(self: *const WorkItem) !void {
        try self.callback(self.data);
    }
};

// WorkQueue manages worker threads that pull from a shared queue

pub const WorkQueue = struct {
    allocator: Allocator,
    queue: ArrayList(WorkItem),
    workers: ArrayList(Thread),
    mutex: Mutex,
    condition: Condition,
    running: bool,
    worker_count: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, worker_count: usize) Self {
        return Self{
            .allocator = allocator,
            .queue = ArrayList(WorkItem).init(allocator),
            .workers = ArrayList(Thread).init(allocator),
            .mutex = .{},
            .condition = .{},
            .running = false,
            .worker_count = worker_count,
        };
    }

    pub fn deinit(self: *Self) void {
        self.stop();

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.queue.items) |*item| {
            item.deinit();
        }
        self.queue.deinit();
        self.workers.deinit();
    }

    pub fn start(self: *Self) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.running = true;

        var i: usize = 0;
        while (i < self.worker_count) : (i += 1) {
            const thread = try Thread.spawn(.{}, workerThread, .{self});
            try self.workers.append(thread);
        }
    }

    pub fn stop(self: *Self) void {
        self.mutex.lock();
        self.running = false;
        self.condition.broadcast();
        self.mutex.unlock();

        for (self.workers.items) |thread| {
            thread.join();
        }

        self.workers.clearRetainingCapacity();
    }

    pub fn enqueue(self: *Self, item: WorkItem) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.queue.append(item);
        self.condition.signal();
    }

    fn workerThread(self: *Self) void {
        while (true) {
            self.mutex.lock();

            while (self.running and self.queue.items.len == 0) {
                self.condition.wait(&self.mutex); // sleep until work arrives or shutdown
            }

            if (!self.running and self.queue.items.len == 0) {
                self.mutex.unlock();
                break; // shutdown signal + empty queue = exit thread
            }

            const item = self.queue.orderedRemove(0); // FIFO order
            self.mutex.unlock();

            item.execute() catch |err| {
                std.debug.print("{s}Error: Work item {d} failed: {any}{s}\n", .{ ansi.Color.BOLD_RED, item.id, err, ansi.Color.RESET });
            };

            var mutable_item = item;
            mutable_item.deinit();
        }
    }

    pub fn waitForCompletion(self: *Self) void {
        while (true) {
            self.mutex.lock();
            const queue_empty = self.queue.items.len == 0;
            self.mutex.unlock();

            if (queue_empty) {
                break;
            }

            std.time.sleep(10 * std.time.ns_per_ms);
        }
    }

    pub fn getQueueSize(self: *Self) usize {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.queue.items.len;
    }
};
