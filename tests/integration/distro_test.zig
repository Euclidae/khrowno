const std = @import("std");
const testing = std.testing;
const distro = @import("../../src/system/distro.zig");

test "detect current distribution" {
    const allocator = testing.allocator;
    
    var distro_info = try distro.detectDistro(allocator);
    defer distro_info.deinit(allocator);
    
    try testing.expect(distro_info.name.len > 0);
    try testing.expect(distro_info.version.len > 0);
    try testing.expect(distro_info.package_manager.len > 0);
}

test "distribution type detection" {
    const allocator = testing.allocator;
    
    var distro_info = try distro.detectDistro(allocator);
    defer distro_info.deinit(allocator);
    
    try testing.expect(distro_info.distro_type != .unknown);
}

test "kernel version detection" {
    const allocator = testing.allocator;
    
    var distro_info = try distro.detectDistro(allocator);
    defer distro_info.deinit(allocator);
    
    try testing.expect(distro_info.kernel_version.len > 0);
    try testing.expect(std.mem.indexOf(u8, distro_info.kernel_version, ".") != null);
}
