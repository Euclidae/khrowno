//! parallel backup using thread pool
//! makes backups faster on multi-core systems but can be unstable

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const Thread = std.Thread;
const Mutex = std.Thread.Mutex;
const types = @import("../utils/types.zig");
const String = types.String;
const FileSize = types.FileSize;
const work_queue = @import("work_queue.zig");

pub const BackupTask = struct {
    source_path: String,
    dest_path: String,
    size: FileSize,

    allocator: Allocator,

    pub fn init(allocator: Allocator, source: String, dest: String, size: FileSize) !BackupTask {
        return BackupTask{
            .source_path = try allocator.dupe(u8, source),
            .dest_path = try allocator.dupe(u8, dest),
            .size = size,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BackupTask) void {
        self.allocator.free(self.source_path);
        self.allocator.free(self.dest_path);
    }
};

pub const ParallelBackupEngine = struct {
    allocator: Allocator,
    work_queue: work_queue.WorkQueue,
    total_bytes: FileSize,
    processed_bytes: FileSize,
    mutex: Mutex,

    const Self = @This();

    pub fn init(allocator: Allocator, thread_count: usize) Self {
        return Self{
            .allocator = allocator,
            .work_queue = work_queue.WorkQueue.init(allocator, thread_count),
            .total_bytes = 0,
            .processed_bytes = 0,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *Self) void {
        self.work_queue.deinit();
    }

    pub fn start(self: *Self) !void {
        try self.work_queue.start();
    }

    pub fn stop(self: *Self) void {
        self.work_queue.stop();
    }

    pub fn addTask(self: *Self, task: BackupTask) !void {
        self.mutex.lock();
        self.total_bytes += task.size; // track progress
        self.mutex.unlock();

        const task_data = try std.fmt.allocPrint(
            self.allocator,
            "{s}|{s}|{d}",
            .{ task.source_path, task.dest_path, task.size },
        );
        defer self.allocator.free(task_data);

        const work_item = try work_queue.WorkItem.init(
            self.allocator,
            @intCast(std.time.timestamp()),
            task_data,
            &processBackupTask,
        );

        try self.work_queue.enqueue(work_item);
    }

    fn processBackupTask(data: String) !void {
        var parts = std.mem.splitScalar(u8, data, '|');
        const source = parts.next() orelse return error.InvalidTaskData;
        const dest = parts.next() orelse return error.InvalidTaskData;
        const size_str = parts.next() orelse return error.InvalidTaskData;

        const size = try std.fmt.parseInt(u64, size_str, 10);

        const source_file = try std.fs.cwd().openFile(source, .{});
        defer source_file.close();

        const dest_dir = std.fs.path.dirname(dest);
        if (dest_dir) |dir| {
            try std.fs.cwd().makePath(dir);
        }

        const dest_file = try std.fs.cwd().createFile(dest, .{});
        defer dest_file.close();

        var buffer: [8192]u8 = undefined;
        var total_read: u64 = 0;

        while (total_read < size) {
            const bytes_read = try source_file.read(&buffer);
            if (bytes_read == 0) break;

            try dest_file.writeAll(buffer[0..bytes_read]);
            total_read += bytes_read;
        }
    }

    pub fn waitForCompletion(self: *Self) void {
        self.work_queue.waitForCompletion();
    }

    pub fn getProgress(self: *Self) f64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.total_bytes == 0) return 0.0;
        return @as(f64, @floatFromInt(self.processed_bytes)) / @as(f64, @floatFromInt(self.total_bytes));
    }

    pub fn updateProgress(self: *Self, bytes: FileSize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.processed_bytes += bytes;
    }
};

pub const ChunkProcessor = struct {
    allocator: Allocator,
    chunk_size: usize,

    const Self = @This();

    pub fn init(allocator: Allocator, chunk_size: usize) Self {
        return Self{
            .allocator = allocator,
            .chunk_size = chunk_size,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn processFileInChunks(self: *Self, file_path: String, processor: *const fn (chunk: String) anyerror!void) !void {
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        var buffer = try self.allocator.alloc(u8, self.chunk_size);
        defer self.allocator.free(buffer);

        while (true) {
            const bytes_read = try file.read(buffer);
            if (bytes_read == 0) break;

            try processor(buffer[0..bytes_read]);
        }
    }
};
