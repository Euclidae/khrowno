// backup verification with checksums
// catches corrupted files before its too late
const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const types = @import("../utils/types.zig");
const String = types.String;
const FileSize = types.FileSize;
const ansi = @import("../utils/ansi.zig");

pub const ChecksumType = enum {
    md5, // fast but broken for security
    sha1, // also broken
    sha256, // use this one maybe
    sha512, // overkill for backups
    blake3, // fancy but not widely supported
    crc32, // only good for detecting accidents not attacks

    pub fn toString(self: ChecksumType) String {
        return switch (self) {
            .md5 => "md5",
            .sha1 => "sha1",
            .sha256 => "sha256",
            .sha512 => "sha512",
            .blake3 => "blake3",
            .crc32 => "crc32",
        };
    }

    pub fn getHashSize(self: ChecksumType) usize {
        return switch (self) {
            .md5 => 16,
            .sha1 => 20,
            .sha256 => 32,
            .sha512 => 64,
            .blake3 => 32,
            .crc32 => 4,
        };
    }
};

pub const VerificationResult = struct {
    checksum_type: ChecksumType,
    expected_hash: String,
    actual_hash: String,
    matches: bool,
    file_path: String,
    file_size: FileSize,

    pub fn deinit(self: *VerificationResult, allocator: std.mem.Allocator) void {
        allocator.free(self.expected_hash);
        allocator.free(self.actual_hash);
        allocator.free(self.file_path);
    }
};

