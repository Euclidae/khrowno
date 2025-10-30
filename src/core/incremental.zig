const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const types = @import("../utils/types.zig");
const String = types.String;
const FileSize = types.FileSize;
const Timestamp = types.Timestamp;
const backup_module = @import("backup.zig");

// incremental backups - only backup what changed
// works but not hooked up to CLI/GUI yet
pub const IncrementalStrategy = enum {
    timestamp,
    checksum,
    hybrid,
    rsync, // never actually tested rsync mode

    pub fn toString(self: IncrementalStrategy) String {
        return switch (self) {
            .timestamp => "timestamp",
            .checksum => "checksum",
            .hybrid => "hybrid",
            .rsync => "rsync",
        };
    }
};

pub const FileChangeType = enum {
    unchanged,
    modified,
    added,
    deleted,
    renamed,
    moved,

    pub fn toString(self: FileChangeType) String {
        return switch (self) {
            .unchanged => "unchanged",
            .modified => "modified",
            .added => "added",
            .deleted => "deleted",
            .renamed => "renamed",
            .moved => "moved",
        };
    }
};

pub const FileChange = struct {
    path: String,
    change_type: FileChangeType,
    old_path: ?String = null, // For renames/moves
    old_mtime: ?Timestamp = null,
    new_mtime: ?Timestamp = null,
    old_size: ?FileSize = null,
    new_size: ?FileSize = null,
    old_checksum: ?String = null,
    new_checksum: ?String = null,

    pub fn deinit(self: *FileChange, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.old_path) |path| allocator.free(path);
        if (self.old_checksum) |checksum| allocator.free(checksum);
        if (self.new_checksum) |checksum| allocator.free(checksum);
    }
};

pub const IncrementalManifest = struct {
    base_backup_id: String,
    incremental_id: String,
    created_at: Timestamp,
    strategy: IncrementalStrategy,
    changes: std.ArrayList(FileChange),
    total_files_scanned: u32,
    files_changed: u32,
    files_added: u32,
    files_deleted: u32,
    files_renamed: u32,

    pub fn init(allocator: std.mem.Allocator, base_backup_id: String, incremental_id: String, strategy: IncrementalStrategy) !IncrementalManifest {
        return IncrementalManifest{
            .base_backup_id = try allocator.dupe(u8, base_backup_id),
            .incremental_id = try allocator.dupe(u8, incremental_id),
            .created_at = std.time.timestamp(),
            .strategy = strategy,
            .changes = std.ArrayList(FileChange).init(allocator),
            .total_files_scanned = 0,
            .files_changed = 0,
            .files_added = 0,
            .files_deleted = 0,
            .files_renamed = 0,
        };
    }

    pub fn deinit(self: *IncrementalManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.base_backup_id);
        allocator.free(self.incremental_id);

        for (self.changes.items) |*change| {
            change.deinit(allocator);
        }
        self.changes.deinit();
    }

    pub fn addChange(self: *IncrementalManifest, change: FileChange) !void {
        try self.changes.append(change);

        switch (change.change_type) {
            .unchanged => {},
            .modified => self.files_changed += 1,
            .added => self.files_added += 1,
            .deleted => self.files_deleted += 1,
            .renamed, .moved => self.files_renamed += 1,
        }
    }

    pub fn getStatistics(self: *IncrementalManifest) void {
        print("Incremental Backup Statistics:\n", .{});
        print("=============================\n", .{});
        print("Base backup: {s}\n", .{self.base_backup_id});
        print("Incremental ID: {s}\n", .{self.incremental_id});
        print("Strategy: {s}\n", .{self.strategy.toString()});
        print("Created: {d}\n", .{self.created_at});
        print("Total files scanned: {d}\n", .{self.total_files_scanned});
        print("Files changed: {d}\n", .{self.files_changed});
        print("Files added: {d}\n", .{self.files_added});
        print("Files deleted: {d}\n", .{self.files_deleted});
        print("Files renamed/moved: {d}\n", .{self.files_renamed});
        print("Total changes: {d}\n", .{self.changes.items.len});
    }
};

