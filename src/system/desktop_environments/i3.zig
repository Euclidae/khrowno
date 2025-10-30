//! i3 Window Manager Handler
//
//! i3 is a tiling window manager - no fancy desktop environment, just windows and workspaces.
//! Configuration is dead simple: one config file at ~/.config/i3/config
//! and optionally an i3status config for the status bar.
//
//! This is probably the easiest "desktop environment" to backup because it's just
//! text files. No databases, no million config files, no themes to worry about.
//! i3 users like it simple, and so do we.

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../../utils/types.zig");
const String = types.String;

// config_content: main i3 config (keybindings, window rules)
// workspace_layout: not used yet
// bar_config: i3status bar settings
pub const I3Settings = struct {
    config_content: ArrayList(u8),
    workspace_layout: ?String,
    bar_config: ArrayList(u8),

    allocator: Allocator,

    pub fn init(allocator: Allocator) I3Settings {
        return I3Settings{
            .config_content = ArrayList(u8).init(allocator),
            .workspace_layout = null,
            .bar_config = ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *I3Settings) void {
        self.config_content.deinit();
        if (self.workspace_layout) |layout| {
            self.allocator.free(layout);
        }
        self.bar_config.deinit();
    }
};

pub const I3Handler = struct {
    allocator: Allocator,
    settings: I3Settings,
    config_path: String,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const home = std.posix.getenv("HOME") orelse "/home";
        const config_path = try std.fmt.allocPrint(allocator, "{s}/.config/i3/config", .{home});

        return Self{
            .allocator = allocator,
            .settings = I3Settings.init(allocator),
            .config_path = config_path,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.config_path);
        self.settings.deinit();
    }

    pub fn backupSettings(self: *Self) !void {
        try self.backupConfig();
        try self.backupBarConfig();
    }

    fn backupConfig(self: *Self) !void {
        const content = std.fs.cwd().readFileAlloc(self.allocator, self.config_path, 1024 * 1024) catch return;
        defer self.allocator.free(content);

        try self.settings.config_content.appendSlice(content);
    }

    fn backupBarConfig(self: *Self) !void {
        const home = std.posix.getenv("HOME") orelse "/home";
        const bar_config_path = try std.fmt.allocPrint(self.allocator, "{s}/.config/i3status/config", .{home});
        defer self.allocator.free(bar_config_path);

        const content = std.fs.cwd().readFileAlloc(self.allocator, bar_config_path, 1024 * 1024) catch return;
        defer self.allocator.free(content);

        try self.settings.bar_config.appendSlice(content);
    }

    pub fn restoreSettings(self: *Self) !void {
        try self.restoreConfig();
        try self.restoreBarConfig();
    }

    fn restoreConfig(self: *Self) !void {
        if (self.settings.config_content.items.len > 0) {
            const config_dir = std.fs.path.dirname(self.config_path);
            if (config_dir) |dir| {
                try std.fs.cwd().makePath(dir);
            }

            const file = try std.fs.cwd().createFile(self.config_path, .{});
            defer file.close();

            try file.writeAll(self.settings.config_content.items);
        }
    }

    fn restoreBarConfig(self: *Self) !void {
        if (self.settings.bar_config.items.len > 0) {
            const home = std.posix.getenv("HOME") orelse "/home";
            const bar_config_path = try std.fmt.allocPrint(self.allocator, "{s}/.config/i3status/config", .{home});
            defer self.allocator.free(bar_config_path);

            const config_dir = std.fs.path.dirname(bar_config_path);
            if (config_dir) |dir| {
                try std.fs.cwd().makePath(dir);
            }

            const file = try std.fs.cwd().createFile(bar_config_path, .{});
            defer file.close();

            try file.writeAll(self.settings.bar_config.items);
        }
    }

    pub fn exportSettings(self: *Self) !ArrayList(u8) {
        var output = ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        try writer.writeAll("I3_SETTINGS\n");
        try writer.writeAll("CONFIG:\n");
        try writer.writeAll(self.settings.config_content.items);
        try writer.writeAll("\nBAR_CONFIG:\n");
        try writer.writeAll(self.settings.bar_config.items);

        return output;
    }
};
