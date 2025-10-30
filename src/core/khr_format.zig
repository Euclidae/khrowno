//! .khr file format - custom because tar.gz is boring
//! would be nice if zig had block comments but we're stuck with // everywhere
//! use streaming_crypto for large backups to avoid OOM
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const print = std.debug.print;
const fs = std.fs;
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;
const FileSize = types.FileSize;
const Timestamp = types.Timestamp;
const security = @import("../security/crypto.zig");
const streaming_crypto = @import("../security/streaming_crypto.zig");
const compress = @import("../utils/compress.zig");

pub const SaveProgressCallback = *const fn (operation: String, current: usize, total: usize) void;

pub const KhrHeader = struct {
    magic: [8]u8 = "KHRONO01".*,
    version: u32 = 1,
    compression: CompressionType = .none,
    encryption: EncryptionInfo = undefined,
    tar_size: FileSize = 0,
    checksum: [32]u8 = undefined,

    const Self = @This();

    pub fn write(self: *const Self, writer: anytype) !void {
        try writer.writeAll(&self.magic);
        try writer.writeInt(u32, self.version, .little);
        try writer.writeInt(u8, @intFromEnum(self.compression), .little);
        try self.encryption.write(writer);
        try writer.writeInt(FileSize, self.tar_size, .little);
        try writer.writeAll(&self.checksum);
    }

    // Streaming extractor for V2 payloads.
    // On-dsk layout (all little-endian):
    //   "KHRV2\n" magic
    //   Repeated entries:
    //     tag: u8                 1=file, 2=symlink
    //     path_len: u32           number of bytes in path
    //     path: [path_len]u8      UTF-8 bytes (no NUL)
    //     mode: u64               unix mode bit
    //     mtime: i64              seconds since epoch
    //     if tag==1 (file):
    //         size: u64
    //         data: [size]u8
    //     if tag==2 (symlink):
    //         target_len: u32
    //         target: [target_len]u8
    // Hashing note: we hash the uncompressed byte in the exact order written
    // (including magic[constants or values that are used in algorithms that may appear arbitrary]
    //  and metadata), then compare to header.checksum. The
    // create() path updates the hasher with the same uncompressed stream, so
    // the verifier must decompress first (as done here).
    //
    fn extractKhrBackupStreamingGzip(allocator: Allocator, file: fs.File, data_start: u64, payload_len: u64, extract_to: String, expected_checksum: [32]u8) !void {
        const V2_MAGIC = "KHRV2\n";
        try file.seekTo(data_start);

        const base_reader = file.reader();
        var limited = std.io.limitedReader(base_reader, payload_len);
        var dec = std.compress.gzip.decompressor(limited.reader());
        var reader = dec.reader();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        var hdrbuf: [6]u8 = undefined;
        const mread = reader.readAll(&hdrbuf) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return KhrError.ArchiveFormatFailed,
        };
        if (mread != V2_MAGIC.len or !std.mem.eql(u8, &hdrbuf, V2_MAGIC)) return KhrError.ArchiveFormatFailed;
        hasher.update(V2_MAGIC);

        var b4: [4]u8 = undefined;
        var b8: [8]u8 = undefined;
        var tagbuf: [1]u8 = undefined;
        var tmp: [64 * 1024]u8 = undefined;

        const sanitize = struct {
            fn sanitizeRelativePath(alloc: Allocator, p: String) ![]u8 {
                var start: usize = 0;
                while (start < p.len and p[start] == '/') start += 1;
                var out = std.ArrayList(u8).init(alloc);
                errdefer out.deinit();
                var it = std.mem.splitScalar(u8, p[start..], '/');
                var first = true;
                while (it.next()) |seg| {
                    if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
                        return KhrError.ArchiveFormatFailed;
                    }
                    if (!first) try out.append('/');
                    first = false;
                    try out.appendSlice(seg);
                }
                if (out.items.len == 0) return KhrError.ArchiveFormatFailed;
                return out.toOwnedSlice();
            }
        };

        // Main read loop: read a tag, then parse a record. We avoid buffering
        // the entire archive; everything is streamed and written incrementally.
        while (true) {
            const tr = reader.readAll(&tagbuf) catch |err| {
                if (err == error.EndOfStream) break;
                return KhrError.ArchiveFormatFailed;
            };
            if (tr == 0) break;
            if (tr != 1) return KhrError.ArchiveFormatFailed;
            hasher.update(&tagbuf);
            const tag = tagbuf[0];
            // tag 1=file, 2=symlink

            const pr = reader.readAll(&b4) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (pr != b4.len) return KhrError.ArchiveFormatFailed;
            hasher.update(&b4);
            const path_len = std.mem.readInt(u32, &b4, .little);

            const path_slice = try allocator.alloc(u8, path_len); // allocate exact path bytes
            defer allocator.free(path_slice);
            const got = reader.readAll(path_slice) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (got != path_len) return KhrError.ArchiveFormatFailed;
            hasher.update(path_slice);
            // Prevent path traversal and absolute paths. If sanitize fails we bail.
            const safe_rel = sanitize.sanitizeRelativePath(allocator, path_slice) catch return KhrError.ArchiveFormatFailed;
            defer allocator.free(safe_rel);
            print("Extracting: {s}\n", .{safe_rel});

            const mr = reader.readAll(&b8) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (mr != b8.len) return KhrError.ArchiveFormatFailed;
            hasher.update(&b8);
            const mode_val_u64 = std.mem.readInt(u64, &b8, .little);

            const mt = reader.readAll(&b8) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (mt != b8.len) return KhrError.ArchiveFormatFailed;
            hasher.update(&b8);

            if (tag == 1) {
                const sr = reader.readAll(&b8) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (sr != b8.len) return KhrError.ArchiveFormatFailed;
                hasher.update(&b8);
                var size = std.mem.readInt(FileSize, &b8, .little);

                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, safe_rel }); // join without trusting input slashes
                defer allocator.free(full_path);
                if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                const out = try std.fs.cwd().createFile(full_path, .{});
                defer out.close();

                while (size > 0) {
                    const chunk: usize = @intCast(@min(size, tmp.len));
                    const n = reader.read(tmp[0..chunk]) catch |err| switch (err) {
                        error.EndOfStream => 0,
                        else => return KhrError.ArchiveFormatFailed,
                    };
                    if (n == 0) return KhrError.ArchiveFormatFailed;
                    try out.writeAll(tmp[0..n]);
                    hasher.update(tmp[0..n]);
                    size -= n;
                }

                if (builtin.os.tag == .linux) {
                    const perm: u32 = @intCast(mode_val_u64 & 0o7777);
                    posix.fchmod(out.handle, perm) catch {};
                }
            } else if (tag == 2) {
                // symlink: read target len and target (allow absolute or relative targets)
                const lr = reader.readAll(&b4) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (lr != b4.len) return KhrError.ArchiveFormatFailed;
                hasher.update(&b4);
                const target_len = std.mem.readInt(u32, &b4, .little);
                const target = try allocator.alloc(u8, target_len);
                defer allocator.free(target);
                const got2 = reader.readAll(target) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (got2 != target_len) return KhrError.ArchiveFormatFailed;
                hasher.update(target);

                const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, safe_rel });
                defer allocator.free(full_path);
                if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                const c_link = try allocator.allocSentinel(u8, full_path.len, 0);
                defer allocator.free(c_link);
                std.mem.copyForwards(u8, c_link, full_path);
                const c_target = try allocator.allocSentinel(u8, target.len, 0);
                defer allocator.free(c_target);
                std.mem.copyForwards(u8, c_target, target);
                posix.symlinkZ(c_target.ptr, c_link.ptr) catch {};
            } else {
                return KhrError.ArchiveFormatFailed;
            }
        }

        var checksum: [32]u8 = undefined;
        hasher.final(&checksum);
        if (!std.mem.eql(u8, &checksum, &expected_checksum)) return KhrError.ChecksumMismatch;
    }

    // Streaming creator for V2 payloads.
    // Design choices:
    // - We compress while we write to keep memory usage small.
    // - The checksum is over the uncompressed logical stream (same order the
    //   extractor reads), so verification doesn't depend on gzip chunking.
    // - We skip non-regular files (fifos, sockets, devices) to avoid hangs.
    // - Symlinks are encoded as tag=2 with a target string; we do not follow
    //   symlinks to avoid duplicating unrelated data.
    fn createKhrBackupStreamingGzip(allocator: Allocator, source_paths: []const String, output_path: String, progress_cb: ?SaveProgressCallback) !void {
        const V2_MAGIC = "KHRV2\n";
        const file = try fs.cwd().createFile(output_path, .{});
        defer file.close();

        var header = KhrHeader{
            .compression = .gzip,
            .encryption = EncryptionInfo{
                .algorithm = .chacha20_poly1305,
                .kdf = .argon2id,
                .salt = [_]u8{0} ** 32,
                .nonce = [_]u8{0} ** 12,
                .opslimit = 0,
                .memlimit = 0,
            },
            .tar_size = 0,
            .checksum = [_]u8{0} ** 32,
        };
        header.version = 2;

        try header.write(file.writer());
        const data_start = try file.getPos();

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        try file.writer().writeAll(V2_MAGIC);
        hasher.update(V2_MAGIC);

        var gz = try std.compress.gzip.compressor(file.writer(), .{});

        var b4: [4]u8 = undefined;
        var b8: [8]u8 = undefined;
        var tagbuf: [1]u8 = undefined;
        const total_files_gzip_create = source_paths.len;
        for (source_paths, 0..) |path, i| {
            if (progress_cb) |cb| {
                if (i % 100 == 0 or i == total_files_gzip_create - 1) {
                    cb("Saving files", i + 1, total_files_gzip_create);
                }
            }
            // Detect symlink via readlink
            const c_path = allocator.allocSentinel(u8, path.len, 0) catch continue;
            defer allocator.free(c_path);
            std.mem.copyForwards(u8, c_path, path);
            var linktmp: [4096]u8 = undefined;
            const maybe_target: ?[]u8 = posix.readlinkZ(c_path.ptr, linktmp[0..]) catch null;
            if (maybe_target) |target| {
                // Tag: 2=symlink
                tagbuf[0] = 2;
                try gz.writer().writeAll(&tagbuf);
                hasher.update(&tagbuf);

                std.mem.writeInt(u32, &b4, @as(u32, @intCast(path.len)), .little);
                try gz.writer().writeAll(&b4);
                hasher.update(&b4);
                try gz.writer().writeAll(path);
                hasher.update(path);
                std.mem.writeInt(u64, &b8, @as(u64, 0), .little);
                try gz.writer().writeAll(&b8);
                hasher.update(&b8);
                std.mem.writeInt(i64, &b8, @as(i64, 0), .little);
                try gz.writer().writeAll(&b8);
                hasher.update(&b8);

                std.mem.writeInt(u32, &b4, @as(u32, @intCast(target.len)), .little);
                try gz.writer().writeAll(&b4);
                hasher.update(&b4);
                try gz.writer().writeAll(target);
                hasher.update(target);
                continue;
            }

            // Only archive regular files; skip fifos, sockets, block/char devices to avoid blocking
            const f = fs.cwd().openFile(path, .{}) catch continue;
            defer f.close();
            const st = f.stat() catch continue;
            if (st.kind != .file) continue;

            tagbuf[0] = 1;
            try gz.writer().writeAll(&tagbuf);
            hasher.update(&tagbuf);

            std.mem.writeInt(u32, &b4, @as(u32, @intCast(path.len)), .little);
            try gz.writer().writeAll(&b4);
            hasher.update(&b4);
            try gz.writer().writeAll(path);
            hasher.update(path);

            std.mem.writeInt(u64, &b8, @as(u64, @intCast(st.mode)), .little);
            try gz.writer().writeAll(&b8);
            hasher.update(&b8);
            std.mem.writeInt(i64, &b8, @as(i64, @intCast(st.mtime)), .little);
            try gz.writer().writeAll(&b8);
            hasher.update(&b8);
            std.mem.writeInt(FileSize, &b8, @as(FileSize, @intCast(st.size)), .little);
            try gz.writer().writeAll(&b8);
            hasher.update(&b8);

            var buf: [1024 * 1024]u8 = undefined;
            var remaining: FileSize = st.size;
            while (remaining > 0) {
                const to_read: usize = @intCast(@min(remaining, buf.len));
                const n = try f.read(buf[0..to_read]);
                if (n == 0) break;
                try gz.writer().writeAll(buf[0..n]);
                hasher.update(buf[0..n]);
                remaining -= n;
            }
        }

        try gz.finish();
        const data_end = try file.getPos();
        const payload_len: u64 = @intCast(data_end - data_start);
        var checksum: [32]u8 = undefined;
        hasher.final(&checksum);
        header.tar_size = payload_len;
        header.checksum = checksum;

        try file.seekTo(0);
        try header.write(file.writer());
    }
    pub fn read(reader: anytype) !Self {
        var header: Self = undefined;

        _ = try reader.readAll(&header.magic);
        header.version = try reader.readInt(u32, .little);
        header.compression = @enumFromInt(try reader.readInt(u8, .little));
        header.encryption = try EncryptionInfo.read(reader);
        header.tar_size = try reader.readInt(FileSize, .little);
        _ = try reader.readAll(&header.checksum);

        if (!std.mem.eql(u8, &header.magic, "KHRONO01")) {
            return error.InvalidKhrFile;
        }

        return header;
    }
};

