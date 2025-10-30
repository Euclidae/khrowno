const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;
const ansi = @import("ansi.zig");

// grabs enabled repos from various package managers
// snapshots param is anytype to avoid circular imports with backup.zig
// expects: allocator, metadata ArrayList, repository_count, package_count fields
pub const RepoCrawler = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) !RepoCrawler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RepoCrawler) void {
        _ = self;
    }

    // Capture current repositories from common Linux package managers.
    // apt: sources.list or apt-cache policy
    // dnf: dnf repolist -v
    // pacman: pacman -Sl
    // best-effort - failures logged but dont abort backup
    pub fn captureCurrentRepos(self: *RepoCrawler, snapshots: anytype) !void {
        // Helper to run a command and append non-empty lines to snapshots.metadata
        const Helper = struct {
            fn runAndCollect(allocator: Allocator, cmdline: []const []const u8, label: []const u8, sink: anytype) void {
            var child = std.process.Child.init(cmdline, allocator);
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
            child.spawn() catch |e| {
                print("{s}Error: repo_crawler spawn failed for '{s}': {any}{s}\n", .{ ansi.Color.BOLD_RED, label, e, ansi.Color.RESET });
                return;
            };
            const out = child.stdout.?.reader().readAllAlloc(allocator, 1024 * 1024) catch |e| {
                print("{s}Error: repo_crawler read stdout failed for '{s}': {any}{s}\n", .{ ansi.Color.BOLD_RED, label, e, ansi.Color.RESET });
                _ = child.wait() catch {};
                return;
            };
            defer allocator.free(out);
            const errbuf = child.stderr.?.reader().readAllAlloc(allocator, 256 * 1024) catch null;
            defer if (errbuf) |b| allocator.free(b);
            const term = child.wait() catch |e| {
                print("{s}Error: repo_crawler wait failed for '{s}': {any}{s}\n", .{ ansi.Color.BOLD_RED, label, e, ansi.Color.RESET });
                return;
            };
            if (!(term == .Exited and term.Exited == 0)) {
                print("{s}Warning: repo_crawler '{s}' exited with non-zero status{s}\n", .{ ansi.Color.BOLD_YELLOW, label, ansi.Color.RESET });
                return;
            }
            var it = std.mem.splitScalar(u8, out, '\n');
            while (it.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                const copy = sink.allocator.dupe(u8, trimmed) catch return;
                sink.metadata.append(copy) catch return;
                sink.repository_count += 1; // approximation
            }
            }
        };

        // Detect available package manager by presence of binary.
        const pm = detectPkgManager(self.allocator) catch null;
        if (pm) |name| {
            defer self.allocator.free(name);
            if (std.mem.eql(u8, name, "apt")) {
                // Prefer reading sources; fall back to apt-cache policy
                // Combine outputs to be resilient
                Helper.runAndCollect(self.allocator, &[_][]const u8{ "/bin/sh", "-c", "grep -h ^deb -r /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null" }, "grep sources", snapshots);
                Helper.runAndCollect(self.allocator, &[_][]const u8{ "apt-cache", "policy" }, "apt-cache policy", snapshots);
            } else if (std.mem.eql(u8, name, "dnf")) {
                Helper.runAndCollect(self.allocator, &[_][]const u8{ "dnf", "repolist", "-v" }, "dnf repolist -v", snapshots);
            } else if (std.mem.eql(u8, name, "pacman")) {
                Helper.runAndCollect(self.allocator, &[_][]const u8{ "pacman", "-Sl" }, "pacman -Sl", snapshots);
            } else if (std.mem.eql(u8, name, "zypper")) {
                Helper.runAndCollect(self.allocator, &[_][]const u8{ "zypper", "lr", "-u" }, "zypper lr -u", snapshots);
            } else {
                // Unknown manager: nothing to do
            }
        } else {
            print("repo_crawler: no supported package manager detected\n", .{});
        }

        // We do not compute package_count here; leave for other parts of the system.
    }

    fn detectPkgManager(allocator: Allocator) ![]u8 {
        const candidates = [_][]const u8{ "apt", "dnf", "pacman", "zypper" };
        for (candidates) |bin| {
            var child = std.process.Child.init(&[_][]const u8{ "which", bin }, allocator);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;
            child.spawn() catch continue;
            const term = child.wait() catch continue;
            if (term == .Exited and term.Exited == 0) {
                return allocator.dupe(u8, bin);
            }
        }
        return error.NotFound;
    }
};
