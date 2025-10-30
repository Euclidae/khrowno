//! Flatpak support - way easier to restore than distro packages since they work cross-distro
//! no need for the package mapping hell I dealt with in package_resolver.zig
//! snap packages can stay in the bin where they belong (😡)

const std = @import("std");
const fs = std.fs;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;

pub fn getInstalledFlatpaks(allocator: Allocator) !std.ArrayList([]u8) {
    var flatpaks = std.ArrayList([]u8).init(allocator);
    errdefer {
        for (flatpaks.items) |f| allocator.free(f); // straight forward. app ids for flatpak just goes com.doo.shit.on.car.birdie.bird
        flatpaks.deinit();
    }

    var child = std.process.Child.init(&[_]String{ "flatpak", "list", "--app", "--columns=application" }, allocator);
    // --columns=application strips version info, we just want the app ID
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    child.spawn() catch |err| {
        return err;
    };
    defer _ = child.wait() catch {};

    if (child.stdout) |stdout| {
        const data = try stdout.readToEndAlloc(allocator, 10 * 1024 * 1024);
        defer allocator.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n\t");
            if (trimmed.len > 0) {
                try flatpaks.append(try allocator.dupe(u8, trimmed));
            }
        }
    }

    return flatpaks;
}

pub fn saveFlatpakList(allocator: Allocator, filepath: String) !void {
    var flatpaks = try getInstalledFlatpaks(allocator);
    defer {
        for (flatpaks.items) |f| allocator.free(f);
        flatpaks.deinit();
    }

    if (flatpaks.items.len == 0) {
        // either I goofed or no flatpaks installed, nothing to save
        return;
    }

    const file = try fs.cwd().createFile(filepath, .{});
    defer file.close();

    try file.writer().print("KROWNO_FLATPAK_LIST\n", .{});
    try file.writer().print("TIMESTAMP: {d}\n", .{std.time.timestamp()});
    try file.writer().print("COUNT: {d}\n", .{flatpaks.items.len});

    for (flatpaks.items) |app_id| {
        try file.writer().print("{s}\n", .{app_id});
    }

    print("✓ Backed up {d} Flatpak applications\n", .{flatpaks.items.len});
}

pub fn installFlatpaksFromFile(allocator: Allocator, filepath: String) !void {
    const file = fs.cwd().openFile(filepath, .{}) catch |err| {
        if (err == error.FileNotFound) return;
        return err;
    };
    defer file.close();

    const data = try file.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(data);

    var flatpaks = std.ArrayList([]u8).init(allocator);
    defer {
        for (flatpaks.items) |f| allocator.free(f);
        flatpaks.deinit();
    }

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\n\t");
        if (trimmed.len == 0 or
            std.mem.startsWith(u8, trimmed, "KROWNO_") or
            std.mem.startsWith(u8, trimmed, "TIMESTAMP:") or
            std.mem.startsWith(u8, trimmed, "COUNT:"))
        {
            continue;
        }

        try flatpaks.append(try allocator.dupe(u8, trimmed));
    }

    if (flatpaks.items.len == 0) {
        return;
    }

    // same progress pattern as package_resolver.zig - show what we're doing
    print("Installing Flatpak applications...\n", .{});
    print("  Found {d} Flatpaks to install\n", .{flatpaks.items.len});

    if (!isFlatpakInstalled(allocator)) {
        print("  ⚠ Flatpak is not installed - skipping Flatpak installation\n", .{});
        print("  Install Flatpak first: sudo apt install flatpak (or equivalent)\n", .{});
        return;
    }

    // track success/failure like we do in package_resolver.zig
    var installed: usize = 0;
    var failed: usize = 0;

    for (flatpaks.items) |app_id| {
        print("  Installing {s}...\n", .{app_id});

        if (installFlatpak(allocator, app_id)) {
            installed += 1;
        } else |_| {
            failed += 1;
        }
    }

    print("  ✓ Flatpak installation complete: {d} installed, {d} failed\n", .{ installed, failed });
}

fn isFlatpakInstalled(allocator: Allocator) bool {
    // checking if flatpak command exists, same pattern from package_resolver.zig
    var child = std.process.Child.init(&[_]String{ "which", "flatpak" }, allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn installFlatpak(allocator: Allocator, app_id: String) !void {
    // install from flathub by default, -y auto-confirms
    // inherit stdout/stderr so user sees download progress.
    // late entry because I am an idiot. I forgot flatpaks don't come installed by default, lol so I should probably handle that somewhere.
    // TODO ^
    var child = std.process.Child.init(&[_]String{ "flatpak", "install", "-y", "flathub", app_id }, allocator);
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();
    const term = try child.wait();

    if (term != .Exited or term.Exited != 0) {
        return error.InstallationFailed;
    }
}

pub fn installFlatpaksFromDirectory(allocator: Allocator, dir_path: String) !void {
    var dir = fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // scan directory for flatpak backup files
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, "krowno_flatpaks_")) continue;

        const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.name });
        defer allocator.free(fpath);

        try installFlatpaksFromFile(allocator, fpath);
        return;
    }
}
