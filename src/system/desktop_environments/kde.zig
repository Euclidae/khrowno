//! KDE Plasma Desktop Environment Handler
//
//! KDE is... special. It has approximately one million config files scattered
//! across ~/.config. We try to grab the important ones (kdeglobals, kwinrc, etc.)
//! and the Plasma theme because that's what makes your desktop look pretty.
//
//! Unlike GNOME's centralized dconf, KDE uses individual .rc files for everything.
//! more flexible but chaotic

//! KDE has way too many config files that change between plasma versions
//! plasma 6 will probably break this

const std = @import("std");
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../../utils/types.zig");
const String = types.String;

// config_files: kdeglobals, kwinrc, plasmarc, etc
// plasma_theme: breeze/breeze-dark/whatever
// kwin_rules: window-specific rules and tweaks
pub const KDESettings = struct {
    config_files: ArrayList(String),
    plasma_theme: ?String,
    kwin_rules: ArrayList(u8),
    
    // kwin rules format is annoying to parse so we just store raw bytes
    // works across plasma versions at least
    
    allocator: Allocator,
    
    pub fn init(allocator: Allocator) KDESettings {
        return KDESettings{
            .config_files = ArrayList(String).init(allocator),
            .plasma_theme = null,
            .kwin_rules = ArrayList(u8).init(allocator),
            .allocator = allocator,
        };
    }
    
    pub fn deinit(self: *KDESettings) void {
        for (self.config_files.items) |file| {
            self.allocator.free(file);
        }
        self.config_files.deinit();
        if (self.plasma_theme) |theme| {
            self.allocator.free(theme);
        }
        self.kwin_rules.deinit();
    }
};

pub const KDEHandler = struct {
    allocator: Allocator,
    settings: KDESettings,
    config_dir: String,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const home = std.posix.getenv("HOME") orelse "/home";
        const config_dir = try std.fmt.allocPrint(allocator, "{s}/.config", .{home});
        
        return Self{
            .allocator = allocator,
            .settings = KDESettings.init(allocator),
            .config_dir = config_dir,
        };
    }
    
    pub fn deinit(self: *Self) void {
        self.allocator.free(self.config_dir);
        self.settings.deinit();
    }
    
    pub fn backupSettings(self: *Self) !void {
        try self.backupConfigFiles();
        try self.backupPlasmaTheme();
        try self.backupKWinRules();
    }
    
    fn backupConfigFiles(self: *Self) !void {
        const config_patterns = [_]String{
            "kderc",
            "kdeglobals",
            "kwinrc",
            "plasmarc",
            "kscreenlockerrc",
            "ksmserverrc",
        };
        
        var dir = std.fs.cwd().openDir(self.config_dir, .{ .iterate = true }) catch return;
        defer dir.close();
        
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            for (config_patterns) |pattern| {
                if (std.mem.indexOf(u8, entry.name, pattern) != null) {
                    const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config_dir, entry.name });
                    try self.settings.config_files.append(full_path);
                }
            }
        }
    }
    
    fn backupPlasmaTheme(self: *Self) !void {
        const cmd = "kreadconfig5 --file plasmarc --group Theme --key name";
        
        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        
        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024);
        
        const term = try child.wait();
        if (term.Exited == 0 and stdout.len > 0) {
            const trimmed = types.trim(stdout);
            const copy = try self.allocator.dupe(u8, trimmed);
            self.settings.plasma_theme = copy;
        }
        self.allocator.free(stdout);
    }
    
    fn backupKWinRules(self: *Self) !void {
        const kwinrules_path = try std.fmt.allocPrint(self.allocator, "{s}/kwinrulesrc", .{self.config_dir});
        defer self.allocator.free(kwinrules_path);
        
        const content = std.fs.cwd().readFileAlloc(self.allocator, kwinrules_path, 1024 * 1024) catch return;
        defer self.allocator.free(content);
        
        try self.settings.kwin_rules.appendSlice(content);
    }
    
    pub fn restoreSettings(self: *Self) !void {
        try self.restoreConfigFiles();
        try self.restorePlasmaTheme();
        try self.restoreKWinRules();
    }
    
    fn restoreConfigFiles(self: *Self) !void {
        for (self.settings.config_files.items) |config_path| {
            const content = std.fs.cwd().readFileAlloc(self.allocator, config_path, 1024 * 1024) catch continue;
            defer self.allocator.free(content);
            
            const basename = std.fs.path.basename(config_path);
            const target_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.config_dir, basename });
            defer self.allocator.free(target_path);
            
            const file = try std.fs.cwd().createFile(target_path, .{});
            defer file.close();
            
            try file.writeAll(content);
        }
    }
    
    fn restorePlasmaTheme(self: *Self) !void {
        if (self.settings.plasma_theme) |theme| {
            const cmd = try std.fmt.allocPrint(self.allocator, "kwriteconfig5 --file plasmarc --group Theme --key name {s}", .{theme});
            defer self.allocator.free(cmd);
            
            var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
            try child.spawn();
            _ = try child.wait();
        }
    }
    
    fn restoreKWinRules(self: *Self) !void {
        if (self.settings.kwin_rules.items.len > 0) {
            const kwinrules_path = try std.fmt.allocPrint(self.allocator, "{s}/kwinrulesrc", .{self.config_dir});
            defer self.allocator.free(kwinrules_path);
            
            const file = try std.fs.cwd().createFile(kwinrules_path, .{});
            defer file.close();
            
            try file.writeAll(self.settings.kwin_rules.items);
        }
    }
    
    pub fn exportSettings(self: *Self) !ArrayList(u8) {
        var output = ArrayList(u8).init(self.allocator);
        const writer = output.writer();
        
        try writer.writeAll("KDE_SETTINGS\n");
        try writer.writeAll("CONFIG_FILES:\n");
        for (self.settings.config_files.items) |file| {
            try writer.print("{s}\n", .{file});
        }
        if (self.settings.plasma_theme) |theme| {
            try writer.print("\nPLASMA_THEME: {s}\n", .{theme});
        }
        try writer.writeAll("\nKWIN_RULES:\n");
        try writer.writeAll(self.settings.kwin_rules.items);
        
        return output;
    }
};
