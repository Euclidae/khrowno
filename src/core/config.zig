const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const types = @import("../utils/types.zig");
const String = types.String;
const FileSize = types.FileSize;

pub const Config = struct {
    backup_strategy: String = "standard",
    max_file_size: FileSize = 10 * 1024 * 1024, // skip files bigger than 10MB by default - usually cache/temp files
    compression_level: u8 = 6, // zstd level 6 gives decent compression without being too slow
    encryption_enabled: bool = true, // always encrypt by default, users can disable if they want

    show_progress: bool = true,
    auto_close_dialogs: bool = false, // dont auto-close so users can read errors
    theme: String = "default",

    parallel_backup: bool = false, // disabled by default until more testing done
    verify_checksums: bool = true, // always verify - catches corruption early
    backup_retention_days: u32 = 30,

    const Self = @This();

    pub fn loadFromFile(allocator: std.mem.Allocator, path: String) !Self {
        const content = fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch |err| switch (err) {
            error.FileNotFound => {
                return Self{}; // return defaults if no config file
            },
            else => return err,
        };
        defer allocator.free(content);

        var config = Self{};

        // simple ini-style parsing - good enough for config files
        var lines = std.mem.split(u8, content, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue; // skip empty lines and comments

            if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
                const key = trimmed[0..eq_pos];
                const value = trimmed[eq_pos + 1 ..];

                try parseConfigValue(&config, key, value, allocator);
            }
        }

        return config;
    }

    pub fn saveToFile(self: *const Self, _: std.mem.Allocator, path: String) !void {
        const file = try fs.createFileAbsolute(path, .{});
        defer file.close();

        var writer = file.writer();

        try writer.writeAll("# Krowno Backup Tool Configuration\n");
        try writer.writeAll("# Generated automatically - edit with care\n\n");

        try writer.writeAll("[Backup]\n");
        try writer.print("strategy={s}\n", .{self.backup_strategy});
        try writer.print("max_file_size={d}\n", .{self.max_file_size});
        try writer.print("compression_level={d}\n", .{self.compression_level});
        try writer.print("encryption_enabled={any}\n", .{self.encryption_enabled});
        try writer.writeAll("\n");

        try writer.writeAll("[UI]\n");
        try writer.print("show_progress={any}\n", .{self.show_progress});
        try writer.print("auto_close_dialogs={any}\n", .{self.auto_close_dialogs});
        try writer.print("theme={s}\n", .{self.theme});
        try writer.writeAll("\n");

        try writer.writeAll("[Advanced]\n");
        try writer.print("parallel_backup={any}\n", .{self.parallel_backup});
        try writer.print("verify_checksums={any}\n", .{self.verify_checksums});
        try writer.print("backup_retention_days={d}\n", .{self.backup_retention_days});
    }

    pub fn getDefaultPath() String {
        // follow XDG base directory spec
        const home = std.posix.getenv("HOME") orelse "/tmp";
        return home ++ "/.config/krowno/config.ini";
    }

    pub fn loadDefault(allocator: std.mem.Allocator) !Self {
        const config_path = getDefaultPath();

        const config = loadFromFile(allocator, config_path) catch |err| switch (err) {
            error.FileNotFound => {
                // first run - create config directory and default config file
                print("Creating default config\n", .{});
                const default_config = Self{};

                const config_dir = std.fs.path.dirname(config_path) orelse "/tmp";
                fs.makePathAbsolute(config_dir) catch |path_err| {
                    // not fatal if we cant create dir, just means config wont persist
                    print("Warning: Could not create config directory: {}\n", .{path_err});
                };

                default_config.saveToFile(allocator, config_path) catch |save_err| {
                    print("Warning: Could not save default config: {}\n", .{save_err});
                };

                return default_config;
            },
            else => return err,
        };

        return config;
    }
};

fn parseConfigValue(config: *Config, key: String, value: String, allocator: std.mem.Allocator) !void {
    if (std.mem.eql(u8, key, "strategy")) {
        config.backup_strategy = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "max_file_size")) {
        config.max_file_size = std.fmt.parseInt(u64, value, 10) catch config.max_file_size;
    } else if (std.mem.eql(u8, key, "compression_level")) {
        const level = std.fmt.parseInt(u8, value, 10) catch config.compression_level;
        if (level <= 9) config.compression_level = level;
    } else if (std.mem.eql(u8, key, "encryption_enabled")) {
        config.encryption_enabled = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "show_progress")) {
        config.show_progress = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "auto_close_dialogs")) {
        config.auto_close_dialogs = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "theme")) {
        config.theme = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "parallel_backup")) {
        config.parallel_backup = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "verify_checksums")) {
        config.verify_checksums = std.mem.eql(u8, value, "true");
    } else if (std.mem.eql(u8, key, "backup_retention_days")) {
        config.backup_retention_days = std.fmt.parseInt(u32, value, 10) catch config.backup_retention_days;
    } else {
        print("Unknown config key: {s}\n", .{key});
    }
}

pub fn validateConfig(config: *const Config) bool {
    var valid = true;

    const valid_strategies = [_]String{ "minimal", "standard", "personal", "full" };
    var strategy_valid = false;
    for (valid_strategies) |strategy| {
        if (std.mem.eql(u8, config.backup_strategy, strategy)) {
            strategy_valid = true;
            break;
        }
    }
    if (!strategy_valid) {
        print("Invalid backup strategy: {s}\n", .{config.backup_strategy});
        valid = false;
    }

    if (config.compression_level > 9) {
        print("Invalid compression level: {}\n", .{config.compression_level});
        valid = false;
    }

    if (config.max_file_size == 0) {
        print("Invalid max file size: {}\n", .{config.max_file_size});
        valid = false;
    }

    if (config.backup_retention_days == 0) {
        print("Invalid retention days: {}\n", .{config.backup_retention_days});
        valid = false;
    }

    return valid;
}

pub fn getEnvOverrides(allocator: std.mem.Allocator) !Config {
    var overrides = Config{};

    if (std.posix.getenv("KROWNO_STRATEGY")) |strategy| {
        overrides.backup_strategy = try allocator.dupe(u8, strategy);
    }

    if (std.posix.getenv("KROWNO_MAX_FILE_SIZE")) |size_str| {
        overrides.max_file_size = std.fmt.parseInt(u64, size_str, 10) catch overrides.max_file_size;
    }

    if (std.posix.getenv("KROWNO_COMPRESSION")) |comp_str| {
        overrides.compression_level = std.fmt.parseInt(u8, comp_str, 10) catch overrides.compression_level;
    }

    if (std.posix.getenv("KROWNO_ENCRYPTION")) |enc_str| {
        overrides.encryption_enabled = std.mem.eql(u8, enc_str, "true");
    }

    return overrides;
}

pub fn mergeConfig(base: *const Config, overrides: *const Config, allocator: std.mem.Allocator) !Config {
    var merged = base.*;

    if (!std.mem.eql(u8, overrides.backup_strategy, "standard")) {
        merged.backup_strategy = try allocator.dupe(u8, overrides.backup_strategy);
    }

    if (overrides.max_file_size != 10 * 1024 * 1024) {
        merged.max_file_size = overrides.max_file_size;
    }

    if (overrides.compression_level != 6) {
        merged.compression_level = overrides.compression_level;
    }

    if (overrides.encryption_enabled != true) {
        merged.encryption_enabled = overrides.encryption_enabled;
    }

    return merged;
}
