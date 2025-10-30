//! yup... ended up doing it.

//! XFCE Desktop Environment Handler
//
//! XFCE uses xfconf for settings management - it's like a simpler version of dconf.
//! We backup the main channels (xfce4-desktop, xfce4-panel, xfwm4, xsettings),
//! panel configuration files, and theme settings.
//
//! XFCE is lightweight and straightforward, which makes it pretty easy to backup.
//! No million config files like KDE, no binary database mysteries like GNOME.
//! Just good old xfconf and some config files. Refreshing, honestly.

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../../utils/types.zig");
const String = types.String;

// xfconf_settings: desktop, panel, wm channels
// panel_config: panel layout and plugins
// theme_settings: gtk/xfce theme prefs
pub const XfceSettings = struct {
    xfconf_settings: ArrayList(u8),
    panel_config: ArrayList(u8),
    theme_settings: ArrayList(u8),

    allocator: Allocator,

    pub fn init(allocator: Allocator) XfceSettings {
        return XfceSettings{
            .xfconf_settings = ArrayList(u8).init(allocator),
            .panel_config = ArrayList(u8).init(allocator),
            .theme_settings = ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *XfceSettings) void {
        self.xfconf_settings.deinit();
        self.panel_config.deinit();
        self.theme_settings.deinit();
    }
};

pub const XfceHandler = struct {
    allocator: Allocator,
    settings: XfceSettings,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .settings = XfceSettings.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.settings.deinit();
    }

    pub fn backupSettings(self: *Self) !void {
        try self.backupXfconfSettings();
        try self.backupPanelConfig();
        try self.backupThemeSettings();
    }

    fn backupXfconfSettings(self: *Self) !void {
        const channels = [_]String{
            "xfce4-desktop",  // wallpaper, icons, desktop behavior
            "xfce4-panel",    // panel layout and applets
            "xfwm4",          // window manager tweaks
            "xsettings",      // general xfce prefs
        };

        for (channels) |channel| {
            const cmd = try std.fmt.allocPrint(self.allocator, "xfconf-query -c {s} -lv", .{channel});
            defer self.allocator.free(cmd);

            var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;

            try child.spawn();
            const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
            defer self.allocator.free(stdout);

            _ = try child.wait();

            try self.settings.xfconf_settings.writer().print("[{s}]\n", .{channel});
            try self.settings.xfconf_settings.appendSlice(stdout);
            try self.settings.xfconf_settings.appendSlice("\n");
        }
    }

    fn backupPanelConfig(self: *Self) !void {
        const home = std.posix.getenv("HOME") orelse "/home";
        const panel_dir = try std.fmt.allocPrint(self.allocator, "{s}/.config/xfce4/panel", .{home});
        defer self.allocator.free(panel_dir);

        var dir = std.fs.cwd().openDir(panel_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ panel_dir, entry.name });
            defer self.allocator.free(full_path);

            const content = std.fs.cwd().readFileAlloc(self.allocator, full_path, 1024 * 1024) catch continue;
            defer self.allocator.free(content);

            try self.settings.panel_config.writer().print("[{s}]\n", .{entry.name});
            try self.settings.panel_config.appendSlice(content);
            try self.settings.panel_config.appendSlice("\n");
        }
    }

    fn backupThemeSettings(self: *Self) !void {
        const cmd = "xfconf-query -c xsettings -p /Net/ThemeName";

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024);
        defer self.allocator.free(stdout);

        _ = try child.wait();

        try self.settings.theme_settings.appendSlice(stdout);
    }

    pub fn restoreSettings(self: *Self) !void {
        try self.restoreXfconfSettings();
        try self.restorePanelConfig();
        try self.restoreThemeSettings();
    }

    fn restoreXfconfSettings(self: *Self) !void {
        var lines = std.mem.splitScalar(u8, self.settings.xfconf_settings.items, '\n');
        var current_channel: ?[]const u8 = null;

        while (lines.next()) |line| {
            const trimmed = types.trim(line);
            if (trimmed.len == 0) continue;

            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                current_channel = trimmed[1 .. trimmed.len - 1];
            } else if (current_channel) |channel| {
                var parts = std.mem.splitScalar(u8, trimmed, ' ');
                const property = parts.next() orelse continue;
                const value = parts.next() orelse continue;

                const cmd = try std.fmt.allocPrint(
                    self.allocator,
                    "xfconf-query -c {s} -p {s} -s {s}",
                    .{ channel, property, value },
                );
                defer self.allocator.free(cmd);

                var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
                try child.spawn();
                _ = try child.wait();
            }
        }
    }

    fn restorePanelConfig(self: *Self) !void {
        const home = std.posix.getenv("HOME") orelse "/home";
        const panel_dir = try std.fmt.allocPrint(self.allocator, "{s}/.config/xfce4/panel", .{home});
        defer self.allocator.free(panel_dir);

        try std.fs.cwd().makePath(panel_dir);

        var lines = std.mem.splitScalar(u8, self.settings.panel_config.items, '\n');
        var current_file: ?[]const u8 = null;
        var content = ArrayList(u8).init(self.allocator);
        defer content.deinit();

        while (lines.next()) |line| {
            const trimmed = types.trim(line);
            if (trimmed.len == 0) continue;

            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                if (current_file) |filename| {
                    const file_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ panel_dir, filename });
                    defer self.allocator.free(file_path);

                    const file = try std.fs.cwd().createFile(file_path, .{});
                    defer file.close();

                    try file.writeAll(content.items);
                    content.clearRetainingCapacity();
                }
                current_file = trimmed[1 .. trimmed.len - 1];
            } else {
                try content.appendSlice(line);
                try content.append('\n');
            }
        }
    }

    fn restoreThemeSettings(self: *Self) !void {
        if (self.settings.theme_settings.items.len > 0) {
            const theme = types.trim(self.settings.theme_settings.items);
            const cmd = try std.fmt.allocPrint(
                self.allocator,
                "xfconf-query -c xsettings -p /Net/ThemeName -s {s}",
                .{theme},
            );
            defer self.allocator.free(cmd);

            var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
            try child.spawn();
            _ = try child.wait();
        }
    }

    pub fn exportSettings(self: *Self) !ArrayList(u8) {
        var output = ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        try writer.writeAll("XFCE_SETTINGS\n");
        try writer.writeAll("XFCONF:\n");
        try writer.writeAll(self.settings.xfconf_settings.items);
        try writer.writeAll("\nPANEL:\n");
        try writer.writeAll(self.settings.panel_config.items);
        try writer.writeAll("\nTHEME:\n");
        try writer.writeAll(self.settings.theme_settings.items);

        return output;
    }
};
