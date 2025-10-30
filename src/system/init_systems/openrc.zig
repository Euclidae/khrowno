const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../../utils/types.zig");
const String = types.String;
const ansi = @import("../../utils/ansi.zig");

pub const OpenRCService = struct {
    name: String,
    runlevel: String,
    enabled: bool,

    allocator: Allocator,

    pub fn init(allocator: Allocator, name: String, runlevel: String) !OpenRCService {
        return OpenRCService{
            .name = try allocator.dupe(u8, name),
            .runlevel = try allocator.dupe(u8, runlevel),
            .enabled = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *OpenRCService) void {
        self.allocator.free(self.name);
        self.allocator.free(self.runlevel);
    }
};

pub const OpenRCHandler = struct {
    allocator: Allocator,
    services: ArrayList(OpenRCService), // This OpenRC handler queries rc-update instead of scraping files. Shelling should keeps
    //behavior consistent with OpenRC's own resolver

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .services = ArrayList(OpenRCService).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.services.items) |*service| {
            service.deinit();
        }
        self.services.deinit();
    }

    pub fn detectServices(self: *Self) !void {
        const runlevels = [_]String{ "boot", "default", "shutdown" };

        // Output format is "name | runlevel"; brittle but better than guessing
        for (runlevels) |runlevel| {
            const cmd = try std.fmt.allocPrint(self.allocator, "rc-update show {s}", .{runlevel});
            defer self.allocator.free(cmd);

            var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            try child.spawn();
            const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(stdout);

            _ = try child.wait();

            var lines = std.mem.splitScalar(u8, stdout, '\n');
            while (lines.next()) |line| {
                const trimmed = types.trim(line);
                if (trimmed.len == 0) continue;

                var parts = std.mem.splitScalar(u8, trimmed, '|');
                if (parts.next()) |service_name| {
                    var service = try OpenRCService.init(self.allocator, types.trim(service_name), runlevel);
                    service.enabled = true;
                    try self.services.append(service);
                }
            }
        }
    }


    pub fn backupService(self: *Self, service_name: String) !?String {
        const init_path = try std.fmt.allocPrint(self.allocator, "/etc/init.d/{s}", .{service_name});// Snapshot the init script verbatim; reconstructing from metadata is risky.
        defer self.allocator.free(init_path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, init_path, 1024 * 1024) catch |err| {
            std.debug.print("{s}Error: Failed to read {s}: {any}{s}\n", .{ ansi.Color.BOLD_RED, init_path, err, ansi.Color.RESET });
            return null;
        };

        return content;
    }

    pub fn restoreService(self: *Self, service_name: String, runlevel: String, content: String) !void {
        const init_path = try std.fmt.allocPrint(self.allocator, "/etc/init.d/{s}", .{service_name});
        defer self.allocator.free(init_path);

        const file = try std.fs.cwd().createFile(init_path, .{ .mode = 0o755 });
        defer file.close();

        try file.writeAll(content);
        // Write the script and register it for a runlevel using rc-update add
        const cmd = try std.fmt.allocPrint(self.allocator, "rc-update add {s} {s}", .{ service_name, runlevel });
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        try child.spawn();
        _ = try child.wait();
    }

    // Export format: NAME|RUNLEVEL|enabled
    pub fn exportServices(self: *Self) !ArrayList(u8) {
        var output = ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        try writer.writeAll("OPENRC_SERVICES\n");
        for (self.services.items) |service| {
            try writer.print("{s}|{s}|{s}\n", .{
                service.name,
                service.runlevel,
                if (service.enabled) "enabled" else "disabled",
            });
        }

        return output;
    }
};