pub const CompressionType = enum(u8) {
    none = 0,
    gzip = 1,
    lz4 = 2,
    zstd = 3,
};

// This is some simple encryption metadata aligned with our crypto module
pub const EncAlgo = enum(u8) { chacha20_poly1305 = 1 };
pub const KdfAlgo = enum(u8) { argon2id = 1 };

pub const EncryptionInfo = struct {
    algorithm: EncAlgo = .chacha20_poly1305,
    kdf: KdfAlgo = .argon2id,
    salt: [32]u8 = undefined,
    nonce: [12]u8 = undefined,
    opslimit: u32 = 0,
    memlimit: u32 = 0,

    const Self = @This();

    pub fn write(self: *const Self, writer: anytype) !void {
        try writer.writeInt(u8, @intFromEnum(self.algorithm), .little);
        try writer.writeInt(u8, @intFromEnum(self.kdf), .little);
        try writer.writeAll(&self.salt);
        try writer.writeAll(&self.nonce);
        try writer.writeInt(u32, self.opslimit, .little);
        try writer.writeInt(u32, self.memlimit, .little);
    }

    pub fn read(reader: anytype) !Self {
        var info: Self = undefined;

        info.algorithm = @enumFromInt(try reader.readInt(u8, .little));
        info.kdf = @enumFromInt(try reader.readInt(u8, .little));
        _ = try reader.readAll(&info.salt);
        _ = try reader.readAll(&info.nonce);
        info.opslimit = try reader.readInt(u32, .little);
        info.memlimit = try reader.readInt(u32, .little);

        return info;
    }
};