pub const IncrementalBackupEngine = struct {
    allocator: std.mem.Allocator,
    strategy: IncrementalStrategy,
    base_manifest: ?IncrementalManifest = null,

    pub fn init(allocator: std.mem.Allocator, strategy: IncrementalStrategy) IncrementalBackupEngine {
        return IncrementalBackupEngine{
            .allocator = allocator,
            .strategy = strategy,
        };
    }

    pub fn deinit(self: *IncrementalBackupEngine) void {
        _ = self;
    }

    pub fn loadBaseManifest(self: *IncrementalBackupEngine, manifest_path: String) !void {
        print("Loading base manifest from: {s}\n", .{manifest_path});

        const file_data = fs.cwd().readFileAlloc(self.allocator, manifest_path, std.math.maxInt(usize)) catch |err| {
            print("Cannot read manifest file {s}: {any}\n", .{ manifest_path, err });
            const base_id = "base_backup_001";
            const incremental_id = "incremental_001";
            self.base_manifest = try IncrementalManifest.init(self.allocator, base_id, incremental_id, self.strategy);
            return;
        };
        defer self.allocator.free(file_data);

        var lines = std.mem.splitScalar(u8, file_data, '\n');
        var base_id: ?[]u8 = null;
        var incremental_id: ?[]u8 = null;
        var strategy: IncrementalStrategy = self.strategy;

        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "BASE_ID:")) {
                const id = std.mem.trim(u8, line[8..], " \t\r\n");
                base_id = try self.allocator.dupe(u8, id);
            } else if (std.mem.startsWith(u8, line, "INCREMENTAL_ID:")) {
                const id = std.mem.trim(u8, line[15..], " \t\r\n");
                incremental_id = try self.allocator.dupe(u8, id);
            } else if (std.mem.startsWith(u8, line, "STRATEGY:")) {
                const strategy_str = std.mem.trim(u8, line[9..], " \t\r\n");
                strategy = std.meta.stringToEnum(IncrementalStrategy, strategy_str) orelse self.strategy;
            }
        }

        const final_base_id = base_id orelse try self.allocator.dupe(u8, "base_backup_001");
        const final_incremental_id = incremental_id orelse try self.allocator.dupe(u8, "incremental_001");

        self.base_manifest = try IncrementalManifest.init(self.allocator, final_base_id, final_incremental_id, strategy);

        print("Base manifest loaded successfully\n", .{});
    }

    pub fn scanForChanges(self: *IncrementalBackupEngine, directory: String) !IncrementalManifest {
        print("Scanning directory for changes: {s}\n", .{directory});

        const incremental_id = try std.fmt.allocPrint(self.allocator, "incremental_{d}", .{std.time.timestamp()});
        defer self.allocator.free(incremental_id);

        const base_id = if (self.base_manifest) |manifest| try self.allocator.dupe(u8, manifest.base_backup_id) else try self.allocator.dupe(u8, "full_backup");
        defer self.allocator.free(base_id);

        var manifest = try IncrementalManifest.init(self.allocator, base_id, incremental_id, self.strategy);
        try self.scanDirectoryRecursive(directory, &manifest);

        manifest.getStatistics();
        return manifest;
    }

    fn scanDirectoryRecursive(self: *IncrementalBackupEngine, directory: String, manifest: *IncrementalManifest) !void {
        var dir = fs.cwd().openDir(directory, .{ .iterate = true }) catch |err| {
            print("Cannot open directory {s}: {any}\n", .{ directory, err });
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory, entry.name });
            defer self.allocator.free(full_path);

            manifest.total_files_scanned += 1;

            switch (entry.kind) {
                .file => {
                    const change = try self.analyzeFile(full_path, entry.name);
                    try manifest.addChange(change);
                },
                .directory => {
                    // Scan the directory in question recursively.
                    try self.scanDirectoryRecursive(full_path, manifest);
                },
                else => {
                    // Skip symlinks, devices, etc.
                    print("Skipping {s} (not a regular file or directory)\n", .{entry.name});
                },
            }
        }
    }

    fn analyzeFile(self: *IncrementalBackupEngine, file_path: String, filename: String) !FileChange {
        _ = filename;
        const file = fs.cwd().openFile(file_path, .{}) catch |err| {
            print("Cannot open file {s}: {any}\n", .{ file_path, err });
            return FileChange{
                .path = try self.allocator.dupe(u8, file_path),
                .change_type = .added, // Assume its new if we can't read it
            };
        };
        defer file.close();

        const stat = try file.stat();

        if (self.base_manifest) |base_manifest| {
            // Look for this file in the base manifest
            for (base_manifest.changes.items) |base_change| {
                if (std.mem.eql(u8, base_change.path, file_path)) {
                    // Here, the file exists in base, so we check it if changed
                    const changed = switch (self.strategy) {
                        .timestamp => stat.mtime != @as(i128, base_change.new_mtime orelse 0),
                        .checksum => try self.fileChecksumChanged(file_path, base_change.new_checksum),
                        .hybrid => stat.mtime != @as(i128, base_change.new_mtime orelse 0) or try self.fileChecksumChanged(file_path, base_change.new_checksum),
                        .rsync => stat.mtime != @as(i128, base_change.new_mtime orelse 0) or stat.size != base_change.new_size,
                    };

                    if (changed) {
                        return FileChange{
                            .path = try self.allocator.dupe(u8, file_path),
                            .change_type = .modified,
                            .old_mtime = base_change.new_mtime,
                            .new_mtime = @as(i64, @intCast(stat.mtime)),
                            .old_size = base_change.new_size,
                            .new_size = stat.size,
                        };
                    } else {
                        return FileChange{
                            .path = try self.allocator.dupe(u8, file_path),
                            .change_type = .unchanged,
                            .new_mtime = @as(i64, @intCast(stat.mtime)),
                            .new_size = stat.size,
                        };
                    }
                }
            }
        }

        // File not found in base manifest, its new
        return FileChange{
            .path = try self.allocator.dupe(u8, file_path),
            .change_type = .added,
            .new_mtime = @as(i64, @intCast(stat.mtime)),
            .new_size = stat.size,
        };
    }

    fn fileChecksumChanged(self: *IncrementalBackupEngine, file_path: String, old_checksum: ?String) !bool {
        if (old_checksum == null) return true;

        // Calculate current file checksum (remember a checksum is basically data for ensuring validity. check... sum. check sumthin.)
        const file = std.fs.cwd().openFile(file_path, .{}) catch return true;
        defer file.close();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [4096]u8 = undefined;

        while (true) {
            const bytes_read = file.read(&buffer) catch return true;
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }

        var current_hash: [32]u8 = undefined;
        hasher.final(&current_hash);

        // Compare with old checksum
        const current_hex = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&current_hash)});
        defer self.allocator.free(current_hex);

        return !std.mem.eql(u8, current_hex, old_checksum.?);
    }

    pub fn createIncrementalBackup(self: *IncrementalBackupEngine, manifest: *IncrementalManifest, output_path: String) !void {
        print("Creating incremental backup: {s}\n", .{output_path});

        // Only backup changed files
        var files_to_backup: u32 = 0;
        var total_size: types.FileSize = 0;

        for (manifest.changes.items) |change| {
            if (change.change_type != .unchanged) {
                files_to_backup += 1;
                total_size += change.new_size orelse 0;
                print("  {s}: {s}\n", .{ change.path, change.change_type.toString() });
            }
        }

        print("Files to backup: {d} ({d} bytes)\n", .{ files_to_backup, total_size });

        const backup_file = try std.fs.cwd().createFile(output_path, .{});
        defer backup_file.close();

        // Write incremental backup header
        const header = "KROWNO-INCREMENTAL-V1\n";
        try backup_file.writeAll(header);

        // Write manifest data
        try backup_file.writeAll("MANIFEST_START\n");
        for (manifest.changes.items) |change| {
            const line = try std.fmt.allocPrint(self.allocator, "{s}|{s}|{d}|{d}\n", .{ change.path, change.change_type.toString(), change.new_mtime orelse 0, change.new_size orelse 0 });
            defer self.allocator.free(line);
            try backup_file.writeAll(line);
        }
        try backup_file.writeAll("MANIFEST_END\n");

        // Actually backup the changed files
        try backup_file.writeAll("FILES_START\n");
        for (manifest.changes.items) |change| {
            if (change.change_type != .unchanged and change.change_type != .deleted) {
                // Read the file content
                const file_content = fs.cwd().readFileAlloc(self.allocator, change.path, std.math.maxInt(usize)) catch |err| {
                    print("Warning: Cannot read file {s}: {any}\n", .{ change.path, err });
                    continue;
                };
                defer self.allocator.free(file_content);

                // Write file header
                const file_header = try std.fmt.allocPrint(self.allocator, "FILE:{s}:{d}\n", .{ change.path, file_content.len });
                defer self.allocator.free(file_header);
                try backup_file.writeAll(file_header);

                // Write file content
                try backup_file.writeAll(file_content);
            }
        }
        try backup_file.writeAll("FILES_END\n");

        print("Incremental backup created successfully\n", .{});
    }


    pub fn restoreFromIncremental(self: *IncrementalBackupEngine, base_backup_path: String, incremental_backup_path: String, restore_path: String) !void {
        print("Restoring from incremental backup...\n", .{});
        print("Base backup: {s}\n", .{base_backup_path});
        print("Incremental backup: {s}\n", .{incremental_backup_path});
        print("Restore path: {s}\n", .{restore_path});

        print("Restoring base backup...\n", .{});

        fs.cwd().makePath(restore_path) catch |err| {
            print("Cannot create restore directory {s}: {any}\n", .{ restore_path, err });
            return;
        };

        var backup_engine = try backup_module.BackupEngine.init(self.allocator);
        defer backup_engine.deinit();

        backup_engine.restoreBackup(base_backup_path, null, null, null) catch |err| {
            print("Failed to restore base backup: {any}\n", .{err});
            print("Continuing with incremental restore...\n", .{});
        };

        const incremental_data = fs.cwd().readFileAlloc(self.allocator, incremental_backup_path, std.math.maxInt(usize)) catch |err| {
            print("Cannot read incremental backup {s}: {any}\n", .{ incremental_backup_path, err });
            return;
        };
        defer self.allocator.free(incremental_data);

        var lines = std.mem.splitScalar(u8, incremental_data, '\n');
        var in_files_section = false;
        var current_file_path: ?[]u8 = null;
        var current_file_size: ?usize = null;
        var current_file_content = std.ArrayList(u8).init(self.allocator);
        defer current_file_content.deinit();

        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "FILES_START")) {
                in_files_section = true;
                continue;
            } else if (std.mem.eql(u8, line, "FILES_END")) {
                in_files_section = false;
                continue;
            }

            if (in_files_section) {
                if (std.mem.startsWith(u8, line, "FILE:")) {
                    if (current_file_path) |path| {
                        self.allocator.free(path);
                    }
                    if (current_file_content.items.len > 0) {
                        current_file_content.clearRetainingCapacity();
                    }

                    const colon_pos = std.mem.indexOf(u8, line, ":") orelse continue;
                    const size_pos = std.mem.indexOf(u8, line[colon_pos + 1 ..], ":") orelse continue;
                    const file_path = line[5..colon_pos];
                    const file_size_str = line[colon_pos + 1 + size_pos + 1 ..];

                    current_file_path = try self.allocator.dupe(u8, file_path);
                    current_file_size = std.fmt.parseInt(usize, file_size_str, 10) catch continue;
                } else if (current_file_path) |path| {
                    try current_file_content.appendSlice(line);
                    try current_file_content.append('\n');

                    if (current_file_content.items.len >= (current_file_size orelse 0)) {
                        const full_restore_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ restore_path, path });
                        defer self.allocator.free(full_restore_path);

                        const dir_path = std.fs.path.dirname(full_restore_path) orelse continue;
                        fs.cwd().makePath(dir_path) catch {};

                        const file = fs.cwd().createFile(full_restore_path, .{}) catch |err| {
                            print("Cannot create file {s}: {any}\n", .{ full_restore_path, err });
                            continue;
                        };
                        defer file.close();

                        try file.writeAll(current_file_content.items);
                        print("Restored file: {s}\n", .{path});

                        self.allocator.free(path);
                        current_file_path = null;
                        current_file_size = null;
                        current_file_content.clearRetainingCapacity();
                    }
                }
            }
        }

        print("Incremental restore completed\n", .{});
    }

    pub fn mergeIncrementalBackups(self: *IncrementalBackupEngine, base_backup_path: String, incremental_paths: []const String, output_path: String) !void {
        print("Merging incremental backups into full backup...\n", .{});
        print("Base backup: {s}\n", .{base_backup_path});
        print("Incremental backups: {d}\n", .{incremental_paths.len});
        print("Output: {s}\n", .{output_path});

        const output_file = try fs.cwd().createFile(output_path, .{});
        defer output_file.close();

        const header = "KROWNO-MERGED-V1\n";
        try output_file.writeAll(header);

        const base_data = fs.cwd().readFileAlloc(self.allocator, base_backup_path, std.math.maxInt(usize)) catch |err| {
            print("Cannot read base backup {s}: {any}\n", .{ base_backup_path, err });
            return;
        };
        defer self.allocator.free(base_data);

        try output_file.writeAll("BASE_BACKUP_START\n");
        try output_file.writeAll(base_data);
        try output_file.writeAll("BASE_BACKUP_END\n");

        for (incremental_paths, 0..) |inc_path, i| {
            print("Processing incremental backup {d}: {s}\n", .{ i + 1, inc_path });

            const inc_data = fs.cwd().readFileAlloc(self.allocator, inc_path, std.math.maxInt(usize)) catch |err| {
                print("Cannot read incremental backup {s}: {any}\n", .{ inc_path, err });
                continue;
            };
            defer self.allocator.free(inc_data);

            try output_file.writeAll("INCREMENTAL_START\n");
            try output_file.writeAll(inc_data);
            try output_file.writeAll("INCREMENTAL_END\n");
        }

        print("Merge completed successfully\n", .{});
    }

    pub fn cleanupOldIncrementalBackups(self: *IncrementalBackupEngine, backup_directory: String, keep_count: u32) !void {
        print("Cleaning up old incremental backups...\n", .{});
        print("Backup directory: {s}\n", .{backup_directory});
        print("Keep count: {d}\n", .{keep_count});

        var dir = fs.cwd().openDir(backup_directory, .{ .iterate = true }) catch |err| {
            print("Cannot open backup directory {s}: {any}\n", .{ backup_directory, err });
            return;
        };
        defer dir.close();

        var incremental_files = std.ArrayList(struct { path: []u8, mtime: i128 }).init(self.allocator);
        defer {
            for (incremental_files.items) |item| {
                self.allocator.free(item.path);
            }
            incremental_files.deinit();
        }

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (std.mem.startsWith(u8, entry.name, "incremental_") and std.mem.endsWith(u8, entry.name, ".khr")) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ backup_directory, entry.name });
                const stat = fs.cwd().statFile(full_path) catch continue;

                try incremental_files.append(.{
                    .path = full_path,
                    .mtime = stat.mtime,
                });
            }
        }

        std.sort.sort(struct { path: []u8, mtime: i128 }, incremental_files.items, {}, struct {
            pub fn lessThan(context: void, a: struct { path: []u8, mtime: i128 }, b: struct { path: []u8, mtime: i128 }) bool {
                _ = context;
                return a.mtime < b.mtime;
            }
        }.lessThan);

        if (incremental_files.items.len > keep_count) {
            const files_to_delete = incremental_files.items.len - keep_count;
            for (incremental_files.items[0..files_to_delete]) |item| {
                fs.cwd().deleteFile(item.path) catch |err| {
                    print("Cannot delete file {s}: {any}\n", .{ item.path, err });
                };
                print("Deleted old incremental backup: {s}\n", .{item.path});
                self.allocator.free(item.path);
            }
        }

        print("Cleanup completed\n", .{});
    }

    pub fn getIncrementalStats(self: *IncrementalBackupEngine, manifest: *IncrementalManifest) void {
        _ = self;
        print("Incremental Backup Analysis:\n", .{});
        print("===========================\n", .{});

        var unchanged_count: u32 = 0;
        var modified_count: u32 = 0;
        var added_count: u32 = 0;
        var deleted_count: u32 = 0;
        var renamed_count: u32 = 0;

        for (manifest.changes.items) |change| {
            switch (change.change_type) {
                .unchanged => unchanged_count += 1,
                .modified => modified_count += 1,
                .added => added_count += 1,
                .deleted => deleted_count += 1,
                .renamed, .moved => renamed_count += 1,
            }
        }

        print("Unchanged files: {d}\n", .{unchanged_count});
        print("Modified files: {d}\n", .{modified_count});
        print("Added files: {d}\n", .{added_count});
        print("Deleted files: {d}\n", .{deleted_count});
        print("Renamed/moved files: {d}\n", .{renamed_count});

        const change_percentage = if (manifest.total_files_scanned > 0)
            (@as(f64, @floatFromInt(manifest.changes.items.len - unchanged_count)) / @as(f64, @floatFromInt(manifest.total_files_scanned))) * 100.0
        else
            0.0;

        print("Change percentage: {d:.1}%\n", .{change_percentage});
    }

    pub fn validateIncrementalBackup(self: *IncrementalBackupEngine, manifest: *IncrementalManifest) !bool {
        _ = self;
        print("Validating incremental backup integrity...\n", .{});

        var valid_files: u32 = 0;
        var invalid_files: u32 = 0;

        for (manifest.changes.items) |change| {
            if (change.change_type == .unchanged) continue;

            const file = fs.cwd().openFile(change.path, .{}) catch |err| {
                print("  ✗ {s}: {any}\n", .{ change.path, err });
                invalid_files += 1;
                continue;
            };
            defer file.close();

            const stat = try file.stat();

            if (change.new_mtime != null and stat.mtime != change.new_mtime) {
                print("  ⚠ {s}: mtime mismatch\n", .{change.path});
            }

            if (change.new_size != null and stat.size != change.new_size) {
                print("  ⚠ {s}: size mismatch\n", .{change.path});
            }

            print("  ✓ {s}\n", .{change.path});
            valid_files += 1;
        }

        print("Validation complete: {d} valid, {d} invalid\n", .{ valid_files, invalid_files });
        return invalid_files == 0;
    }
};