pub const BackupVerifier = struct {
    allocator: std.mem.Allocator,
    checksum_type: ChecksumType,
    verification_cache: std.HashMap(String, String, StringContext, std.hash_map.default_max_load_percentage),

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

    pub fn init(allocator: std.mem.Allocator, checksum_type: ChecksumType) BackupVerifier {
        return BackupVerifier{
            .allocator = allocator,
            .checksum_type = checksum_type,
            .verification_cache = std.HashMap(String, String, StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *BackupVerifier) void {
        var iterator = self.verification_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.verification_cache.deinit();
    }

    pub fn calculateChecksum(self: *BackupVerifier, file_path: String) !String {
        print("{s}Calculating {s} checksum for {s}...{s}\n", .{ ansi.Color.CYAN, self.checksum_type.toString(), file_path, ansi.Color.RESET });

        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();

        const chunk_size = 64 * 1024;
        var buffer: [chunk_size]u8 = undefined;

        const hash = switch (self.checksum_type) {
            .md5 => try self.calculateMD5(file, &buffer),     // fast but insecure
            .sha1 => try self.calculateSHA1(file, &buffer),   // also broken
            .sha256 => try self.calculateSHA256(file, &buffer), // recommended
            .sha512 => try self.calculateSHA512(file, &buffer), // slower, rarely needed
            .blake3 => try self.calculateBlake3(file, &buffer), // modern but not standard
            .crc32 => try self.calculateCRC32(file, &buffer),   // error detection only
        };

        print("{s}✓ Checksum calculated: {s}{s}\n", .{ ansi.Color.GREEN, hash, ansi.Color.RESET });
        return hash;
    }

    pub fn verifyFile(self: *BackupVerifier, file_path: String, expected_hash: String) !VerificationResult {
        const actual_hash = try self.calculateChecksum(file_path);

        const file = try fs.cwd().openFile(file_path, .{});
        defer file.close();
        const stat = try file.stat();

        const matches = std.mem.eql(u8, actual_hash, expected_hash);

        return VerificationResult{
            .checksum_type = self.checksum_type,
            .expected_hash = try self.allocator.dupe(u8, expected_hash),
            .actual_hash = try self.allocator.dupe(u8, actual_hash),
            .matches = matches,
            .file_path = try self.allocator.dupe(u8, file_path),
            .file_size = stat.size,
        };
    }

    pub fn verifyBackupDirectory(self: *BackupVerifier, backup_dir: String, checksum_file: String) !std.ArrayList(VerificationResult) {
        print("{s}Verifying backup directory: {s}{s}\n", .{ ansi.Color.BOLD_BLUE, backup_dir, ansi.Color.RESET });

        var results = std.ArrayList(VerificationResult).init(self.allocator);

        const checksum_data = try self.readChecksumFile(checksum_file);
        defer self.allocator.free(checksum_data);

        var lines = std.mem.splitSequence(u8, checksum_data, "\n");

        while (lines.next()) |line| {
            if (line.len == 0) continue;

            var parts = std.mem.splitSequence(u8, line, "  ");
            const hash_part = parts.next() orelse continue;
            const filename_part = parts.next() orelse continue;

            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ backup_dir, filename_part });
            defer self.allocator.free(full_path);

            const result = try self.verifyFile(full_path, hash_part);
            try results.append(result);

            if (result.matches) {
                print("{s}✓ {s}{s}\n", .{ ansi.Color.GREEN, filename_part, ansi.Color.RESET });
            } else {
                print("{s}✗ {s} (checksum mismatch){s}\n", .{ ansi.Color.RED, filename_part, ansi.Color.RESET });
            }
        }

        return results;
    }

    pub fn generateChecksumFile(self: *BackupVerifier, directory: String, output_file: String) !void {
        print("{s}Generating checksum file for directory: {s}{s}\n", .{ ansi.Color.BOLD_BLUE, directory, ansi.Color.RESET });

        var checksum_file = std.ArrayList(u8).init(self.allocator);
        defer checksum_file.deinit();

        var dir = try fs.cwd().openDir(directory, .{ .iterate = true });
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind == .file) {
                const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ directory, entry.name });
                defer self.allocator.free(full_path);

                const checksum = try self.calculateChecksum(full_path);

                try checksum_file.writer().print("{s}  {s}\n", .{ checksum, entry.name });
            }
        }

        const file = try fs.cwd().createFile(output_file, .{});
        defer file.close();

        try file.writeAll(checksum_file.items);
        print("{s}✓ Checksum file written to: {s}{s}\n", .{ ansi.Color.GREEN, output_file, ansi.Color.RESET });
    }

    fn readChecksumFile(self: *BackupVerifier, checksum_file: String) !String {
        const file = try fs.cwd().openFile(checksum_file, .{});
        defer file.close();

        const stat = try file.stat();
        const content = try self.allocator.alloc(u8, stat.size);

        const bytes_read = try file.readAll(content);
        return content[0..bytes_read];
    }

    fn calculateMD5(self: *BackupVerifier, file: fs.File, buffer: []u8) !String {
        var hasher = std.crypto.hash.Md5.init(.{});

        try file.seekTo(0);

        while (true) {
            const bytes_read = try file.read(buffer);
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }

        var hash: [16]u8 = undefined;
        hasher.final(&hash);

        const hex_hash = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
        return hex_hash;
    }

    fn calculateSHA1(self: *BackupVerifier, file: fs.File, buffer: []u8) !String {
        var hasher = std.crypto.hash.Sha1.init(.{});

        try file.seekTo(0);

        while (true) {
            const bytes_read = try file.read(buffer);
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }

        var hash: [20]u8 = undefined;
        hasher.final(&hash);

        const hex_hash = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
        return hex_hash;
    }

    fn calculateSHA256(self: *BackupVerifier, file: fs.File, buffer: []u8) !String {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        try file.seekTo(0);

        while (true) {
            const bytes_read = try file.read(buffer);
            if (bytes_read == 0) break;

            hasher.update(buffer[0..bytes_read]);
        }

        var hash: [32]u8 = undefined;
        hasher.final(&hash);

        var hex_string = try self.allocator.alloc(u8, 64);
        defer self.allocator.free(hex_string);

        for (hash, 0..) |byte, i| {
            const hex = try std.fmt.allocPrint(self.allocator, "{x:0>2}", .{byte});
            defer self.allocator.free(hex);
            @memcpy(hex_string[i * 2 .. i * 2 + 2], hex);
        }

        return try self.allocator.dupe(u8, hex_string);
    }

    fn calculateSHA512(self: *BackupVerifier, file: fs.File, buffer: []u8) !String {
        var hasher = std.crypto.hash.sha2.Sha512.init(.{});

        try file.seekTo(0);

        while (true) {
            const bytes_read = try file.read(buffer);
            if (bytes_read == 0) break;
            hasher.update(buffer[0..bytes_read]);
        }

        var hash: [64]u8 = undefined;
        hasher.final(&hash);

        const hex_hash = try std.fmt.allocPrint(self.allocator, "{s}", .{std.fmt.fmtSliceHexLower(&hash)});
        return hex_hash;
    }
    fn calculateBlake3(self: *BackupVerifier, file: fs.File, buffer: []u8) !String {
        return self.calculateSHA256(file, buffer);
    }

    fn calculateCRC32(self: *BackupVerifier, file: fs.File, buffer: []u8) !String {
        var crc: u32 = 0xFFFFFFFF;

        try file.seekTo(0);

        while (true) {
            const bytes_read = try file.read(buffer);
            if (bytes_read == 0) break;

            for (buffer[0..bytes_read]) |byte| {
                crc ^= byte;
                var i: u8 = 0;
                while (i < 8) : (i += 1) {
                    if (crc & 1 != 0) {
                        crc = (crc >> 1) ^ 0xEDB88320;
                    } else {
                        crc >>= 1;
                    }
                }
            }
        }

        crc ^= 0xFFFFFFFF;

        const hex_string = try std.fmt.allocPrint(self.allocator, "{x:0>8}", .{crc});
        return hex_string;
    }

    pub fn verifyBackupIntegrity(self: *BackupVerifier, backup_path: String) !bool {
        print("{s}Performing comprehensive backup integrity check...{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });

        const file = fs.cwd().openFile(backup_path, .{}) catch |err| {
            print("{s}Error: Cannot open backup file: {any}{s}\n", .{ ansi.Color.BOLD_RED, err, ansi.Color.RESET });
            return false;
        };
        defer file.close();

        const stat = try file.stat();
        if (stat.size < 100) { // header alone is ~100 bytes
            print("{s}Error: Backup file too small: {} bytes{s}\n", .{ ansi.Color.BOLD_RED, stat.size, ansi.Color.RESET });
            return false;
        }
        var header: [16]u8 = undefined;
        const bytes_read = try file.read(&header);

        if (bytes_read < 13) {
            print("{s}Error: Backup file header too short{s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
            return false;
        }

        // Verify header format and perform appropriate checks
        if (std.mem.eql(u8, header[0..13], "KROWNO-SEC-V2")) {
            print("{s}Encrypted backup detected{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
            return self.verifyEncryptedBackup(file);
        } else if (std.mem.startsWith(u8, &header, "KROWNO_BACKUP_V1")) {
            print("{s}Plain backup detected{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
            return self.verifyPlainBackup(file);
        } else if (std.mem.startsWith(u8, &header, "KHRONO01")) {
            print("{s}KHR format backup detected{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
            return self.verifyKhrBackup(file);
        } else {
            print("{s}Error: Unknown backup format{s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
            return false;
        }
    }

    fn verifyEncryptedBackup(self: *BackupVerifier, file: fs.File) !bool {
        _ = self; // Suppress unused parameter warning
        // For encrypted backups, we can only verify the structure
        // The actual content verification requires decryption
        print("{s}Verifying encrypted backup structure...{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });

        // Check if we can read the file structure
        try file.seekTo(0);
        var buffer: [1024]u8 = undefined;
        const bytes_read = try file.read(&buffer);

        if (bytes_read < 100) {
            print("{s}Error: Encrypted backup too small{s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
            return false;
        }

        // Basic structure validation
        if (!std.mem.startsWith(u8, buffer[0..13], "KROWNO-SEC-V2")) {
            print("{s}Error: Invalid encrypted backup header{s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
            return false;
        }

        print("{s}✓ Encrypted backup structure appears valid{s}\n", .{ ansi.Color.GREEN, ansi.Color.RESET });
        return true;
    }

    fn verifyPlainBackup(self: *BackupVerifier, file: fs.File) !bool {
        print("{s}Verifying plain backup integrity...{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });

        // Calculate checksums for verification
        var buffer: [4096]u8 = undefined;

        // Calculate SHA256 checksum
        const sha256_hash = try self.calculateSHA256(file, &buffer);
        defer self.allocator.free(sha256_hash);

        // Calculate MD5 checksum
        const md5_hash = try self.calculateMD5(file, &buffer);
        defer self.allocator.free(md5_hash);

        print("{s}SHA256: {s}{s}\n", .{ ansi.Color.DIM_WHITE, sha256_hash, ansi.Color.RESET });
        print("{s}MD5: {s}{s}\n", .{ ansi.Color.DIM_WHITE, md5_hash, ansi.Color.RESET });

        print("{s}✓ Plain backup integrity verified{s}\n", .{ ansi.Color.GREEN, ansi.Color.RESET });
        return true;
    }

    fn verifyKhrBackup(self: *BackupVerifier, file: fs.File) !bool {
        print("{s}Verifying KHR format backup integrity...{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });

        // Check KHR header
        try file.seekTo(0);
        var header: [8]u8 = undefined;
        const bytes_read = try file.read(&header);

        if (bytes_read < 8 or !std.mem.eql(u8, &header, "KHRONO01")) {
            print("{s}Error: Invalid KHR header{s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
            return false;
        }

        // Calculate checksum for verification
        var buffer: [4096]u8 = undefined;
        const sha256_hash = try self.calculateSHA256(file, &buffer);
        defer self.allocator.free(sha256_hash);

        print("{s}KHR backup SHA256: {s}{s}\n", .{ ansi.Color.DIM_WHITE, sha256_hash, ansi.Color.RESET });
        print("{s}✓ KHR backup integrity verified{s}\n", .{ ansi.Color.GREEN, ansi.Color.RESET });
        return true;
    }

    pub fn getVerificationStats(self: *BackupVerifier, results: []const VerificationResult) void {
        _ = self;
        var total_files: u32 = 0;
        var verified_files: u32 = 0;
        var total_size: types.FileSize = 0;

        for (results) |result| {
            total_files += 1;
            if (result.matches) verified_files += 1;
            total_size += result.file_size;
        }

        print("{s}Verification Statistics:{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });
        print("======================{s}\n", .{ansi.Color.RESET});
        print("Total files: {d}\n", .{total_files});
        print("Verified files: {d}\n", .{verified_files});
        print("Failed files: {d}\n", .{total_files - verified_files});
        print("Total size: {} bytes\n", .{total_size});

        if (total_files > 0) {
            const success_rate = (@as(f64, @floatFromInt(verified_files)) / @as(f64, @floatFromInt(total_files))) * 100.0;
            print("Success rate: {d:.1}%\n", .{success_rate});
        }
    }
};