pub const KhrError = error{
    InvalidKhrFile,
    UnsupportedVersion,
    CompressionFailed,
    DecompressionFailed,
    EncryptionFailed,
    DecryptionFailed,
    TarCreationFailed,
    TarExtractionFailed,
    ChecksumMismatch,
    OutOfMemory,
    ArchiveCreationFailed,
    ArchiveFormatFailed,
    ArchiveFilterFailed,
    ArchiveOpenFailed,
    ArchiveCloseFailed,
};

fn createKhrBackupStreaming(allocator: Allocator, source_paths: []const String, output_path: String, progress_cb: ?SaveProgressCallback) !void {
    const V2_MAGIC = "KHRV2\n";
    const file = try fs.cwd().createFile(output_path, .{});
    defer file.close();

    var header = KhrHeader{
        .compression = .none,
        .encryption = EncryptionInfo{
            .algorithm = .chacha20_poly1305,
            .kdf = .argon2id,
            .salt = [_]u8{0} ** 32,
            .nonce = [_]u8{0} ** 12,
            .opslimit = 0,
            .memlimit = 0,
        },
        .tar_size = 0,
        .checksum = [_]u8{0} ** 32,
    };
    header.version = 2;

    try header.write(file.writer());
    const data_start = try file.getPos();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try file.writer().writeAll(V2_MAGIC);
    hasher.update(V2_MAGIC);

    var b4: [4]u8 = undefined;
    var b8: [8]u8 = undefined;
    var tagbuf: [1]u8 = undefined;

    const total_files_plain_create = source_paths.len;
    for (source_paths, 0..) |path, i| {
        // Update progress every 100 files to reduce overhead
        if (progress_cb) |cb| {
            if (i % 100 == 0 or i == total_files_plain_create - 1) {
                cb("Saving files", i + 1, total_files_plain_create);
            }
        }
        // Detect symlink via readlink
        const c_path = allocator.allocSentinel(u8, path.len, 0) catch continue;
        defer allocator.free(c_path);
        std.mem.copyForwards(u8, c_path, path);
        var tbuf: [4096]u8 = undefined;
        const maybe_target: ?[]u8 = posix.readlinkZ(c_path.ptr, tbuf[0..]) catch null;
        if (maybe_target) |target| {
            // Tag: 2=symlink
            tagbuf[0] = 2;
            try file.writer().writeAll(&tagbuf);
            hasher.update(&tagbuf);

            std.mem.writeInt(u32, &b4, @as(u32, @intCast(path.len)), .little);
            try file.writer().writeAll(&b4);
            hasher.update(&b4);
            try file.writer().writeAll(path);
            hasher.update(path);

            std.mem.writeInt(u64, &b8, @as(u64, 0), .little);
            try file.writer().writeAll(&b8);
            hasher.update(&b8);
            std.mem.writeInt(i64, &b8, @as(i64, 0), .little);
            try file.writer().writeAll(&b8);
            hasher.update(&b8);

            std.mem.writeInt(u32, &b4, @as(u32, @intCast(target.len)), .little);
            try file.writer().writeAll(&b4);
            hasher.update(&b4);
            try file.writer().writeAll(target);
            hasher.update(target);
            continue;
        }

        const f = fs.cwd().openFile(path, .{}) catch continue;
        defer f.close();
        const st = f.stat() catch continue;
        if (st.kind != .file) {
            print("Skipping non-regular: {s}\n", .{path});
            continue;
        }

        tagbuf[0] = 1;
        try file.writer().writeAll(&tagbuf);
        hasher.update(&tagbuf);

        std.mem.writeInt(u32, &b4, @as(u32, @intCast(path.len)), .little);
        try file.writer().writeAll(&b4);
        hasher.update(&b4);
        try file.writer().writeAll(path);
        hasher.update(path);

        std.mem.writeInt(u64, &b8, @as(u64, @intCast(st.mode)), .little);
        try file.writer().writeAll(&b8);
        hasher.update(&b8);
        std.mem.writeInt(i64, &b8, @as(i64, @intCast(st.mtime)), .little);
        try file.writer().writeAll(&b8);
        hasher.update(&b8);
        std.mem.writeInt(FileSize, &b8, @as(FileSize, @intCast(st.size)), .little);
        try file.writer().writeAll(&b8);
        hasher.update(&b8);

        var buf: [1024 * 1024]u8 = undefined;
        var remaining: FileSize = st.size;
        while (remaining > 0) {
            const to_read: usize = @intCast(@min(remaining, buf.len));
            const n = try f.read(buf[0..to_read]);
            if (n == 0) break;
            try file.writer().writeAll(buf[0..n]);
            hasher.update(buf[0..n]);
            remaining -= n;
        }
    }

    // Finalize header
    const data_end = try file.getPos();
    const payload_len: u64 = @intCast(data_end - data_start);
    var checksum: [32]u8 = undefined;
    hasher.final(&checksum);
    header.tar_size = payload_len;
    header.checksum = checksum;

    // Rewrite header at start
    try file.seekTo(0);
    try header.write(file.writer());
}

