//! GNOME Desktop Environment Handler
//
//! Backs up and restores GNOME-specific settings using dconf.
//! GNOME stores everything in dconf (a binary database), so we dump it all
//! and restore it later. Also handles extensions and keybindings separately
//! because they're important and easy to mess up.
//
//! Fun fact: This was one of the easier DEs to support because dconf makes
//! everything centralized. Unlike KDE with its million config files...
//! ... I might not do xfce actually.

//! GNOME was surprisingly easy - dconf dump/load makes everything simple
//! extensions need special treatment but otherwise straightforward

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../../utils/types.zig");
const String = types.String;

// dconf_settings: full database dump
// extensions: installed shell extensions
// keybindings: custom shortcuts
pub const GnomeSettings = struct {
    dconf_settings: ArrayList(u8),
    extensions: ArrayList(String),
    keybindings: ArrayList(u8),

    allocator: Allocator,

    pub fn init(allocator: Allocator) GnomeSettings {
        return GnomeSettings{
            .dconf_settings = ArrayList(u8).init(allocator),
            .extensions = ArrayList(String).init(allocator),
            .keybindings = ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GnomeSettings) void {
        self.dconf_settings.deinit();
        for (self.extensions.items) |ext| {
            self.allocator.free(ext);
        }
        self.extensions.deinit();
        self.keybindings.deinit();
    }
};

pub const GnomeHandler = struct {
    allocator: Allocator,
    settings: GnomeSettings,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .settings = GnomeSettings.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.settings.deinit();
    }

    pub fn backupSettings(self: *Self) !void {
        try self.backupDconfSettings();
        try self.backupExtensions();
        try self.backupKeybindings();
    }

    fn backupDconfSettings(self: *Self) !void {
        const cmd = "dconf dump /";

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(stdout);

        _ = try child.wait();

        try self.settings.dconf_settings.appendSlice(stdout);
    }

    fn backupExtensions(self: *Self) !void {
        const cmd = "gnome-extensions list";

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
            if (trimmed.len > 0) {
                try self.settings.extensions.append(try self.allocator.dupe(u8, trimmed));
            }
        }
    }

    fn backupKeybindings(self: *Self) !void {
        const cmd = "dconf dump /org/gnome/desktop/wm/keybindings/";

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        _ = try child.wait();

        try self.settings.keybindings.appendSlice(stdout);
    }

    pub fn restoreSettings(self: *Self) !void {
        try self.restoreDconfSettings();
        try self.restoreExtensions();
        try self.restoreKeybindings();
    }

    fn restoreDconfSettings(self: *Self) !void {
        const tmp_file = "/tmp/khrowno_dconf_backup.ini";

        const file = try std.fs.cwd().createFile(tmp_file, .{});
        defer file.close();

        try file.writeAll(self.settings.dconf_settings.items);

        const cmd = try std.fmt.allocPrint(self.allocator, "dconf load / < {s}", .{tmp_file});
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        try child.spawn();
        _ = try child.wait();

        std.fs.cwd().deleteFile(tmp_file) catch {};
    }

    fn restoreExtensions(self: *Self) !void {
        for (self.settings.extensions.items) |ext| {
            const cmd = try std.fmt.allocPrint(self.allocator, "gnome-extensions enable {s}", .{ext});
            defer self.allocator.free(cmd);

            var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
            try child.spawn();
            _ = try child.wait();
        }
    }

    fn restoreKeybindings(self: *Self) !void {
        const tmp_file = "/tmp/khrowno_keybindings.ini";

        const file = try std.fs.cwd().createFile(tmp_file, .{});
        defer file.close();

        try file.writeAll(self.settings.keybindings.items);

        const cmd = try std.fmt.allocPrint(self.allocator, "dconf load /org/gnome/desktop/wm/keybindings/ < {s}", .{tmp_file});
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        try child.spawn();
        _ = try child.wait();

        std.fs.cwd().deleteFile(tmp_file) catch {};
    }

    pub fn exportSettings(self: *Self) !ArrayList(u8) {
        var output = ArrayList(u8).init(self.allocator);
        const writer = output.writer();

        try writer.writeAll("GNOME_SETTINGS\n");
        try writer.writeAll("DCONF_DUMP:\n");
        try writer.writeAll(self.settings.dconf_settings.items);
        try writer.writeAll("\nEXTENSIONS:\n");
        for (self.settings.extensions.items) |ext| {
            try writer.print("{s}\n", .{ext});
        }
        try writer.writeAll("\nKEYBINDINGS:\n");
        try writer.writeAll(self.settings.keybindings.items);

        return output;
    }
};
