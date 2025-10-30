//! Streaming encryption  processes data in chunks so you can encrypt huge backups without OOM
const std = @import("std");
const crypto = @import("crypto.zig");
const types = @import("../utils/types.zig");
const String = types.String;
const Allocator = std.mem.Allocator;

pub const StreamEncryptor = struct {
    allocator: Allocator,
    key: [32]u8,
    buffer: []u8,
    chunk_size: usize,

    const Self = @This();
    const CHUNK_SIZE: usize = 1024 * 1024; // 1MB chunks - sweet spot for performance
    // tried 4MB first but it was slower on my laptop
    // 256KB was too small, lots of overhead

    pub fn init(allocator: Allocator, password: String, salt: [32]u8) !Self {
        const key = try crypto.deriveKey(allocator, password, salt);
        const buffer = try allocator.alloc(u8, CHUNK_SIZE + 16); // +16 for auth tag
        // forgot this at first and had buffer overflows

        return Self{
            .allocator = allocator,
            .key = key,
            .buffer = buffer,
            .chunk_size = CHUNK_SIZE,
        };
    }

    pub fn deinit(self: *Self) void {
        @memset(&self.key, 0);
        self.allocator.free(self.buffer);
    }

    pub fn encryptStream(
        self: *Self,
        reader: anytype,
        writer: anytype,
        total_size: types.FileSize,
    ) !void {
        var remaining = total_size;
        var chunk_index: u64 = 0;

        //this was a pain to debug - had to learn about anytype. turns out its like templates in C++ but way less verbose
        //still not sure if im doing this right but it works
        while (remaining > 0) {
            const to_read = @min(remaining, self.chunk_size);
            const chunk_data = self.buffer[0..to_read];

            const bytes_read = try reader.readAll(chunk_data);
            if (bytes_read == 0) break; // EOF earlier than expected, weird but ok

            var nonce: [12]u8 = undefined;
            std.mem.writeInt(u64, nonce[0..8], chunk_index, .little);
            std.mem.writeInt(u32, nonce[8..12], 0, .little);

            const encrypted = try crypto.encryptData(
                self.allocator,
                chunk_data[0..bytes_read],
                self.key,
                nonce,
            );
            defer self.allocator.free(encrypted);

            try writer.writeInt(u64, encrypted.len, .little);
            try writer.writeAll(encrypted);

            remaining -= bytes_read;
            chunk_index += 1;
        }
    }

    pub fn decryptStream(
        self: *Self,
        reader: anytype,
        writer: anytype,
    ) !void {
        var chunk_index: u64 = 0;

        while (true) {
            const chunk_size = reader.readInt(u64, .little) catch |err| {
                if (err == error.EndOfStream) break;
                return err;
            };

            if (chunk_size == 0) break;
            if (chunk_size > self.buffer.len) return error.ChunkTooLarge;

            const encrypted_chunk = self.buffer[0..chunk_size];
            const bytes_read = try reader.readAll(encrypted_chunk);
            if (bytes_read != chunk_size) return error.IncompleteChunk;

            var nonce: [12]u8 = undefined;
            std.mem.writeInt(u64, nonce[0..8], chunk_index, .little);
            std.mem.writeInt(u32, nonce[8..12], 0, .little);

            const decrypted = try crypto.decryptData(
                self.allocator,
                encrypted_chunk,
                self.key,
                nonce,
            );
            defer self.allocator.free(decrypted);

            try writer.writeAll(decrypted);

            chunk_index += 1;
        }
    }
};

pub fn encryptFile(
    allocator: Allocator,
    input_path: String,
    output_path: String,
    password: String,
) !void {
    const salt = try crypto.generateSalt();

    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    const file_size = (try input_file.stat()).size;

    try output_file.writeAll(&salt);

    var encryptor = try StreamEncryptor.init(allocator, password, salt);
    defer encryptor.deinit();

    try encryptor.encryptStream(
        input_file.reader(),
        output_file.writer(),
        file_size,
    );
}

pub fn decryptFile(
    allocator: Allocator,
    input_path: String,
    output_path: String,
    password: String,
) !void {
    const input_file = try std.fs.cwd().openFile(input_path, .{});
    defer input_file.close();

    const output_file = try std.fs.cwd().createFile(output_path, .{});
    defer output_file.close();

    var salt: [32]u8 = undefined;
    _ = try input_file.readAll(&salt);

    var decryptor = try StreamEncryptor.init(allocator, password, salt);
    defer decryptor.deinit();

    try decryptor.decryptStream(
        input_file.reader(),
        output_file.writer(),
    );
}