fn extractKhrBackupStreaming(allocator: Allocator, file: fs.File, data_start: u64, payload_len: u64, extract_to: String, expected_checksum: [32]u8) !void {
    const V2_MAGIC = "KHRV2\n";
    try file.seekTo(data_start);

    var remaining = payload_len;
    if (remaining < V2_MAGIC.len) return KhrError.ArchiveFormatFailed;

    var hdrbuf: [6]u8 = undefined;
    _ = try file.readAll(&hdrbuf);
    if (!std.mem.eql(u8, &hdrbuf, V2_MAGIC)) return KhrError.ArchiveFormatFailed;
    remaining -= V2_MAGIC.len;

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(V2_MAGIC);

    var b4: [4]u8 = undefined;
    var b8: [8]u8 = undefined;
    var tagbuf: [1]u8 = undefined;
    var tmp: [64 * 1024]u8 = undefined;

    while (remaining > 0) {
        if (remaining < 1) break;
        _ = try file.readAll(&tagbuf);
        hasher.update(&tagbuf);
        remaining -= 1;
        const tag = tagbuf[0];

        _ = try file.readAll(&b4);
        hasher.update(&b4);
        remaining -= b4.len;
        const path_len = std.mem.readInt(u32, &b4, .little);

        if (remaining < path_len) return KhrError.ArchiveFormatFailed;
        const path_slice = try allocator.alloc(u8, path_len);
        defer allocator.free(path_slice);
        _ = try file.readAll(path_slice);
        hasher.update(path_slice);
        remaining -= path_len;

        _ = try file.readAll(&b8);
        hasher.update(&b8);
        remaining -= b8.len;
        const mode_val_u64 = std.mem.readInt(u64, &b8, .little);

        _ = try file.readAll(&b8);
        hasher.update(&b8);
        remaining -= b8.len;
        const _mtime = std.mem.readInt(i64, &b8, .little);
        _ = _mtime; // Read for format compliance but not used during extraction

        if (tag == 1) {
            _ = try file.readAll(&b8);
            hasher.update(&b8);
            remaining -= b8.len;
            var size = std.mem.readInt(FileSize, &b8, .little);

            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, path_slice });
            defer allocator.free(full_path);
            if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
            const out = try std.fs.cwd().createFile(full_path, .{});
            defer out.close();

            while (size > 0) {
                const chunk: usize = @intCast(@min(size, tmp.len));
                const n = try file.read(tmp[0..chunk]);
                if (n == 0) return KhrError.ArchiveFormatFailed;
                try out.writeAll(tmp[0..n]);
                hasher.update(tmp[0..n]);
                size -= n;
                remaining -= n;
            }
            if (builtin.os.tag == .linux) {
                const perm: u32 = @intCast(mode_val_u64 & 0o7777);
                posix.fchmod(out.handle, perm) catch {};
            }
        } else if (tag == 2) {
            // symlink: read target len and target (allow absolute or relative targets)
            _ = try file.readAll(&b4);
            hasher.update(&b4);
            remaining -= b4.len;
            const target_len = std.mem.readInt(u32, &b4, .little);
            if (remaining < target_len) return KhrError.ArchiveFormatFailed;
            const target = try allocator.alloc(u8, target_len);
            defer allocator.free(target);
            _ = try file.readAll(target);
            hasher.update(target);
            remaining -= target_len;

            // create symlink(remember this means symbolic link)
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, path_slice });
            defer allocator.free(full_path);
            if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
            const c_link = allocator.allocSentinel(u8, full_path.len, 0) catch continue;
            defer allocator.free(c_link);
            std.mem.copyForwards(u8, c_link, full_path);
            const c_target = allocator.allocSentinel(u8, target.len, 0) catch continue;
            defer allocator.free(c_target);
            std.mem.copyForwards(u8, c_target, target);
            posix.symlinkZ(c_target.ptr, c_link.ptr) catch {};
        } else {
            return KhrError.ArchiveFormatFailed;
        }
    }

    var checksum: [32]u8 = undefined;
    hasher.final(&checksum);
    if (!std.mem.eql(u8, &checksum, &expected_checksum)) return KhrError.ChecksumMismatch;
}

pub fn createKhrBackup(
    allocator: Allocator,
    source_paths: []const String,
    output_path: String,
    password: ?String,
    compression: CompressionType,
    progress_cb: ?SaveProgressCallback,
) !void {
    // Fast path: streaming archive with no compression/encryption (version 2)
    if (password == null and compression == .none) {
        try createKhrBackupStreaming(allocator, source_paths, output_path, progress_cb);
        return;
    }
    // Streaming gzip path (version 2, no encryption)
    if (password == null and compression == .gzip) {
        try KhrHeader.createKhrBackupStreamingGzip(allocator, source_paths, output_path, progress_cb);
        return;
    }
    print("Creating .khr backup: {s}\n", .{output_path});

    // Step 1: Create simple archive blob (length-prefixed file data)
    const tar_data = try createTarArchive(allocator, source_paths);
    defer allocator.free(tar_data);

    print("Created archive blob: {d} bytes\n", .{tar_data.len});

    // Step 2: Compress if requested
    var compressed_data: ?[]u8 = null;
    var final_data = tar_data;
    var final_size = tar_data.len;
    var effective_compression = compression;

    if (compression != .none) {
        compressed_data = try compressData(allocator, tar_data, compression);
        defer allocator.free(compressed_data.?);
        final_data = compressed_data.?;
        final_size = compressed_data.?.len;
        print("Compressed to: {d} bytes\n", .{final_size});
        // If unsupported algos fell back to gzip in compressData, reflect that in header
        if (compression == .lz4 or compression == .zstd) {
            effective_compression = .gzip;
        }
    }

    // Step 3: Encrypt if password provided
    var encryption_info: ?EncryptionInfo = null;
    if (password != null) {
        const enc_res = try encryptData(allocator, final_data, password.?);
        defer allocator.free(enc_res.data);
        encryption_info = enc_res.info;
        final_data = enc_res.data;
        final_size = enc_res.data.len;
        print("Encrypted to: {d} bytes\n", .{final_size});
    }

    // Step 4: Create header
    var checksum: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(final_data);
    hasher.final(&checksum);

    var header = KhrHeader{
        .compression = effective_compression,
        .tar_size = @intCast(final_size), // total payload size actually stored after comp/encrypt
        .checksum = checksum,
        .encryption = EncryptionInfo{
            .algorithm = .chacha20_poly1305,
            .kdf = .argon2id,
            .salt = [_]u8{0} ** 32,
            .nonce = [_]u8{0} ** 12,
            .opslimit = 0,
            .memlimit = 0,
        },
    };

    if (encryption_info) |info| {
        header.encryption = info;
    }

    // Step 5: Write file
    const file = try fs.cwd().createFile(output_path, .{});
    defer file.close();

    try header.write(file.writer());
    try file.writeAll(final_data);

    print("KHR backup created successfully: {s}\n", .{output_path});
}

