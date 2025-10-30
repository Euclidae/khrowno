// handles packages from third-party sources (AUR, PPAs, COPR, etc)

const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.hash_map.HashMap;
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;
const distro = @import("../system/distro.zig");

pub const PackageSource = enum {
    official,
    aur, // arch user repo - pain to deal with
    copr, // fedora community repos
    ppa, // ubuntu personal package archives
    flatpak,
    snap, // ugh. everything wrong with this garbage. Chowed 20 gb of my data. auto updates, slow af, unntrollable . all around hsitty
    // fuck you snap.
    third_party,
};

pub const PackageInfo = struct {
    name: String,
    version: String,
    source: PackageSource,
    repository: ?String,
    dependencies: ArrayList(String),
    conflicts: ArrayList(String),
    provides: ArrayList(String),

    allocator: Allocator,

    pub fn init(allocator: Allocator, name: String, version: String, source: PackageSource) !PackageInfo {
        return PackageInfo{
            .name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .source = source,
            .repository = null,
            .dependencies = ArrayList(String).init(allocator),
            .conflicts = ArrayList(String).init(allocator),
            .provides = ArrayList(String).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *PackageInfo) void {
        self.allocator.free(self.name);
        self.allocator.free(self.version);
        if (self.repository) |repo| {
            self.allocator.free(repo);
        }
        for (self.dependencies.items) |dep| {
            self.allocator.free(dep);
        }
        self.dependencies.deinit();
        for (self.conflicts.items) |conf| {
            self.allocator.free(conf);
        }
        self.conflicts.deinit();
        for (self.provides.items) |prov| {
            self.allocator.free(prov);
        }
        self.provides.deinit();
    }
};

pub const ConflictResolution = enum {
    prefer_newer,
    prefer_official,
    prefer_existing,
    manual,
};

pub const UnifiedPackageResolver = struct {
    allocator: Allocator,
    distro_info: distro.DistroInfo,
    package_cache: HashMap(String, PackageInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    conflict_strategy: ConflictResolution,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const distro_info = try distro.detectDistro(allocator);

        return Self{
            .allocator = allocator,
            .distro_info = distro_info,
            .package_cache = HashMap(String, PackageInfo, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .conflict_strategy = .prefer_official,
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.package_cache.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.package_cache.deinit();
        self.distro_info.deinit(self.allocator);
    }

    pub fn resolvePackage(self: *Self, package_name: String) !?*const PackageInfo {
        if (self.package_cache.getPtr(package_name)) |ptr| {
            return ptr;
        }

        const pkg_info_opt = try self.queryPackageInfo(package_name);
        if (pkg_info_opt) |info| {
            const key = try self.allocator.dupe(u8, package_name);
            try self.package_cache.put(key, info);
            return self.package_cache.getPtr(package_name);
        }

        return null;
    }

    fn queryPackageInfo(self: *Self, package_name: String) !?PackageInfo {
        const cmd = switch (self.distro_info.distro_type) {
            .fedora => try std.fmt.allocPrint(self.allocator, "dnf info {s}", .{package_name}),
            .ubuntu, .debian, .mint => try std.fmt.allocPrint(self.allocator, "apt show {s}", .{package_name}),
            .arch => try std.fmt.allocPrint(self.allocator, "pacman -Si {s}", .{package_name}),
            .nixos => try std.fmt.allocPrint(self.allocator, "nix-env -qa {s}", .{package_name}),
            else => return null,
        };
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        _ = try child.wait();

        return try self.parsePackageInfo(package_name, stdout);
    }

    fn parsePackageInfo(self: *Self, package_name: String, output: String) !?PackageInfo {
        var lines = std.mem.splitScalar(u8, output, '\n');
        var version: ?String = null;
        const source = PackageSource.official;

        while (lines.next()) |line| {
            const trimmed = types.trim(line);
            if (trimmed.len == 0) continue;

            if (std.mem.startsWith(u8, trimmed, "Version:") or std.mem.startsWith(u8, trimmed, "version")) {
                const parts = std.mem.splitScalar(u8, trimmed, ':');
                _ = parts.next();
                if (parts.next()) |ver| {
                    version = types.trim(ver);
                }
            }
        }

        if (version) |ver| {
            return try PackageInfo.init(self.allocator, package_name, ver, source);
        }

        return null;
    }

    pub fn resolveAURPackage(self: *Self, package_name: String) !?PackageInfo {
        if (self.distro_info.distro_type != .arch) {
            return null;
        }

        const cmd = try std.fmt.allocPrint(self.allocator, "yay -Si {s} 2>/dev/null || paru -Si {s} 2>/dev/null", .{ package_name, package_name });
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        _ = try child.wait();

        if (stdout.len > 0) {
            var pkg_info = try self.parsePackageInfo(package_name, stdout);
            if (pkg_info) |*info| {
                info.source = .aur;
            }
            return pkg_info;
        }

        return null;
    }

    pub fn resolveCOPRPackage(self: *Self, package_name: String, copr_repo: String) !?PackageInfo {
        if (self.distro_info.distro_type != .fedora) {
            return null;
        }

        const cmd = try std.fmt.allocPrint(self.allocator, "dnf --enablerepo={s} info {s}", .{ copr_repo, package_name });
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        _ = try child.wait();

        if (stdout.len > 0) {
            var pkg_info = try self.parsePackageInfo(package_name, stdout);
            if (pkg_info) |*info| {
                info.source = .copr;
                info.repository = try self.allocator.dupe(u8, copr_repo);
            }
            return pkg_info;
        }

        return null;
    }

    pub fn resolvePPAPackage(self: *Self, package_name: String, ppa: String) !?PackageInfo {
        if (self.distro_info.distro_type != .ubuntu and self.distro_info.distro_type != .mint) {
            return null;
        }

        const cmd = try std.fmt.allocPrint(self.allocator, "apt-cache policy {s}", .{package_name});
        defer self.allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "sh", "-c", cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        _ = try child.wait();

        if (std.mem.indexOf(u8, stdout, ppa) != null) {
            var pkg_info = try self.parsePackageInfo(package_name, stdout);
            if (pkg_info) |*info| {
                info.source = .ppa;
                info.repository = try self.allocator.dupe(u8, ppa);
            }
            return pkg_info;
        }

        return null;
    }

    pub fn resolveConflicts(self: *Self, packages: []PackageInfo) !ArrayList(PackageInfo) {
        var resolved = ArrayList(PackageInfo).init(self.allocator);
        var seen = HashMap(String, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer seen.deinit();

        for (packages) |pkg| {
            if (seen.contains(pkg.name)) {
                continue;
            }

            var selected = pkg;
            for (packages) |other| {
                if (std.mem.eql(u8, pkg.name, other.name) and !std.mem.eql(u8, pkg.version, other.version)) {
                    selected = try self.selectBetterPackage(pkg, other);
                }
            }

            try seen.put(try self.allocator.dupe(u8, selected.name), {});
            try resolved.append(selected);
        }

        return resolved;
    }

    fn selectBetterPackage(self: *Self, pkg1: PackageInfo, pkg2: PackageInfo) !PackageInfo {
        return switch (self.conflict_strategy) {
            .prefer_official => if (pkg1.source == .official) pkg1 else pkg2, // trust distro repos over third-party
            .prefer_newer => if (try self.compareVersions(pkg1.version, pkg2.version) > 0) pkg1 else pkg2,
            .prefer_existing => pkg1, // keep first match
            .manual => pkg1, // user will decide later
        };
    }

    fn compareVersions(_: *Self, v1: String, v2: String) !i32 {
        var parts1 = std.mem.splitScalar(u8, v1, '.');
        var parts2 = std.mem.splitScalar(u8, v2, '.');

        while (true) {
            const p1 = parts1.next();
            const p2 = parts2.next();

            if (p1 == null and p2 == null) return 0; // equal
            if (p1 == null) return -1; // v1 shorter = older
            if (p2 == null) return 1; // v2 shorter = older

            const n1 = std.fmt.parseInt(u32, p1.?, 10) catch 0;
            const n2 = std.fmt.parseInt(u32, p2.?, 10) catch 0;

            if (n1 > n2) return 1;
            if (n1 < n2) return -1;
        }
    }
};
