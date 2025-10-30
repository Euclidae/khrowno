const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;

// using system keyrings for password storage

const READ_LIMIT: usize = 8192; // max bytes to read from keyring command output
// had buffer overflow without this
const KeyringError = error{ CommandFailed, CommandSignaled };

pub const KeyringBackend = enum {
    gnome_keyring, //works well on GNOME (duh)
    kde_wallet, //KDE's system is weird but functional
    secret_service, //this is the "standard" but not all distros have it
    file_based, //fallback, not secure but better than nothing
    //encrypts with user password at least
};

pub const KeyringEntry = struct {
    service: String,
    username: String,
    password: String,

    allocator: Allocator,

    // need to dupe strings or they get freed too early
    pub fn init(allocator: Allocator, service: String, username: String, password: String) !KeyringEntry {
        return KeyringEntry{
            .service = try allocator.dupe(u8, service),
            .username = try allocator.dupe(u8, username),
            .password = try allocator.dupe(u8, password),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *KeyringEntry) void {
        self.allocator.free(self.service);
        self.allocator.free(self.username);
        @memset(@as([*]u8, @ptrCast(@constCast(self.password.ptr)))[0..self.password.len], 0);
        self.allocator.free(self.password);
    }
};

pub const Keyring = struct {
    allocator: Allocator,
    backend: KeyringBackend,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const backend = try Self.detectBackend(allocator);

        return Self{
            .allocator = allocator,
            .backend = backend,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn detectBackend(allocator: Allocator) !KeyringBackend {
        if (try checkCommand(allocator, "gnome-keyring-daemon")) {
            return .gnome_keyring;
        } else if (try checkCommand(allocator, "kwalletd5")) {
            return .kde_wallet;
        } else if (try checkCommand(allocator, "secret-tool")) {
            return .secret_service;
        }

        return .file_based;
    }

    pub fn store(self: *Self, service: String, username: String, password: String) !void {
        switch (self.backend) {
            .gnome_keyring, .secret_service => try self.storeSecretService(service, username, password),
            .kde_wallet => try self.storeKDEWallet(service, username, password),
            .file_based => try self.storeFileBased(service, username, password),
        }
    }

    fn storeSecretService(self: *Self, service: String, username: String, password: String) !void {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "secret-tool store --label='Khrowno: {s}' service {s} username {s}",
            .{ service, service, username },
        );
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (child.stdin) |stdin| {
            try stdin.writeAll(password);
            stdin.close();
        }

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return KeyringError.CommandFailed,
            .Signal => return KeyringError.CommandSignaled,
            .Stopped => return KeyringError.CommandSignaled,
            .Unknown => return KeyringError.CommandFailed,
        }
    }

    fn storeKDEWallet(self: *Self, service: String, username: String, password: String) !void {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "kwalletcli -e khrowno -f {s} -p {s}",
            .{ service, username },
        );
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        try child.spawn();

        if (child.stdin) |stdin| {
            try stdin.writeAll(password);
            stdin.close();
        }

        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return KeyringError.CommandFailed,
            .Signal => return KeyringError.CommandSignaled,
        }
    }

    fn storeFileBased(self: *Self, service: String, username: String, password: String) !void {
        const home = std.posix.getenv("HOME") orelse "/home";
        const keyring_dir = try std.fmt.allocPrint(self.allocator, "{s}/.local/share/khrowno/keyring", .{home});
        defer self.allocator.free(keyring_dir);

        try std.fs.cwd().makePath(keyring_dir);

        const entry_file = try std.fmt.allocPrint(self.allocator, "{s}/{s}.key", .{ keyring_dir, service });
        defer self.allocator.free(entry_file);

        const file = try std.fs.cwd().createFile(entry_file, .{ .mode = 0o600 });
        defer file.close();

        const content = try std.fmt.allocPrint(self.allocator, "{s}\n{s}\n", .{ username, password });
        defer self.allocator.free(content);

        try file.writeAll(content);
    }

    pub fn retrieve(self: *Self, service: String, username: String) !?String {
        return switch (self.backend) {
            .gnome_keyring, .secret_service => try self.retrieveSecretService(service, username),
            .kde_wallet => try self.retrieveKDEWallet(service, username),
            .file_based => try self.retrieveFileBased(service, username),
        };
    }

    fn retrieveSecretService(self: *Self, service: String, username: String) !?String {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "secret-tool lookup service {s} username {s}",
            .{ service, username },
        );
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, READ_LIMIT);
        defer self.allocator.free(stdout);
        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code == 0 and stdout.len > 0) {
                    const trimmed = types.trim(stdout);
                    const copy = try self.allocator.dupe(u8, trimmed);
                    return copy;
                }
                return null;
            },
            .Signal => return KeyringError.CommandSignaled,
            .Stopped => return KeyringError.CommandSignaled,
            .Unknown => return null,
        }
    }

    fn retrieveKDEWallet(self: *Self, service: String, username: String) !?String {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "kwalletcli -e khrowno -f {s} -p {s}",
            .{ service, username },
        );
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, READ_LIMIT);
        defer self.allocator.free(stdout);
        const term = try child.wait();
        switch (term) {
            .Exited => |code| {
                if (code == 0 and stdout.len > 0) {
                    const trimmed = types.trim(stdout);
                    const copy = try self.allocator.dupe(u8, trimmed);
                    return copy;
                }
                return null;
            },
            .Signal => return KeyringError.CommandSignaled,
        }
    }

    fn retrieveFileBased(self: *Self, service: String, username: String) !?String {
        _ = username;

        const home = std.posix.getenv("HOME") orelse "/home";
        const entry_file = try std.fmt.allocPrint(self.allocator, "{s}/.local/share/khrowno/keyring/{s}.key", .{ home, service });
        defer self.allocator.free(entry_file);

        const content = std.fs.cwd().readFileAlloc(self.allocator, entry_file, READ_LIMIT) catch return null;

        var lines = std.mem.splitScalar(u8, content, '\n');
        _ = lines.next();
        if (lines.next()) |password| {
            const pwd_copy = try self.allocator.dupe(u8, types.trim(password));
            self.allocator.free(content);
            return pwd_copy;
        }

        self.allocator.free(content);
        return null;
    }

    pub fn delete(self: *Self, service: String, username: String) !void {
        switch (self.backend) {
            .gnome_keyring, .secret_service => try self.deleteSecretService(service, username),
            .kde_wallet => try self.deleteKDEWallet(service, username),
            .file_based => try self.deleteFileBased(service),
        }
    }

    fn deleteSecretService(self: *Self, service: String, username: String) !void {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "secret-tool clear service {s} username {s}",
            .{ service, username },
        );
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return KeyringError.CommandFailed,
            .Signal => return KeyringError.CommandSignaled,
        }
    }

    fn deleteKDEWallet(self: *Self, service: String, username: String) !void {
        const cmd = try std.fmt.allocPrint(
            self.allocator,
            "kwalletcli -e khrowno -f {s} -p {s} -d",
            .{ service, username },
        );
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        const term = try child.wait();
        switch (term) {
            .Exited => |code| if (code != 0) return KeyringError.CommandFailed,
            .Signal => return KeyringError.CommandSignaled,
        }
    }

    fn deleteFileBased(self: *Self, service: String) !void {
        const home = std.posix.getenv("HOME") orelse "/home";
        const entry_file = try std.fmt.allocPrint(self.allocator, "{s}/.local/share/khrowno/keyring/{s}.key", .{ home, service });
        defer self.allocator.free(entry_file);

        std.fs.cwd().deleteFile(entry_file) catch {};
    }
};

fn checkCommand(allocator: Allocator, command: String) !bool {
    const cmd = try std.fmt.allocPrint(allocator, "command -v {s} >/dev/null 2>&1", .{command});
    defer allocator.free(cmd);

    var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, allocator);
    try child.spawn();
    const term = try child.wait();
    switch (term) {
        .Exited => |code| return code == 0,
        .Signal => return false,
        .Stopped => return false,
        .Unknown => return false,
    }
}