pub fn extractKhrBackup(
    allocator: Allocator,
    khr_path: String,
    password: ?String,
    extract_to: String,
) !void {
    print("Extracting .khr backup: {s}\n", .{khr_path});

    const file = try fs.cwd().openFile(khr_path, .{});
    defer file.close();

    // Step 1: Read header
    const header = try KhrHeader.read(file.reader());
    print("KHR version: {d}, compression: {s}, tar size: {d}\n", .{ header.version, @tagName(header.compression), header.tar_size });

    // Streaming extract for v2 (no compression/encryption)
    const data_start_pos = try file.getPos();
    if (header.version == 2) {
        const is_encrypted = (header.encryption.opslimit != 0 or header.encryption.memlimit != 0);
        if (header.compression == .none and !is_encrypted) {
            try extractKhrBackupStreaming(allocator, file, data_start_pos, header.tar_size, extract_to, header.checksum);
            print("KHR backup extracted successfully to: {s}\n", .{extract_to});
            return;
        }
        if (header.compression == .gzip and !is_encrypted) {
            try KhrHeader.extractKhrBackupStreamingGzip(allocator, file, data_start_pos, header.tar_size, extract_to, header.checksum);
            print("KHR backup extracted successfully to: {s}\n", .{extract_to});
            return;
        }
    }

    // Step 2: Read encrypted/compressed data (v1 or non-streamable)
    const encrypted_data = try allocator.alloc(u8, header.tar_size);
    defer allocator.free(encrypted_data);
    _ = try file.readAll(encrypted_data);

    // Step 3: Verify checksum
    var checksum: [32]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(encrypted_data);
    hasher.final(&checksum);

    if (!std.mem.eql(u8, &checksum, &header.checksum)) {
        return KhrError.ChecksumMismatch;
    }

    // Step 4: Decrypt if needed
    var decrypted_data = encrypted_data;
    var needs_free = false;

    const is_encrypted = (header.encryption.opslimit != 0 or header.encryption.memlimit != 0);
    if (is_encrypted) {
        if (password == null) return KhrError.DecryptionFailed;
        decrypted_data = try decryptData(allocator, encrypted_data, &header.encryption, password.?);
        needs_free = true;
        defer if (needs_free) allocator.free(decrypted_data);
        print("Decrypted: {d} bytes\n", .{decrypted_data.len});
    }

    // Step 5: Decompress if needed
    var decompressed_data = decrypted_data;
    var needs_free_decomp = false;

    if (header.compression != .none) {
        decompressed_data = try decompressData(allocator, decrypted_data, header.compression);
        needs_free_decomp = true;
        defer if (needs_free_decomp) allocator.free(decompressed_data);
        print("Decompressed: {d} bytes\n", .{decompressed_data.len});
    }

    // Step 6: Extract archive
    try extractTarArchive(allocator, decompressed_data, extract_to);

    print("KHR backup extracted successfully to: {s}\n", .{extract_to});
}

pub const EntryMeta = struct {
    path: []u8,
    size: FileSize,
    mtime: Timestamp,
    is_symlink: bool,

    pub fn deinit(self: *EntryMeta, allocator: Allocator) void {
        allocator.free(self.path);
    }
};

