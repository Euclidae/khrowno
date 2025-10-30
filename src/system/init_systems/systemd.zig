const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../../utils/types.zig");
const String = types.String;

pub const SystemdService = struct {
    name: String,
    enabled: bool,
    active: bool,
    unit_file_path: ?String,

    allocator: Allocator,

    pub fn init(allocator: Allocator, name: String) !SystemdService {
        return SystemdService{
            .name = try allocator.dupe(u8, name),
            .enabled = false,
            .active = false,
            .unit_file_path = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SystemdService) void {
        self.allocator.free(self.name);
        if (self.unit_file_path) |path| {
            self.allocator.free(path);
        }
    }
};

// Systemd handler: trust systemctl output instead of scraping unit files
// Shelling out keeps semantics aligned with whatever version of systemd is installed.
pub const SystemdHandler = struct {
    allocator: Allocator,
    services: ArrayList(SystemdService),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .services = ArrayList(SystemdService).init(allocator),
        };
    }

    
    pub fn deinit(self: *Self) void {
        for (self.services.items) |*service| {
            service.deinit();
        }
        self.services.deinit();
    }
    
    pub fn detectServices(self: *Self) !void {
        // list enabled services only; no pager/no legend makes parsing predictable
        const cmd = "systemctl list-unit-files --type=service --state=enabled --no-pager --no-legend";
        
        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(stdout);
        
        _ = try child.wait();
        
        var lines = std.mem.splitScalar(u8, stdout, '\n');
        while (lines.next()) |line| {
            const trimmed = types.trim(line);
            if (trimmed.len == 0) continue;
            
            var parts = std.mem.splitScalar(u8, trimmed, ' ');
            if (parts.next()) |service_name| {
                var service = try SystemdService.init(self.allocator, service_name);
                service.enabled = true;
                try self.services.append(service);
            }
        }
    }
    
    pub fn backupService(self: *Self, service_name: String) !?String {
        // systemctl cat returns the effective unit including drop-ins. That's what we want to restore.
        const cmd = try std.fmt.allocPrint(self.allocator, "systemctl cat {s}", .{service_name});
        defer self.allocator.free(cmd);
        
        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        
        const term = try child.wait();
        // Termination is a tagged union; match and capture exit code.
        const ok = switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
        if (ok and stdout.len > 0) {
            return stdout;
        }

        self.allocator.free(stdout);
        return null;
    }
    
    pub fn restoreService(self: *Self, service_name: String, content: String) !void {
        // write unit file then daemon-reload so systemd picks up changes
        const unit_path = try std.fmt.allocPrint(self.allocator, "/etc/systemd/system/{s}", .{service_name});
        defer self.allocator.free(unit_path);
        
        const file = try std.fs.cwd().createFile(unit_path, .{});
        defer file.close();
        
        try file.writeAll(content);
        
        const reload_cmd = "systemctl daemon-reload";
        var reload_child = std.process.Child.init(&[_]String{ "sh", "-c", reload_cmd }, self.allocator);
        try reload_child.spawn();
        _ = try reload_child.wait();
    }
    
    pub fn enableService(self: *Self, service_name: String) !void {
        const cmd = try std.fmt.allocPrint(self.allocator, "systemctl enable {s}", .{service_name});
        defer self.allocator.free(cmd);
        
        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        try child.spawn();
        _ = try child.wait();
    }
    
    pub fn exportServices(self: *Self) !ArrayList(u8) {
        // Export format: NAME|enabled|active
        var output = ArrayList(u8).init(self.allocator);
        const writer = output.writer();
        
        try writer.writeAll("SYSTEMD_SERVICES\n");
        for (self.services.items) |service| {
            try writer.print("{s}|{s}|{s}\n", .{
                service.name,
                if (service.enabled) "enabled" else "disabled",
                if (service.active) "active" else "inactive",
            });
        }
        
        return output;
    }
};
