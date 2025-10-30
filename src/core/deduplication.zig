//! content-addressable storage for dedup basically git for files - same content = same hash = stored once
//! Hoping it saves a lot of space for multi backups.

const std = @import("std");
const types = @import("../utils/types.zig");
const String = types.String;
const FileSize = types.FileSize;
const fs = std.fs;
const Allocator = std.mem.Allocator;

pub const DeduplicationDatabase = struct {
    allocator: Allocator,
    content_map: std.StringHashMap(ContentEntry),
    storage_path: String,

    const Self = @This();

    pub const ContentEntry = struct {
        hash: [32]u8,
        size: FileSize,
        ref_count: u32,
        storage_path: String,

        pub fn deinit(self: *ContentEntry, allocator: Allocator) void {
            allocator.free(self.storage_path);
        }
    };

    pub fn init(allocator: Allocator, storage_path: String) !Self {
        fs.cwd().makePath(storage_path) catch {};

        return Self{
            .allocator = allocator,
            .content_map = std.StringHashMap(ContentEntry).init(allocator),
            .storage_path = try allocator.dupe(u8, storage_path),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.content_map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.content_map.deinit();
        self.allocator.free(self.storage_path);
    }

    fn hashFile(file_path: String) ![32]u8 {
        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();

        // sha256 for content hashing - good balance of speed and collision resistance
        var hasher = std.crypto.hash.sha2.Sha256.init(.{}); // and i am kinda surprised zig has this. Was using libsodium but basically defenestrated it.
        var buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = try file.read(&buffer);
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }

        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        return hash;
    }

    fn hashToHex(allocator: Allocator, hash: [32]u8) ![]u8 {
        // wish zig had std.fmt.hex built-in but whatever
        const hex_chars = "0123456789abcdef";
        var hex = try allocator.alloc(u8, 64);

        for (hash, 0..) |byte, i| {
            hex[i * 2] = hex_chars[byte >> 4];
            hex[i * 2 + 1] = hex_chars[byte & 0x0F];
        }

        return hex;
    }

    pub fn addFile(self: *Self, file_path: String) !bool {
        const hash = try hashFile(file_path);
        const hash_hex = try hashToHex(self.allocator, hash);
        defer self.allocator.free(hash_hex);

        // already have this content - just bump refcount
        if (self.content_map.getPtr(hash_hex)) |entry| {
            entry.ref_count += 1;
            return false;
        }

        const file_stat = try fs.cwd().statFile(file_path);

        // use first 2 chars of hash as subdir to avoid giant directories
        const subdir = hash_hex[0..2];
        const subdir_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}",
            .{ self.storage_path, subdir },
        );
        defer self.allocator.free(subdir_path);

        fs.cwd().makePath(subdir_path) catch {};

        const dest_path = try std.fmt.allocPrint(
            self.allocator,
            "{s}/{s}/{s}",
            .{ self.storage_path, subdir, hash_hex },
        );

        try fs.cwd().copyFile(file_path, fs.cwd(), dest_path, .{});

        const entry = ContentEntry{
            .hash = hash,
            .size = file_stat.size,
            .ref_count = 1,
            .storage_path = dest_path,
        };

        try self.content_map.put(
            try self.allocator.dupe(u8, hash_hex),
            entry,
        );

        return true;
    }

    pub fn getContentPath(self: *Self, file_path: String) !?String {
        const hash = try hashFile(file_path);
        const hash_hex = try hashToHex(self.allocator, hash);
        defer self.allocator.free(hash_hex);

        if (self.content_map.get(hash_hex)) |entry| {
            return entry.storage_path; // Find where we stored this file's content (if we have it)
        }

        return null;
    }

    pub fn getStats(self: *Self) DeduplicationStats {
        var stats = DeduplicationStats{
            .unique_files = 0,
            .total_references = 0,
            .total_size = 0,
            .dedup_size = 0,
        };

        var it = self.content_map.iterator();
        while (it.next()) |entry| {
            stats.unique_files += 1;
            stats.total_references += entry.value_ptr.ref_count;
            stats.total_size += entry.value_ptr.size * entry.value_ptr.ref_count;
            stats.dedup_size += entry.value_ptr.size;
        } // Calculate how much space were actually saving

        return stats;
    }

    pub const DeduplicationStats = struct {
        unique_files: u64,
        total_references: u64,
        total_size: FileSize,
        dedup_size: FileSize,

        pub fn savingsPercent(self: DeduplicationStats) f64 {
            if (self.total_size == 0) return 0.0;
            const saved = @as(f64, @floatFromInt(self.total_size - self.dedup_size));
            const total = @as(f64, @floatFromInt(self.total_size));
            return (saved / total) * 100.0;
        }
    };
};