pub fn indexKhrBackup(allocator: Allocator, khr_path: String) !std.ArrayList(EntryMeta) {
    const file = try fs.cwd().openFile(khr_path, .{});
    defer file.close();

    const header = try KhrHeader.read(file.reader());
    const data_start = try file.getPos();
    var entries = std.ArrayList(EntryMeta).init(allocator);
    errdefer {
        for (entries.items) |*e| e.deinit(allocator);
        entries.deinit();
    }

    if (header.version != 2) return KhrError.UnsupportedVersion;
    const is_encrypted = (header.encryption.opslimit != 0 or header.encryption.memlimit != 0);
    if (is_encrypted) return KhrError.EncryptionFailed;

    const V2_MAGIC = "KHRV2\n";

    if (header.compression == .none) {
        try file.seekTo(data_start);
        var remaining = header.tar_size;
        if (remaining < V2_MAGIC.len) return KhrError.ArchiveFormatFailed;

        var hdrbuf: [6]u8 = undefined;
        _ = try file.readAll(&hdrbuf);
        if (!std.mem.eql(u8, &hdrbuf, V2_MAGIC)) return KhrError.ArchiveFormatFailed;
        remaining -= V2_MAGIC.len;

        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(V2_MAGIC);

        var b4: [4]u8 = undefined;
        var b8: [8]u8 = undefined;
        var tagbuf: [1]u8 = undefined;
        var tmp: [64 * 1024]u8 = undefined;

        while (remaining > 0) {
            if (remaining < 1) break;
            _ = try file.readAll(&tagbuf);
            hasher.update(&tagbuf);
            remaining -= 1;
            const tag = tagbuf[0];

            _ = try file.readAll(&b4);
            hasher.update(&b4);
            remaining -= b4.len;
            const path_len = std.mem.readInt(u32, &b4, .little);

            if (remaining < path_len) return KhrError.ArchiveFormatFailed;
            const path_slice = try allocator.alloc(u8, path_len);
            errdefer allocator.free(path_slice);
            _ = try file.readAll(path_slice);
            hasher.update(path_slice);
            remaining -= path_len;

            _ = try file.readAll(&b8);
            hasher.update(&b8);
            remaining -= b8.len;

            _ = try file.readAll(&b8);
            hasher.update(&b8);
            remaining -= b8.len;
            const mtime = std.mem.readInt(i64, &b8, .little);

            if (tag == 1) {
                _ = try file.readAll(&b8);
                hasher.update(&b8);
                remaining -= b8.len;
                var size = std.mem.readInt(u64, &b8, .little);

                try entries.append(.{ .path = path_slice, .size = size, .mtime = mtime, .is_symlink = false });

                while (size > 0) {
                    const chunk: usize = @intCast(@min(size, tmp.len));
                    const n = try file.read(tmp[0..chunk]);
                    if (n == 0) return KhrError.ArchiveFormatFailed;
                    hasher.update(tmp[0..n]);
                    size -= n;
                    remaining -= n;
                }
            } else if (tag == 2) {
                _ = try file.readAll(&b4);
                hasher.update(&b4);
                remaining -= b4.len;
                const target_len = std.mem.readInt(u32, &b4, .little);
                if (remaining < target_len) return KhrError.ArchiveFormatFailed;
                const target = try allocator.alloc(u8, target_len);
                errdefer allocator.free(target);
                _ = try file.readAll(target);
                hasher.update(target);
                remaining -= target_len;
                allocator.free(target);

                try entries.append(.{ .path = path_slice, .size = 0, .mtime = mtime, .is_symlink = true });
            } else {
                allocator.free(path_slice);
                return KhrError.ArchiveFormatFailed;
            }
        }

        var checksum: [32]u8 = undefined;
        hasher.final(&checksum);
        if (!std.mem.eql(u8, &checksum, &header.checksum)) return KhrError.ChecksumMismatch;
        return entries;
    } else if (header.compression == .gzip) {
        try file.seekTo(data_start);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var limited = std.io.limitedReader(file.reader(), header.tar_size);
        var dec = std.compress.gzip.decompressor(limited.reader());
        var reader = dec.reader();

        const magic = "KHRV2\n";
        var hdrbuf: [6]u8 = undefined;
        const mread = reader.readAll(&hdrbuf) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return KhrError.ArchiveFormatFailed,
        };
        if (mread != magic.len or !std.mem.eql(u8, &hdrbuf, magic)) return KhrError.ArchiveFormatFailed;
        hasher.update(magic);

        var b4: [4]u8 = undefined;
        var b8: [8]u8 = undefined;
        var tagbuf: [1]u8 = undefined;
        var tmp: [64 * 1024]u8 = undefined;

        while (true) {
            const tr = reader.readAll(&tagbuf) catch |err| {
                if (err == error.EndOfStream) break;
                return KhrError.ArchiveFormatFailed;
            };
            if (tr == 0) break;
            if (tr != 1) return KhrError.ArchiveFormatFailed;
            hasher.update(&tagbuf);
            const tag = tagbuf[0];

            const pr = reader.readAll(&b4) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (pr != b4.len) return KhrError.ArchiveFormatFailed;
            hasher.update(&b4);
            const path_len = std.mem.readInt(u32, &b4, .little);

            const path_slice = try allocator.alloc(u8, path_len);
            errdefer allocator.free(path_slice);
            const got = reader.readAll(path_slice) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (got != path_len) return KhrError.ArchiveFormatFailed;
            hasher.update(path_slice);

            const mr = reader.readAll(&b8) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (mr != b8.len) return KhrError.ArchiveFormatFailed;
            hasher.update(&b8);

            const mt = reader.readAll(&b8) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (mt != b8.len) return KhrError.ArchiveFormatFailed;
            hasher.update(&b8);
            const mtime = std.mem.readInt(i64, &b8, .little);

            if (tag == 1) {
                const sr = reader.readAll(&b8) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (sr != b8.len) return KhrError.ArchiveFormatFailed;
                hasher.update(&b8);
                var size = std.mem.readInt(u64, &b8, .little);

                try entries.append(.{ .path = path_slice, .size = size, .mtime = mtime, .is_symlink = false });

                while (size > 0) {
                    const chunk: usize = @intCast(@min(size, tmp.len));
                    const n = reader.read(tmp[0..chunk]) catch |err| switch (err) {
                        error.EndOfStream => 0,
                        else => return KhrError.ArchiveFormatFailed,
                    };
                    if (n == 0) return KhrError.ArchiveFormatFailed;
                    hasher.update(tmp[0..n]);
                    size -= n;
                }
            } else if (tag == 2) {
                const lr = reader.readAll(&b4) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (lr != b4.len) return KhrError.ArchiveFormatFailed;
                hasher.update(&b4);
                const target_len = std.mem.readInt(u32, &b4, .little);
                const target = try allocator.alloc(u8, target_len);
                errdefer allocator.free(target);
                const got2 = reader.readAll(target) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (got2 != target_len) return KhrError.ArchiveFormatFailed;
                hasher.update(target);
                allocator.free(target);

                try entries.append(.{ .path = path_slice, .size = 0, .mtime = mtime, .is_symlink = true });
            } else {
                allocator.free(path_slice);
                return KhrError.ArchiveFormatFailed;
            }
        }

        var checksum: [32]u8 = undefined;
        hasher.final(&checksum);
        if (!std.mem.eql(u8, &checksum, &header.checksum)) return KhrError.ChecksumMismatch;
        return entries;
    } else {
        return KhrError.CompressionFailed;
    }
}

