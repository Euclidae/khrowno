const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../../utils/types.zig");
const String = types.String;
const ansi = @import("../../utils/ansi.zig");

pub const RunitService = struct {
    name: String,
    service_dir: String,
    enabled: bool,

    allocator: Allocator,

    pub fn init(allocator: Allocator, name: String, service_dir: String) !RunitService {
        return RunitService{
            .name = try allocator.dupe(u8, name),
            .service_dir = try allocator.dupe(u8, service_dir),
            .enabled = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RunitService) void {
        self.allocator.free(self.name);
        self.allocator.free(self.service_dir);
    }
};


pub const RunitHandler = struct {
    allocator: Allocator,
    services: ArrayList(RunitService),// Runit handler: services are directories with a 'run' script
    // Enabled services are typically symlinked into /var/service
    service_base: String,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .services = ArrayList(RunitService).init(allocator),
            .service_base = "/etc/runit/sv",
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.services.items) |*service| {
            service.deinit();
        }
        self.services.deinit();
    }

    // Iterate service_base and treat dirs with a 'run' file as services.
    // We don't touch supervise/ or log/ here to avoid breaking supervision.
    pub fn detectServices(self: *Self) !void {
        var dir = std.fs.cwd().openDir(self.service_base, .{ .iterate = true }) catch |err| {
            std.debug.print("{s}Error: Cannot open runit service dir: {any}{s}\n", .{ ansi.Color.BOLD_RED, err, ansi.Color.RESET });
            return;
        };
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .directory) {
                const service_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.service_base, entry.name });
                defer self.allocator.free(service_dir);

                const run_file = try std.fmt.allocPrint(self.allocator, "{s}/run", .{service_dir});
                defer self.allocator.free(run_file);

                std.fs.cwd().access(run_file, .{}) catch continue;

                var service = try RunitService.init(self.allocator, entry.name, service_dir);
                service.enabled = true;
                try self.services.append(service);
            }
        }
    }


    pub fn backupService(self: *Self, service_name: String) !?String {
        // The run script is the service definition; snapshot it verbatim.
        const run_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}/run", .{ self.service_base, service_name });
        defer self.allocator.free(run_path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, run_path, 1024 * 1024) catch |err| {
            std.debug.print("{s}Error: Failed to read {s}: {any}{s}\n", .{ ansi.Color.BOLD_RED, run_path, err, ansi.Color.RESET });
            return null;
        };

        return content;
    }


    pub fn restoreService(self: *Self, service_name: String, content: String) !void {
        const service_dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.service_base, service_name });
        defer self.allocator.free(service_dir);

        try std.fs.cwd().makePath(service_dir);

        const run_path = try std.fmt.allocPrint(self.allocator, "{s}/run", .{service_dir});
        defer self.allocator.free(run_path);// Recreate service dir + run script; then symlink it into /var/service to enable.

        const file = try std.fs.cwd().createFile(run_path, .{ .mode = 0o755 });
        defer file.close();

        try file.writeAll(content);

        const link_dir = "/var/service";
        const link_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ link_dir, service_name });
        defer self.allocator.free(link_path);

        std.fs.cwd().symLink(service_dir, link_path, .{}) catch |err| {
            std.debug.print("{s}Error: Failed to create symlink: {any}{s}\n", .{ ansi.Color.BOLD_RED, err, ansi.Color.RESET });
        };
    }


    pub fn exportServices(self: *Self) !ArrayList(u8) {
        // Export format: NAME|DIR|enabled
        var output = ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        try writer.writeAll("RUNIT_SERVICES\n");
        for (self.services.items) |service| {
            try writer.print("{s}|{s}|{s}\n", .{
                service.name,
                service.service_dir,
                if (service.enabled) "enabled" else "disabled",
            });
        }

        return output;
    }
};
