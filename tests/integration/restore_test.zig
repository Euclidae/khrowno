const std = @import("std");
const testing = std.testing;
const khr_format = @import("../../src/core/khr_format.zig");
const backup = @import("../../src/core/backup.zig");

// Integration test: create a tiny KHR backup from a specific file and restore to a target dir
test "restore backup to destination directory" {
    const allocator = testing.allocator;

    // Prepare a small source file
    const src_dir = "khrowno_tmp_src";
    const nested_dir = try std.fmt.allocPrint(allocator, "{s}/sub", .{src_dir});
    defer allocator.free(nested_dir);
    std.fs.cwd().makePath(nested_dir) catch {};

    const src_file = try std.fmt.allocPrint(allocator, "{s}/sub/test.txt", .{src_dir});
    defer allocator.free(src_file);

    try std.fs.cwd().writeFile(.{ .sub_path = src_file, .data = "hello-restore" });

    // Create backup from this file
    const khr_path = "/tmp/khrowno_restore_test.khr";
    defer std.fs.cwd().deleteFile(khr_path) catch {};

    var paths = std.ArrayList([]const u8).init(allocator);
    defer paths.deinit();
    try paths.append(src_file);

    try khr_format.createKhrBackup(allocator, paths.items, khr_path, null, khr_format.CompressionType.gzip, null);

    // Restore to destination directory
    const dest_dir = "/tmp/khrowno_restore_out";
    std.fs.cwd().deleteTree(dest_dir) catch {};

    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();

    try engine.restoreBackupTo(khr_path, null, null, dest_dir, null);

    // Verify restored file exists with expected content
    const restored_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dest_dir, src_file });
    defer allocator.free(restored_path);

    const file = try std.fs.cwd().openFile(restored_path, .{});
    defer file.close();

    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    try testing.expect(n > 0);
    try testing.expect(std.mem.startsWith(u8, buf[0..n], "hello-restore"));
}