pub fn extractSelectedKhrBackup(allocator: Allocator, khr_path: String, password: ?String, extract_to: String, selected_paths: []const String) !void {
    _ = password; // streaming selection currently unsupported for encrypted payloads
    const file = try fs.cwd().openFile(khr_path, .{});
    defer file.close();

    const header = try KhrHeader.read(file.reader());
    const data_start = try file.getPos();
    if (header.version != 2) return KhrError.UnsupportedVersion;
    const is_encrypted = (header.encryption.opslimit != 0 or header.encryption.memlimit != 0);
    if (is_encrypted) return KhrError.EncryptionFailed;

    const V2_MAGIC = "KHRV2\n";
    const shouldExtract = struct {
        fn check(path: String, list: []const String) bool {
            for (list) |p| {
                if (std.mem.eql(u8, path, p)) return true;
            }
            return false;
        }
    }.check;

    if (header.compression == .none) {
        try file.seekTo(data_start);
        var remaining = header.tar_size;
        if (remaining < V2_MAGIC.len) return KhrError.ArchiveFormatFailed;
        var hdrbuf: [6]u8 = undefined;
        _ = try file.readAll(&hdrbuf);
        if (!std.mem.eql(u8, &hdrbuf, V2_MAGIC)) return KhrError.ArchiveFormatFailed;
        remaining -= V2_MAGIC.len;

        var b4: [4]u8 = undefined;
        var b8: [8]u8 = undefined;
        var tagbuf: [1]u8 = undefined;
        var tmp: [64 * 1024]u8 = undefined;

        while (remaining > 0) {
            if (remaining < 1) break;
            _ = try file.readAll(&tagbuf);
            remaining -= 1;
            const tag = tagbuf[0];

            _ = try file.readAll(&b4);
            remaining -= b4.len;
            const path_len = std.mem.readInt(u32, &b4, .little);
            if (remaining < path_len) return KhrError.ArchiveFormatFailed;
            const path_slice = try allocator.alloc(u8, path_len);
            defer allocator.free(path_slice);
            _ = try file.readAll(path_slice);
            remaining -= path_len;

            _ = try file.readAll(&b8);
            remaining -= b8.len;

            _ = try file.readAll(&b8);
            remaining -= b8.len;

            if (tag == 1) {
                _ = try file.readAll(&b8);
                remaining -= b8.len;
                var size = std.mem.readInt(u64, &b8, .little);

                const do_extract = shouldExtract(path_slice, selected_paths);
                var out: ?fs.File = null;
                if (do_extract) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, path_slice });
                    defer allocator.free(full_path);
                    if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                    out = try std.fs.cwd().createFile(full_path, .{});
                }

                while (size > 0) {
                    const chunk: usize = @intCast(@min(size, tmp.len));
                    const n = try file.read(tmp[0..chunk]);
                    if (n == 0) return KhrError.ArchiveFormatFailed;
                    if (do_extract) try out.?.writeAll(tmp[0..n]);
                    size -= n;
                    remaining -= n;
                }
                if (out) |f| f.close();
            } else if (tag == 2) {
                _ = try file.readAll(&b4);
                remaining -= b4.len;
                const target_len = std.mem.readInt(u32, &b4, .little);
                if (remaining < target_len) return KhrError.ArchiveFormatFailed;
                const target = try allocator.alloc(u8, target_len);
                defer allocator.free(target);
                _ = try file.readAll(target);
                remaining -= target_len;

                if (shouldExtract(path_slice, selected_paths)) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, path_slice });
                    defer allocator.free(full_path);
                    if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                    const c_link = try allocator.allocSentinel(u8, full_path.len, 0);
                    defer allocator.free(c_link);
                    std.mem.copyForwards(u8, c_link, full_path);
                    const c_target = try allocator.allocSentinel(u8, target.len, 0);
                    defer allocator.free(c_target);
                    std.mem.copyForwards(u8, c_target, target);
                    posix.symlinkZ(c_target.ptr, c_link.ptr) catch {};
                }
            } else {
                return KhrError.ArchiveFormatFailed;
            }
        }
        return;
    } else if (header.compression == .gzip) {
        try file.seekTo(data_start);
        var limited = std.io.limitedReader(file.reader(), header.tar_size);
        var dec = std.compress.gzip.decompressor(limited.reader());
        var reader = dec.reader();

        const magic = "KHRV2\n";
        var hdrbuf: [6]u8 = undefined;
        const mread = reader.readAll(&hdrbuf) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => return KhrError.ArchiveFormatFailed,
        };
        if (mread != magic.len or !std.mem.eql(u8, &hdrbuf, magic)) return KhrError.ArchiveFormatFailed;

        var b4: [4]u8 = undefined;
        var b8: [8]u8 = undefined;
        var tagbuf: [1]u8 = undefined;
        var tmp: [64 * 1024]u8 = undefined;

        while (true) {
            const tr = reader.readAll(&tagbuf) catch |err| {
                if (err == error.EndOfStream) break;
                return KhrError.ArchiveFormatFailed;
            };
            if (tr == 0) break;
            if (tr != 1) return KhrError.ArchiveFormatFailed;
            const tag = tagbuf[0];

            const pr = reader.readAll(&b4) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (pr != b4.len) return KhrError.ArchiveFormatFailed;
            const path_len = std.mem.readInt(u32, &b4, .little);

            const path_slice = try allocator.alloc(u8, path_len);
            defer allocator.free(path_slice);
            const got = reader.readAll(path_slice) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (got != path_len) return KhrError.ArchiveFormatFailed;

            const mr = reader.readAll(&b8) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (mr != b8.len) return KhrError.ArchiveFormatFailed;

            const mt = reader.readAll(&b8) catch |err| switch (err) {
                error.EndOfStream => 0,
                else => return KhrError.ArchiveFormatFailed,
            };
            if (mt != b8.len) return KhrError.ArchiveFormatFailed;

            if (tag == 1) {
                const sr = reader.readAll(&b8) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (sr != b8.len) return KhrError.ArchiveFormatFailed;
                var size = std.mem.readInt(u64, &b8, .little);

                const do_extract = shouldExtract(path_slice, selected_paths);
                var out: ?fs.File = null;
                if (do_extract) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, path_slice });
                    defer allocator.free(full_path);
                    if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                    out = try std.fs.cwd().createFile(full_path, .{});
                }

                while (size > 0) {
                    const chunk: usize = @intCast(@min(size, tmp.len));
                    const n = reader.read(tmp[0..chunk]) catch |err| switch (err) {
                        error.EndOfStream => 0,
                        else => return KhrError.ArchiveFormatFailed,
                    };
                    if (n == 0) return KhrError.ArchiveFormatFailed;
                    if (do_extract) try out.?.writeAll(tmp[0..n]);
                    size -= n;
                }
                if (out) |f| f.close();
            } else if (tag == 2) {
                const lr = reader.readAll(&b4) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (lr != b4.len) return KhrError.ArchiveFormatFailed;
                const target_len = std.mem.readInt(u32, &b4, .little);
                const target = try allocator.alloc(u8, target_len);
                defer allocator.free(target);
                const got2 = reader.readAll(target) catch |err| switch (err) {
                    error.EndOfStream => 0,
                    else => return KhrError.ArchiveFormatFailed,
                };
                if (got2 != target_len) return KhrError.ArchiveFormatFailed;

                if (shouldExtract(path_slice, selected_paths)) {
                    const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, path_slice });
                    defer allocator.free(full_path);
                    if (std.fs.path.dirname(full_path)) |d| std.fs.cwd().makePath(d) catch {};
                    const c_link = try allocator.allocSentinel(u8, full_path.len, 0);
                    defer allocator.free(c_link);
                    std.mem.copyForwards(u8, c_link, full_path);
                    const c_target = try allocator.allocSentinel(u8, target.len, 0);
                    defer allocator.free(c_target);
                    std.mem.copyForwards(u8, c_target, target);
                    posix.symlinkZ(c_target.ptr, c_link.ptr) catch {};
                }
            } else {
                return KhrError.ArchiveFormatFailed;
            }
        }
        return;
    } else {
        return KhrError.CompressionFailed;
    }
}

fn createTarArchive(allocator: Allocator, source_paths: []const String) ![]u8 {
    // Create a simple length-prefixed archive format:
    // Header: "KROWNO_BACKUP_V1\n"
    // For each file:
    //   "FILE: {path}\n"
    //   "LEN: {size}\n"
    //   "MTIME: {mtime}\n"
    //   raw {size} bytes of file content
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();

    try out.appendSlice("KROWNO_BACKUP_V1\n");

    for (source_paths) |path| {
        const file = fs.cwd().openFile(path, .{}) catch continue;
        defer file.close();

        const stat = file.stat() catch continue;
        const contents = file.readToEndAlloc(allocator, std.math.maxInt(usize)) catch continue;
        defer allocator.free(contents);

        const file_line = try std.fmt.allocPrint(allocator, "FILE: {s}\n", .{path});
        defer allocator.free(file_line);
        try out.appendSlice(file_line);

        const len_line = try std.fmt.allocPrint(allocator, "LEN: {d}\n", .{contents.len});
        defer allocator.free(len_line);
        try out.appendSlice(len_line);

        const mtime_line = try std.fmt.allocPrint(allocator, "MTIME: {d}\n", .{stat.mtime});
        defer allocator.free(mtime_line);
        try out.appendSlice(mtime_line);

        // Raw bytes
        try out.appendSlice(contents);
    }

    return out.toOwnedSlice();
}

