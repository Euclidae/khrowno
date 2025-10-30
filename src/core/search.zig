const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const backup = @import("backup.zig");
const types = @import("../utils/types.zig");
const String = types.String;
const ansi = @import("../utils/ansi.zig");

// okay, here me out. Maybe, I don't wanna fzf but wanna use substring??
// might just remove this cuz um...
pub const SearchCriteria = struct {
    name_pattern: ?String = null,
    date_from: ?types.Timestamp = null,
    date_to: ?types.Timestamp = null,
    min_size: ?types.FileSize = null,
    max_size: ?types.FileSize = null,
    strategy: ?String = null,
    hostname: ?String = null,
    username: ?String = null,
    encrypted_only: bool = false,
    plain_only: bool = false,

    pub fn deinit(self: *SearchCriteria, allocator: std.mem.Allocator) void {
        if (self.name_pattern) |pattern| allocator.free(pattern);
        if (self.strategy) |strategy| allocator.free(strategy);
        if (self.hostname) |hostname| allocator.free(hostname);
        if (self.username) |username| allocator.free(username);
    }
};

pub const BackupSearchResult = struct {
    file_path: String,
    file_name: String,
    file_size: types.FileSize,
    created_date: types.Timestamp,
    modified_date: types.Timestamp,
    backup_info: backup.BackupInfo,
    match_score: f64, // higher score = better match, helps sort results by relevance

    pub fn deinit(self: *BackupSearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.file_name);
        self.backup_info.deinit(allocator);
    }
};

