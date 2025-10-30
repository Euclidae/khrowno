const std = @import("std");

pub const String = []const u8;
pub const FileSize = u64;
pub const FileMode = u32;
pub const Timestamp = i64;

pub const Path = struct {
    value: String,

    const Self = @This();

    pub fn init(path: String) Self {
        return Self{ .value = path };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.value);
    }

    pub fn isHidden(self: *const Self) bool {
        return self.value.len > 0 and self.value[0] == '.';
    }

    pub fn getFilename(self: *const Self) String {
        if (std.mem.lastIndexOfScalar(u8, self.value, '/')) |last_slash| {
            return self.value[last_slash + 1 ..];
        }
        return self.value;
    }

    // Decides if a file should be included in backups. We skip cache dirs, temp files, logs, and build artifacts, node_modules alone can be gigabytes you can reinstall with npm
    pub fn shouldBackup(self: *const Self) bool {
        const skip_patterns = [_]String{
            ".cache",
            ".tmp",
            ".log",
            ".lock",
            "node_modules",
            ".git",
            "__pycache__",
        };

        for (skip_patterns) |pattern| {
            if (std.mem.indexOf(u8, self.value, pattern) != null) {
                return false;
            }
        }

        return true;
    }
};

pub const Result = union(enum) {
    success: void,
    failure: String,

    const Self = @This();

    pub fn ok() Self {
        return Self{ .success = {} };
    }

    pub fn err(msg: String) Self {
        return Self{ .failure = msg };
    }

    pub fn isOk(self: *const Self) bool {
        return switch (self.*) {
            .success => true,
            .failure => false,
        };
    }

    pub fn isError(self: *const Self) bool {
        return !self.isOk();
    }

    pub fn getError(self: *const Self) ?String {
        return switch (self.*) {
            .success => null,
            .failure => |msg| msg,
        };
    }
};

pub const Option = union(enum) {
    value: String,
    empty: void,

    const Self = @This();

    pub fn some(val: String) Self {
        return Self{ .value = val };
    }

    pub fn none() Self {
        return Self{ .empty = {} };
    }

    pub fn isSome(self: *const Self) bool {
        return switch (self.*) {
            .value => true,
            .empty => false,
        };
    }

    pub fn isNone(self: *const Self) bool {
        return !self.isSome();
    }

    pub fn unwrap(self: *const Self) ?String {
        return switch (self.*) {
            .value => |val| val,
            .empty => null,
        };
    }

    pub fn unwrapOr(self: *const Self, default_value: String) String {
        return switch (self.*) {
            .value => |val| val,
            .empty => default_value,
        };
    }
};

pub const IMPORTANT_EXTENSIONS = [_]String{
    ".conf",
    ".config",
    ".rc",
    ".ini",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".sh",
    ".bash",
    ".zsh",
    ".py",
    ".js",
    ".rs",
    ".zig",
    ".c",
    ".h",
    ".cpp",
    ".hpp",
};

pub const CONFIG_DIRS = [_]String{
    ".config",
    ".local/share",
    ".cache",
    ".ssh",
    ".gnupg",
    ".mozilla",
    ".thunderbird",
    ".vim",
    ".emacs.d", // I use doom emacs by the way...
};

pub fn isAscii(s: String) bool {
    for (s) |byte| {
        if (byte > 127) return false;
    }
    return true;
}

pub fn toLower(allocator: std.mem.Allocator, s: String) !String {
    // /* ASCII lowercase conversion - add 32 to uppercase letters
    //    'A' is 65, 'a' is 97, difference is 32 not 26 because ASCII designers
    //    shoved symbols like [] between Z and a */
    var result = try allocator.alloc(u8, s.len);
    errdefer allocator.free(result);

    for (s, 0..) |byte, i| {
        if (byte >= 'A' and byte <= 'Z') {
            result[i] = byte + 32;
        } else {
            result[i] = byte;
        }
    }

    return result;
}

pub fn startsWith(s: String, prefix: String) bool {
    if (s.len < prefix.len) return false;
    return std.mem.eql(u8, s[0..prefix.len], prefix);
}

pub fn endsWith(s: String, suffix: String) bool {
    if (s.len < suffix.len) return false;
    return std.mem.eql(u8, s[s.len - suffix.len ..], suffix);
}

pub fn trim(s: String) String {
    var start: usize = 0;
    var end: usize = s.len;

    while (start < end and (s[start] == ' ' or s[start] == '\t' or s[start] == '\r' or s[start] == '\n')) {
        start += 1;
    }

    while (end > start and (s[end - 1] == ' ' or s[end - 1] == '\t' or s[end - 1] == '\r' or s[end - 1] == '\n')) {
        end -= 1;
    }

    return s[start..end];
}
