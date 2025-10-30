const std = @import("std");
const testing = std.testing;
const backup = @import("../../src/core/backup.zig");
const khr_format = @import("../../src/core/khr_format.zig");

test "create minimal backup" {
    const allocator = testing.allocator;
    
    const test_output = "/tmp/khrowno_test_backup.khr";
    defer std.fs.cwd().deleteFile(test_output) catch {};
    
    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();
    
    try engine.createBackup(.minimal, test_output, null, null, khr_format.CompressionType.gzip);
    
    const stat = try std.fs.cwd().statFile(test_output);
    try testing.expect(stat.size > 0);
}

test "backup info retrieval" {
    const allocator = testing.allocator;
    
    const test_output = "/tmp/khrowno_test_info.khr";
    defer std.fs.cwd().deleteFile(test_output) catch {};
    
    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();
    
    try engine.createBackup(.minimal, test_output, null, null, khr_format.CompressionType.gzip);
    
    var info = try backup.getBackupInfo(allocator, test_output);
    defer info.deinit(allocator);
    
    try testing.expect(info.version.len > 0);
}

test "backup validation" {
    const allocator = testing.allocator;
    
    const test_output = "/tmp/khrowno_test_validate.khr";
    defer std.fs.cwd().deleteFile(test_output) catch {};
    
    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();
    
    try engine.createBackup(.minimal, test_output, null, null, khr_format.CompressionType.gzip);
    
    const valid = try backup.validateBackup(allocator, test_output, null);
    try testing.expect(valid);
}