pub const BackupSearcher = struct {
    allocator: std.mem.Allocator,
    search_cache: std.HashMap(String, BackupSearchResult, StringContext, std.hash_map.default_max_load_percentage),

    const StringContext = struct {
        pub fn hash(self: @This(), s: String) u64 {
            _ = self;
            return std.hash_map.hashString(s);
        }
        pub fn eql(self: @This(), a: String, b: String) bool {
            _ = self;
            return std.mem.eql(u8, a, b);
        }
    };

    pub fn init(allocator: std.mem.Allocator) BackupSearcher {
        return BackupSearcher{
            .allocator = allocator,
            .search_cache = std.HashMap(String, BackupSearchResult, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *BackupSearcher) void {
        var iterator = self.search_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.search_cache.deinit();
    }

    pub fn searchBackups(self: *BackupSearcher, search_directory: String, criteria: SearchCriteria) !std.ArrayList(BackupSearchResult) {
        print("{s}Searching for backups in: {s}{s}\n", .{ ansi.Color.CYAN, search_directory, ansi.Color.RESET });

        var results = std.ArrayList(BackupSearchResult).init(self.allocator);

        try self.scanDirectoryForBackups(search_directory, &results, criteria);

        std.sort.pdq(BackupSearchResult, results.items, {}, struct {
            pub fn lessThan(_: void, a: BackupSearchResult, b: BackupSearchResult) bool {
                return a.match_score > b.match_score;
            }
        }.lessThan);

        print("{s}Found {d} matching backups{s}\n", .{ ansi.Color.GREEN, results.items.len, ansi.Color.RESET });
        return results;
    }

    fn scanDirectoryForBackups(self: *BackupSearcher, directory: String, results: *std.ArrayList(BackupSearchResult), criteria: SearchCriteria) !void {
        var dir = fs.cwd().openDir(directory, .{ .iterate = true }) catch |err| {
            print("{s}Error: Cannot open directory {s}: {any}{s}\n", .{ ansi.Color.BOLD_RED, directory, err, ansi.Color.RESET });
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory, entry.name });
            defer self.allocator.free(full_path);

            switch (entry.kind) {
                .file => {
                    if (self.isBackupFile(entry.name)) {
                        if (try self.matchesCriteria(full_path, entry.name, criteria)) {
                            const result = try self.createSearchResult(full_path, entry.name);
                            try results.append(result);
                        }
                    }
                },
                .directory => {
                    try self.scanDirectoryForBackups(full_path, results, criteria);
                },
                else => {},
            }
        }
    }
    fn isBackupFile(self: *BackupSearcher, filename: String) bool {
        _ = self;
        // checking common backup extensions, .krowno is ours obviously
        const extensions = [_]String{ ".krowno", ".backup", ".bak", ".tar", ".gz", ".bz2", ".xz" };

        for (extensions) |ext| {
            if (std.mem.endsWith(u8, filename, ext)) {
                return true;
            }
        }

        return false;
    }

    fn matchesCriteria(self: *BackupSearcher, file_path: String, filename: String, criteria: SearchCriteria) !bool {
        if (criteria.name_pattern) |pattern| {
            if (std.mem.indexOf(u8, filename, pattern) == null) {
                return false;
            }
        }

        const file = fs.cwd().openFile(file_path, .{}) catch return false;
        defer file.close();

        const stat = try file.stat();

        if (criteria.min_size) |min_size| {
            if (stat.size < min_size) return false;
        }
        if (criteria.max_size) |max_size| {
            if (stat.size > max_size) return false;
        }

        if (criteria.date_from) |date_from| {
            if (stat.mtime < date_from) return false;
        }
        if (criteria.date_to) |date_to| {
            if (stat.mtime > date_to) return false;
        }

        var backup_info = backup.getBackupInfo(self.allocator, file_path) catch return false;
        defer backup_info.deinit(self.allocator);

        if (criteria.encrypted_only and !backup_info.encrypted) return false;
        if (criteria.plain_only and backup_info.encrypted) return false;

        if (criteria.hostname) |hostname| {
            if (std.mem.indexOf(u8, backup_info.hostname, hostname) == null) return false;
        }

        if (criteria.username) |username| {
            if (std.mem.indexOf(u8, backup_info.username, username) == null) return false;
        }

        if (criteria.strategy) |strategy| {
            if (std.mem.indexOf(u8, backup_info.version, strategy) == null) return false;
        }

        return true;
    }

    fn createSearchResult(self: *BackupSearcher, file_path: String, filename: String) !BackupSearchResult {
        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();

        const stat = try file.stat();
        const backup_info = try backup.getBackupInfo(self.allocator, file_path);

        var match_score: f64 = 1.0;

        // boost score for recent backups - you probably want the newer ones
        const age_days = @divTrunc(std.time.timestamp() - stat.mtime, 24 * 60 * 60);
        if (age_days < 7) match_score += 0.5; // last week gets big boost
        if (age_days < 30) match_score += 0.3; // last month still relevant
        if (age_days < 90) match_score += 0.1; // last 3 months maybe useful

        // larger backups usually mean more complete, so rank them higher
        if (stat.size > 100 * 1024 * 1024) match_score += 0.2; // 100MB+ is substantial
        if (stat.size > 10 * 1024 * 1024) match_score += 0.1; // 10MB+ is decent

        return BackupSearchResult{
            .file_path = try self.allocator.dupe(u8, file_path),
            .file_name = try self.allocator.dupe(u8, filename),
            .file_size = stat.size,
            .created_date = backup_info.timestamp,
            .modified_date = @as(i64, @intCast(stat.mtime)),
            .backup_info = backup_info,
            .match_score = match_score,
        };
    }

    pub fn findBackupsByDate(self: *BackupSearcher, search_directory: String, days_back: u32) !std.ArrayList(BackupSearchResult) {
        const current_time = std.time.timestamp();
        const from_time = current_time - (@as(types.Timestamp, @intCast(days_back)) * 24 * 60 * 60);

        var criteria = SearchCriteria{};
        criteria.date_from = from_time;
        criteria.date_to = current_time;

        return try self.searchBackups(search_directory, criteria);
    }

    pub fn findBackupsBySize(self: *BackupSearcher, search_directory: String, min_size: types.FileSize, max_size: types.FileSize) !std.ArrayList(BackupSearchResult) {
        var criteria = SearchCriteria{};
        criteria.min_size = min_size;
        criteria.max_size = max_size;

        return try self.searchBackups(search_directory, criteria);
    }

    pub fn findBackupsByHostname(self: *BackupSearcher, search_directory: String, hostname: String) !std.ArrayList(BackupSearchResult) {
        var criteria = SearchCriteria{};
        criteria.hostname = try self.allocator.dupe(u8, hostname);
        defer self.allocator.free(criteria.hostname.?);

        return try self.searchBackups(search_directory, criteria);
    }

    pub fn findBackupsByUsername(self: *BackupSearcher, search_directory: String, username: String) !std.ArrayList(BackupSearchResult) {
        var criteria = SearchCriteria{};
        criteria.username = try self.allocator.dupe(u8, username);
        defer self.allocator.free(criteria.username.?);

        return try self.searchBackups(search_directory, criteria);
    }

    pub fn findDuplicateBackups(self: *BackupSearcher, search_directory: String) !std.ArrayList(std.ArrayList(BackupSearchResult)) {
        print("{s}Searching for duplicate backups...{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });

        var all_backups = try self.searchBackups(search_directory, SearchCriteria{});
        defer {
            for (all_backups.items) |*result| {
                result.deinit(self.allocator);
            }
            all_backups.deinit();
        }

        var duplicates = std.ArrayList(std.ArrayList(BackupSearchResult)).init(self.allocator);

        var i: usize = 0;
        while (i < all_backups.items.len) {
            var group = std.ArrayList(BackupSearchResult).init(self.allocator);
            const base_backup = all_backups.items[i];

            try group.append(BackupSearchResult{
                .file_path = try self.allocator.dupe(u8, base_backup.file_path),
                .file_name = try self.allocator.dupe(u8, base_backup.file_name),
                .file_size = base_backup.file_size,
                .created_date = base_backup.created_date,
                .modified_date = base_backup.modified_date,
                .backup_info = base_backup.backup_info,
                .match_score = base_backup.match_score,
            });

            var j = i + 1;
            while (j < all_backups.items.len) {
                const other_backup = all_backups.items[j];

                // duplicates = same host/user + size within 10% (probably same backup, different timestamp)
                if (std.mem.eql(u8, base_backup.backup_info.hostname, other_backup.backup_info.hostname) and
                    std.mem.eql(u8, base_backup.backup_info.username, other_backup.backup_info.username) and
                    std.abs(@as(i64, @intCast(base_backup.file_size)) - @as(i64, @intCast(other_backup.file_size))) < @as(i64, @intCast(base_backup.file_size / 10)))
                {
                    try group.append(BackupSearchResult{
                        .file_path = try self.allocator.dupe(u8, other_backup.file_path),
                        .file_name = try self.allocator.dupe(u8, other_backup.file_name),
                        .file_size = other_backup.file_size,
                        .created_date = other_backup.created_date,
                        .modified_date = other_backup.modified_date,
                        .backup_info = other_backup.backup_info,
                        .match_score = other_backup.match_score,
                    });

                    _ = all_backups.swapRemove(j);
                } else {
                    j += 1;
                }
            }

            if (group.items.len > 1) {
                try duplicates.append(group);
            } else {
                group.deinit();
            }

            i += 1;
        }

        print("{s}Found {d} groups of duplicate backups{s}\n", .{ ansi.Color.GREEN, duplicates.items.len, ansi.Color.RESET });
        return duplicates;
    }

    pub fn getBackupStatistics(self: *BackupSearcher, directory: String) !void {
        print("{s}Scanning for backups in: {s}{s}\n", .{ ansi.Color.CYAN, directory, ansi.Color.RESET });

        var results = try self.searchBackups(directory, SearchCriteria{});
        defer {
            for (results.items) |*result| {
                result.deinit(self.allocator);
            }
            results.deinit();
        }

        self.getSearchStatistics(results.items);
    }

    pub fn getSearchStatistics(self: *BackupSearcher, results: []BackupSearchResult) void {
        _ = self;
        print("{s}Generating backup statistics...{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });

        var total_size: types.FileSize = 0;
        var encrypted_count: u32 = 0;
        var plain_count: u32 = 0;
        var oldest_date: types.Timestamp = std.time.timestamp();
        var newest_date: types.Timestamp = 0;

        for (results) |backup_item| {
            total_size += backup_item.file_size;

            if (backup_item.backup_info.encrypted) {
                encrypted_count += 1;
            } else {
                plain_count += 1;
            }

            if (backup_item.created_date < oldest_date) {
                oldest_date = backup_item.created_date;
            }
            if (backup_item.created_date > newest_date) {
                newest_date = backup_item.created_date;
            }
        }

        print("{s}Backup Statistics:{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });
        print("================={s}\n", .{ansi.Color.RESET});
        print("Total backups: {d}\n", .{results.len});
        print("Total size: {} bytes ({d:.1} MB)\n", .{ total_size, total_size / (1024 * 1024) });
        print("Encrypted backups: {d}\n", .{encrypted_count});
        print("Plain backups: {d}\n", .{plain_count});
        print("Oldest backup: {d}\n", .{oldest_date});
        print("Newest backup: {d}\n", .{newest_date});

        if (results.len > 0) {
            const avg_size = total_size / results.len;
            print("Average size: {} bytes ({d:.1} MB)\n", .{ avg_size, avg_size / (1024 * 1024) });
        }
    }

    pub fn exportSearchResults(self: *BackupSearcher, results: []const BackupSearchResult, output_file: String) !void {
        _ = self;
        print("{s}Exporting search results to: {s}{s}\n", .{ ansi.Color.CYAN, output_file, ansi.Color.RESET });

        const file = try fs.cwd().createFile(output_file, .{});
        defer file.close();

        try file.writeAll("Backup Search Results\n");
        try file.writeAll("====================\n\n");

        for (results, 0..) |result, i| {
            try file.writer().print("{d}. {s}\n", .{ i + 1, result.file_name });
            try file.writer().print("   Path: {s}\n", .{result.file_path});
            try file.writer().print("   Size: {} bytes\n", .{result.file_size});
            try file.writer().print("   Created: {d}\n", .{result.created_date});
            try file.writer().print("   Hostname: {s}\n", .{result.backup_info.hostname});
            try file.writer().print("   Username: {s}\n", .{result.backup_info.username});
            try file.writer().print("   Encrypted: {any}\n", .{result.backup_info.encrypted});
            try file.writer().print("   Match Score: {d:.2}\n", .{result.match_score});
            try file.writeAll("\n");
        }

        print("{s}Export completed{s}\n", .{ ansi.Color.GREEN, ansi.Color.RESET });
    }

    pub fn generateStatistics(self: *BackupSearcher, backup_directory: String) !void {
        print("{s}Generating comprehensive backup statistics...{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });

        var total_backups: u32 = 0;
        var total_size: types.FileSize = 0;
        var encrypted_count: u32 = 0;
        var plain_count: u32 = 0;
        var incremental_count: u32 = 0;
        var full_count: u32 = 0;
        var oldest_date: types.Timestamp = std.math.maxInt(i64);
        var newest_date: types.Timestamp = 0;

        var dir = fs.cwd().openDir(backup_directory, .{ .iterate = true }) catch |err| {
            print("{s}Error: Cannot open backup directory {s}: {any}{s}\n", .{ ansi.Color.BOLD_RED, backup_directory, err, ansi.Color.RESET });
            return;
        };
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".khr") or std.mem.endsWith(u8, entry.name, ".krowno")) {
                total_backups += 1;

                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ backup_directory, entry.name });
                defer self.allocator.free(full_path);

                const stat = fs.cwd().statFile(full_path) catch continue;
                total_size += stat.size;

                if (stat.mtime < oldest_date) oldest_date = stat.mtime;
                if (stat.mtime > newest_date) newest_date = stat.mtime;

                // filename tells us if it's incremental or full backup
                if (std.mem.startsWith(u8, entry.name, "incremental_")) {
                    incremental_count += 1;
                } else {
                    full_count += 1;
                }

                // peek at file header to see if it's encrypted
                const file = fs.cwd().openFile(full_path, .{}) catch continue;
                defer file.close();

                var header: [16]u8 = undefined;
                const bytes_read = file.read(&header) catch continue;

                if (bytes_read >= 13 and std.mem.eql(u8, header[0..13], "KROWNO-SEC-V2")) {
                    encrypted_count += 1;
                } else {
                    plain_count += 1;
                }
            }
        }

        print("\n{s}=== Backup Statistics ==={s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });
        print("Total backups: {d}\n", .{total_backups});
        print("Total size: {} bytes ({d:.1} GB)\n", .{ total_size, @as(f64, @floatFromInt(total_size)) / (1024 * 1024 * 1024) });
        print("Encrypted backups: {d}\n", .{encrypted_count});
        print("Plain backups: {d}\n", .{plain_count});
        print("Full backups: {d}\n", .{full_count});
        print("Incremental backups: {d}\n", .{incremental_count});

        if (oldest_date != std.math.maxInt(i64)) {
            print("Oldest backup: {d}\n", .{oldest_date});
        }
        if (newest_date != 0) {
            print("Newest backup: {d}\n", .{newest_date});
        }

        if (total_backups > 0) {
            const avg_size = total_size / total_backups;
            print("Average size: {} bytes ({d:.1} MB)\n", .{ avg_size, avg_size / (1024 * 1024) });
        }

        print("{s}========================{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });
    }
};