fn extractTarArchive(allocator: Allocator, data: String, extract_to: String) !void {
    // Sanitize and ensure extracted paths remain inside extract_to
    const sanitize = struct {
        fn sanitizeRelativePath(alloc: Allocator, p: String) ![]u8 {
            // Strip leading '/'
            var start: usize = 0;
            while (start < p.len and p[start] == '/') start += 1;
            var out = std.ArrayList(u8).init(alloc);
            errdefer out.deinit();
            var it = std.mem.splitScalar(u8, p[start..], '/');
            var first = true;
            while (it.next()) |seg| {
                if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) {
                    return KhrError.ArchiveFormatFailed;
                }
                if (!first) try out.append('/');
                first = false;
                try out.appendSlice(seg);
            }
            if (out.items.len == 0) return KhrError.ArchiveFormatFailed;
            return out.toOwnedSlice();
        }
    };
    var i: usize = 0;
    // Expect header
    const magic = "KROWNO_BACKUP_V1\n";
    if (data.len < magic.len or !std.mem.eql(u8, data[0..magic.len], magic)) {
        return KhrError.ArchiveFormatFailed;
    }
    i = magic.len;

    while (i < data.len) {
        // Read a line ending with '\n'
        const file_tag = "FILE: ";
        if (i + file_tag.len > data.len) break;
        if (!std.mem.eql(u8, data[i .. i + file_tag.len], file_tag)) break;
        i += file_tag.len;

        const path_start = i;
        const nl1 = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse break;
        const path = data[path_start..nl1];
        const safe_rel = sanitize.sanitizeRelativePath(allocator, path) catch return KhrError.ArchiveFormatFailed;
        defer allocator.free(safe_rel);
        i = nl1 + 1;

        const len_tag = "LEN: ";
        if (i + len_tag.len > data.len or !std.mem.eql(u8, data[i .. i + len_tag.len], len_tag)) return KhrError.ArchiveFormatFailed;
        i += len_tag.len;
        const len_start = i;
        const nl2 = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse return KhrError.ArchiveFormatFailed;
        const len_str = data[len_start..nl2];
        const file_len = std.fmt.parseInt(usize, len_str, 10) catch return KhrError.ArchiveFormatFailed;
        i = nl2 + 1;

        const mtime_tag = "MTIME: ";
        if (i + mtime_tag.len > data.len or !std.mem.eql(u8, data[i .. i + mtime_tag.len], mtime_tag)) return KhrError.ArchiveFormatFailed;
        i += mtime_tag.len;
        const mt_start = i;
        const nl3 = std.mem.indexOfScalarPos(u8, data, i, '\n') orelse return KhrError.ArchiveFormatFailed;
        _ = std.fmt.parseInt(i64, data[mt_start..nl3], 10) catch 0; // unused
        i = nl3 + 1;

        if (i + file_len > data.len) return KhrError.ArchiveFormatFailed;
        const content = data[i .. i + file_len];
        i += file_len;

        // Write file
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ extract_to, safe_rel });
        defer allocator.free(full_path);
        const dir = std.fs.path.dirname(full_path);
        if (dir) |d| std.fs.cwd().makePath(d) catch {};
        try std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = content });
    }
}

fn compressData(allocator: Allocator, data: String, compression: CompressionType) ![]u8 {
    switch (compression) {
        .none => return try allocator.dupe(u8, data),
        .gzip => {
            var engine = compress.Compressor.init(allocator);
            defer engine.deinit();
            var result = try engine.compress(data);
            defer result.deinit(allocator);
            return try allocator.dupe(u8, result.compressed_data);
        },
        .lz4, .zstd => {
            // LZ4 and ZSTD would be nice to have, but they're not implemented yet.
            // For now, we just fall back to good old gzip. It works fine.
            var engine = compress.Compressor.init(allocator);
            defer engine.deinit();
            var result = try engine.compress(data);
            defer result.deinit(allocator);
            return try allocator.dupe(u8, result.compressed_data);
        },
    }
}

fn decompressData(allocator: Allocator, data: String, compression: CompressionType) ![]u8 {
    switch (compression) {
        .none => return try allocator.dupe(u8, data),
        .gzip => {
            var engine = compress.Compressor.init(allocator);
            defer engine.deinit();
            return engine.decompress(data);
        },
        .lz4, .zstd => {
            // Same deal here - LZ4 and ZSTD aren't ready yet.
            // Gzip to the rescue again.
            var engine = compress.Compressor.init(allocator);
            defer engine.deinit();
            return engine.decompress(data);
        },
    }
}

fn encryptData(allocator: Allocator, data: String, password: String) !struct { data: []u8, info: EncryptionInfo } {
    var ctx = security.CryptoContext.init(allocator);
    defer ctx.deinit();

    var enc = try ctx.encrypt(data, password);
    defer enc.deinit(allocator);

    const info = EncryptionInfo{
        .algorithm = .chacha20_poly1305,
        .kdf = .argon2id,
        .salt = enc.salt,
        .nonce = enc.nonce,
        .opslimit = 3,
        .memlimit = 67108864,
    };

    const serialized = try ctx.serializeEncrypted(enc);
    return .{ .data = serialized, .info = info };
}

fn decryptData(allocator: Allocator, data: String, encryption_info: *const EncryptionInfo, password: String) ![]u8 {
    _ = encryption_info;
    var ctx = security.CryptoContext.init(allocator);
    defer ctx.deinit();

    var parsed = try ctx.deserializeEncrypted(data);
    defer parsed.deinit(allocator);
    return try ctx.decrypt(parsed, password);
}

fn deriveEncryptionInfo(allocator: Allocator, password: String) !EncryptionInfo {
    _ = allocator;
    _ = password;

    var salt: [32]u8 = undefined;
    var nonce: [12]u8 = undefined;
    std.crypto.random.bytes(&salt);
    std.crypto.random.bytes(&nonce);

    return EncryptionInfo{
        .salt = salt,
        .nonce = nonce,
        .opslimit = 3,
        .memlimit = 67108864,
    };
}

pub fn isKhrFile(path: String) bool {
    const file = fs.cwd().openFile(path, .{}) catch return false;
    defer file.close();

    var magic: [8]u8 = undefined;
    _ = file.readAll(&magic) catch return false;

    return std.mem.eql(u8, &magic, "KHRONO01");
}

pub fn getKhrInfo(allocator: Allocator, khr_path: String) !struct {
    version: u32,
    compression: CompressionType,
    encrypted: bool,
    tar_size: u64,
    file_size: u64,
} {
    _ = allocator;
    const file = try fs.cwd().openFile(khr_path, .{});
    defer file.close();

    const header = try KhrHeader.read(file.reader());
    const file_size = try file.getEndPos();

    return .{
        .version = header.version,
        .compression = header.compression,
        // Consider it encrypted if kdf/opslimit indicate PBKDF usage (set by deriveEncryptionInfo)
        .encrypted = (header.encryption.opslimit != 0 or header.encryption.memlimit != 0),
        .tar_size = header.tar_size,
        .file_size = file_size,
    };
}
