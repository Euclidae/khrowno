const std = @import("std");
const testing = std.testing;
const config_manager = @import("../../src/core/config_manager.zig");

test "config manager initialization" {
    const allocator = testing.allocator;
    
    const test_config = "/tmp/khrowno_test_config.ini";
    defer std.fs.cwd().deleteFile(test_config) catch {};
    
    var manager = try config_manager.ConfigManager.init(allocator, test_config);
    defer manager.deinit();
    
    try manager.set("general", "backup_dir", config_manager.ConfigValue{ .string = "/tmp/backups" });
    try manager.set("general", "compression", config_manager.ConfigValue{ .string = "gzip" });
    try manager.set("schedule", "enabled", config_manager.ConfigValue{ .boolean = true });
    
    try manager.save();
    
    const stat = try std.fs.cwd().statFile(test_config);
    try testing.expect(stat.size > 0);
}

test "config value retrieval" {
    const allocator = testing.allocator;
    
    const test_config = "/tmp/khrowno_test_config2.ini";
    defer std.fs.cwd().deleteFile(test_config) catch {};
    
    var manager = try config_manager.ConfigManager.init(allocator, test_config);
    defer manager.deinit();
    
    try manager.set("test", "string_val", config_manager.ConfigValue{ .string = "hello" });
    try manager.set("test", "int_val", config_manager.ConfigValue{ .integer = 42 });
    try manager.set("test", "bool_val", config_manager.ConfigValue{ .boolean = true });
    
    if (manager.get("test", "string_val")) |val| {
        try testing.expectEqualStrings("hello", val.asString().?);
    }
    
    if (manager.get("test", "int_val")) |val| {
        try testing.expectEqual(@as(i64, 42), val.asInt().?);
    }
    
    if (manager.get("test", "bool_val")) |val| {
        try testing.expect(val.asBool().?);
    }
}

test "config persistence" {
    const allocator = testing.allocator;
    
    const test_config = "/tmp/khrowno_test_config3.ini";
    defer std.fs.cwd().deleteFile(test_config) catch {};
    
    {
        var manager = try config_manager.ConfigManager.init(allocator, test_config);
        defer manager.deinit();
        
        try manager.set("data", "value", config_manager.ConfigValue{ .string = "persistent" });
        try manager.save();
    }
    
    {
        var manager = try config_manager.ConfigManager.init(allocator, test_config);
        defer manager.deinit();
        
        try manager.load();
        
        if (manager.get("data", "value")) |val| {
            try testing.expectEqualStrings("persistent", val.asString().?);
        } else {
            try testing.expect(false);
        }
    }
}
