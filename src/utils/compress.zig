// Compression utilities - gzip for now because it's everywhere and just works
// zstd is faster but less compatible, sticking with gzip for universality

const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const String = types.String;

pub const CompressionError = error{
    CompressionFailed,
    DecompressionFailed,
    InvalidFormat,
};

pub const CompressionResult = struct {
    compressed_data: []u8,
    original_size: usize,
    compressed_size: usize,
    compression_ratio: f64,

    pub fn deinit(self: *CompressionResult, allocator: Allocator) void {
        allocator.free(self.compressed_data);
    }
};

pub const Compressor = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn compress(self: *Self, data: String) !CompressionResult {
        var compressed = std.ArrayList(u8).init(self.allocator);
        defer compressed.deinit();

        var compressor = try std.compress.gzip.compressor(compressed.writer(), .{});
        try compressor.writer().writeAll(data);
        try compressor.finish();

        const compressed_data = try compressed.toOwnedSlice();
        const ratio = if (data.len > 0)
            @as(f64, @floatFromInt(compressed_data.len)) / @as(f64, @floatFromInt(data.len))
        else
            0.0;

        return CompressionResult{
            .compressed_data = compressed_data,
            .original_size = data.len,
            .compressed_size = compressed_data.len,
            .compression_ratio = ratio,
        };
    }

    pub fn decompress(self: *Self, compressed_data: String) ![]u8 {
        var stream = std.io.fixedBufferStream(compressed_data);
        var decompressor = std.compress.gzip.decompressor(stream.reader());

        var decompressed = std.ArrayList(u8).init(self.allocator);
        defer decompressed.deinit();

        var buffer: [4096]u8 = undefined;
        while (true) {
            const bytes_read = decompressor.reader().read(&buffer) catch |err| {
                if (err == error.EndOfStream) break;
                return CompressionError.DecompressionFailed;
            };

            if (bytes_read == 0) break;
            try decompressed.appendSlice(buffer[0..bytes_read]);
        }

        return try decompressed.toOwnedSlice();
    }
};

pub fn compressGzip(allocator: Allocator, data: String) ![]u8 {
    var compressor = Compressor.init(allocator);
    defer compressor.deinit();

    const result = try compressor.compress(data);
    const compressed = result.compressed_data;

    return compressed;
}

pub fn decompressGzip(allocator: Allocator, compressed: String) ![]u8 {
    var compressor = Compressor.init(allocator);
    defer compressor.deinit();

    return try compressor.decompress(compressed);
}
