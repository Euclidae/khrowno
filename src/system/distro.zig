const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;

// distro detection is harder than expected - every linux does this differently

// /etc/os-release is supposedly standard but:
// - fedora/ubuntu/mint: use VERSION_ID field
// - debian: has its own /etc/debian_version file
// - arch: rolling release, doesn't care about versions
// tested on fedora (daily driver) and ubuntu/mint VMs

// IMPORTANT: mint must be checked before ubuntu!
// mint's os-release contains "ubuntu" string so checking ubuntu first will match incorrectly
// spent way too long debugging this in the mint VM

pub const DistroType = enum {
    fedora,
    ubuntu,
    debian,
    arch,
    mint,
    nixos,
    opensuse_leap, // stable release, like ubuntu LTS
    opensuse_tumbleweed, // rolling release, like arch
    unknown,

    pub fn toString(self: DistroType) String {
        return switch (self) {
            .fedora => "Fedora",
            .ubuntu => "Ubuntu",
            .debian => "Debian",
            .arch => "Arch Linux",
            .mint => "Linux Mint",
            .nixos => "NixOS",
            .opensuse_leap => "openSUSE Leap",
            .opensuse_tumbleweed => "openSUSE Tumbleweed",
            .unknown => "Unknown",
        };
    }

    pub fn getPackageManager(self: DistroType) String {
        return switch (self) {
            .fedora => "dnf",
            .ubuntu, .debian, .mint => "apt",
            .arch => "pacman",
            .nixos => "nix-env",
            .opensuse_leap, .opensuse_tumbleweed => "zypper", // both use zypper
            .unknown => "unknown",
        };
    }
};

pub const PackageManager = struct {
    name: String,
    list_command: String,
    install_command: String,

    const Self = @This();

    pub fn forDistro(distro: DistroType) Self {
        return switch (distro) {
            .fedora => Self{
                .name = "dnf",
                .list_command = "dnf list installed",
                .install_command = "dnf install",
            },
            .ubuntu, .debian, .mint => Self{
                .name = "apt",
                .list_command = "apt list --installed",
                .install_command = "apt install",
            },
            .arch => Self{
                .name = "pacman",
                .list_command = "pacman -Q",
                .install_command = "pacman -S",
            },
            .nixos => Self{
                .name = "nix-env",
                .list_command = "nix-env -q",
                .install_command = "nix-env -i",
            },
            .opensuse_leap, .opensuse_tumbleweed => Self{
                .name = "zypper",
                .list_command = "zypper search --installed-only",
                .install_command = "zypper install",
            },
            .unknown => Self{
                .name = "unknown",
                .list_command = "echo 'Unknown package manager'",
                .install_command = "echo 'Cannot install packages'",
            },
        };
    }

    pub fn isAvailable(self: *const Self) bool {
        const cmd = std.fmt.allocPrint(std.heap.page_allocator, "which {s}", .{self.name}) catch return false;
        defer std.heap.page_allocator.free(cmd);

        var child = std.process.Child.init(&[_]String{ "/bin/sh", "-c", cmd }, std.heap.page_allocator);
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;

        // kept trying if (child.spawn()) |_| {} like it returns ?void but it's !void (error union)
        // zig error handling != exceptions, need explicit try/catch
        child.spawn() catch return false;
        const term = child.wait() catch return false;

        // was doing: term == .Exited and term.Exited == 0
        // sometimes compiled, sometimes didn't, depending on zig version?
        // proper way should be to match on the union and capture the code
        return switch (term) {
            .Exited => |code| code == 0,
            else => false,
        };
    }

    pub fn getUpdateCommand(self: *const Self) String {
        if (std.mem.eql(u8, self.name, "dnf")) return "dnf update";
        if (std.mem.eql(u8, self.name, "apt")) return "apt update";
        if (std.mem.eql(u8, self.name, "pacman")) return "pacman -Syu";
        if (std.mem.eql(u8, self.name, "nix-env")) return "nix-channel --update";
        return "echo 'Unknown update command'";
    }
};

pub const DistroInfo = struct {
    name: String,
    version: String,
    codename: ?String,
    distro_type: DistroType,
    package_manager: String,
    kernel_version: String,

    const Self = @This();

    pub fn deinit(self: Self, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        if (self.codename) |codename| {
            allocator.free(codename);
        }
        allocator.free(self.package_manager);
        allocator.free(self.kernel_version);
    }
};

pub const DistroFeatures = struct {
    distro: DistroType,

    const Self = @This();

    pub fn init(distro: DistroType) Self {
        return Self{ .distro = distro };
    }

    pub fn supportsFlatpak(self: *const Self) bool {
        // flatpak works on most distros but nixos does things a little differently iirc
        return switch (self.distro) {
            .fedora, .ubuntu, .debian, .mint => true,
            .arch => true,
            .opensuse_leap, .opensuse_tumbleweed => true,
            .nixos => false, // nix handles things differently
            .unknown => false,
        };
    }

    pub fn getRecommendedBackupStrategy(self: *const Self) String {
        return switch (self.distro) {
            .fedora => "standard",
            .ubuntu, .mint => "standard",
            .debian => "minimal",
            .arch => "comprehensive",
            .nixos => "minimal", // nix already has declarative config
            .opensuse_leap => "standard",
            .opensuse_tumbleweed => "comprehensive", // rolling release needs more backups
            .unknown => "standard",
        };
    }
};

pub fn detectDistro(allocator: std.mem.Allocator) !DistroInfo {
    const distro_type = detectDistroType();

    var child = std.process.Child.init(&[_]String{ "uname", "-r" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const kernel_output = try child.stdout.?.reader().readAllAlloc(allocator, 1024);
    defer allocator.free(kernel_output);
    _ = try child.wait();

    const kernel_version = std.mem.trim(u8, kernel_output, " \n\r\t");

    return DistroInfo{
        .name = try allocator.dupe(u8, distro_type.toString()),
        .version = try detectVersion(allocator, distro_type),
        .codename = null, // TODO: try to parse codenames from os-release
        .distro_type = distro_type,
        .package_manager = try allocator.dupe(u8, distro_type.getPackageManager()),
        .kernel_version = try allocator.dupe(u8, kernel_version),
    };
}

fn detectVersion(allocator: Allocator, distro_type: DistroType) !String {
    return switch (distro_type) {
        .fedora => detectFedoraVersion(allocator),
        .ubuntu => detectUbuntuVersion(allocator),
        .debian => detectDebianVersion(allocator),
        .arch => detectArchVersion(allocator),
        .mint => detectMintVersion(allocator),
        .nixos => detectNixOSVersion(allocator),
        .opensuse_leap, .opensuse_tumbleweed => detectOpenSuseVersion(allocator),
        .unknown => allocator.dupe(u8, "unknown"),
    };
}

fn detectFedoraVersion(allocator: Allocator) !String {
    const content = fs.cwd().readFileAlloc(allocator, "/etc/fedora-release", 64) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(content);

    // format: "Fedora release 41 (Fourty One)"
    if (std.mem.indexOf(u8, content, "release ")) |start| {
        const version_start = start + 8;
        if (std.mem.indexOf(u8, content[version_start..], " ")) |end| {
            return allocator.dupe(u8, content[version_start .. version_start + end]);
        }
    }

    return allocator.dupe(u8, "unknown");
}

fn detectOpenSuseVersion(allocator: Allocator) !String {
    const content = fs.cwd().readFileAlloc(allocator, "/etc/os-release", 1024) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VERSION_ID=")) {
            const version = std.mem.trim(u8, line[11..], "\"");
            return allocator.dupe(u8, version);
        }
    }

    return allocator.dupe(u8, "unknown");
}

fn detectUbuntuVersion(allocator: Allocator) !String {
    const content = fs.cwd().readFileAlloc(allocator, "/etc/os-release", 1024) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VERSION_ID=")) {
            const version = std.mem.trim(u8, line[11..], "\"");
            return allocator.dupe(u8, version);
        }
    }

    return allocator.dupe(u8, "unknown");
}

fn detectDebianVersion(allocator: Allocator) !String {
    // debian predates os-release standard, still uses legacy /etc/debian_version
    const content = fs.cwd().readFileAlloc(allocator, "/etc/debian_version", 32) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(content);

    const version = std.mem.trim(u8, content, " \n\r\t");
    return allocator.dupe(u8, version);
}

fn detectArchVersion(allocator: Allocator) !String {
    // Arch is rolling release, no traditional version numbers
    return allocator.dupe(u8, "rolling");
}

fn detectMintVersion(allocator: Allocator) !String {
    // VERSION_ID= in os-release
    const content = fs.cwd().readFileAlloc(allocator, "/etc/os-release", 1024) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VERSION_ID=")) {
            const version = std.mem.trim(u8, line[11..], "\"");
            return allocator.dupe(u8, version);
        }
    }

    return allocator.dupe(u8, "unknown");
}

fn detectNixOSVersion(allocator: Allocator) !String {
    const content = fs.cwd().readFileAlloc(allocator, "/etc/os-release", 1024) catch {
        return allocator.dupe(u8, "unknown");
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "VERSION_ID=")) {
            const version = std.mem.trim(u8, line[11..], "\"");
            return allocator.dupe(u8, version);
        }
    }

    return allocator.dupe(u8, "unknown");
}

pub fn detectDistroType() DistroType {
    print("Detecting Linux distribution...\n", .{});

    // check fedora first
    if (fs.accessAbsolute("/etc/fedora-release", .{})) |_| {
        print("Detected: Fedora\n", .{});
        return .fedora;
    } else |_| {}

    // ubuntu has lsb-release file
    if (fs.accessAbsolute("/etc/lsb-release", .{})) |_| {
        const content = fs.cwd().readFileAlloc(std.heap.page_allocator, "/etc/lsb-release", 1024) catch return .unknown;
        defer std.heap.page_allocator.free(content);

        if (std.mem.indexOf(u8, content, "Ubuntu") != null) {
            print("Detected: Ubuntu\n", .{});
            return .ubuntu;
        }
    } else |_| {}

    if (fs.accessAbsolute("/etc/debian_version", .{})) |_| {
        print("Detected: Debian\n", .{});
        return .debian;
    } else |_| {}

    if (fs.accessAbsolute("/etc/arch-release", .{})) |_| {
        print("Detected: Arch Linux\n", .{});
        return .arch;
    } else |_| {}

    // fallback to os-release which most distros have now
    if (fs.accessAbsolute("/etc/os-release", .{})) |_| {
        const content = fs.cwd().readFileAlloc(std.heap.page_allocator, "/etc/os-release", 2048) catch return .unknown;
        defer std.heap.page_allocator.free(content);

        // mint needs to be checked before ubuntu since its based on it
        if (std.mem.indexOf(u8, content, "linuxmint") != null or std.mem.indexOf(u8, content, "Linux Mint") != null) {
            print("Detected: Linux Mint (via os-release)\n", .{});
            return .mint;
        } else if (std.mem.indexOf(u8, content, "opensuse") != null or std.mem.indexOf(u8, content, "openSUSE") != null or std.mem.indexOf(u8, content, "suse") != null) {
            // check if it's Tumbleweed (rolling) or Leap (stable)
            if (std.mem.indexOf(u8, content, "tumbleweed") != null or std.mem.indexOf(u8, content, "Tumbleweed") != null) {
                print("Detected: openSUSE Tumbleweed (via os-release)\n", .{});
                return .opensuse_tumbleweed;
            } else {
                // default to Leap if not explicitly Tumbleweed
                print("Detected: openSUSE Leap (via os-release)\n", .{});
                return .opensuse_leap;
            }
        } else if (std.mem.indexOf(u8, content, "nixos") != null or std.mem.indexOf(u8, content, "NixOS") != null) {
            print("Detected: NixOS (via os-release)\n", .{});
            return .nixos;
        } else if (std.mem.indexOf(u8, content, "fedora") != null) {
            print("Detected: Fedora (via os-release)\n", .{});
            return .fedora;
        } else if (std.mem.indexOf(u8, content, "ubuntu") != null) {
            print("Detected: Ubuntu (via os-release)\n", .{});
            return .ubuntu;
        } else if (std.mem.indexOf(u8, content, "debian") != null) {
            print("Detected: Debian (via os-release)\n", .{});
            return .debian;
        } else if (std.mem.indexOf(u8, content, "arch") != null or std.mem.indexOf(u8, content, "EndeavourOS") != null or std.mem.indexOf(u8, content, "endeavouros") != null) {
            // endeavour is arch-based, treat it as arch
            print("Detected: Arch Linux (via os-release)\n", .{});
            return .arch;
        }
    } else |_| {}

    print("Could not detect distribution\n", .{});
    return .unknown;
}

pub fn getDistroFeatures() DistroFeatures {
    const distro_type = detectDistroType();
    return DistroFeatures.init(distro_type);
}

pub fn exportPackages(allocator: std.mem.Allocator, output_dir: String) !void {
    const info = try detectDistro(allocator);
    defer info.deinit(allocator);
    const pkg_mgr = PackageManager.forDistro(info.distro_type);

    print("Exporting packages using {s}...\n", .{pkg_mgr.name});

    const packages_file = try std.fmt.allocPrint(allocator, "{s}/packages-{s}.txt", .{ output_dir, pkg_mgr.name });
    defer allocator.free(packages_file);

    var child = std.process.Child.init(&[_]String{ "/bin/sh", "-c", pkg_mgr.list_command }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();

    // 10MB buffer - my fedora install has ~1500 packages, output is ~200KB
    const stdout = try child.stdout.?.readToEndAlloc(allocator, 10 * 1024 * 1024);
    defer allocator.free(stdout);

    const stderr = try child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const exit_code = try child.wait();

    if (exit_code != .Exited or exit_code.Exited != 0) {
        print("Package export failed: {s}\n", .{stderr});
        return;
    }

    const file = try fs.createFileAbsolute(packages_file, .{});
    defer file.close();

    try file.writeAll(stdout);

    print("Packages exported to: {s}\n", .{packages_file});

    try exportFlatpakPackages(allocator, output_dir);
}

fn exportFlatpakPackages(allocator: std.mem.Allocator, output_dir: String) !void {
    // check if flatpak exists - not all distros have it by default
    var child = std.process.Child.init(&[_]String{ "which", "flatpak" }, allocator);

    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    try child.spawn();
    const exit_code = try child.wait();

    if (exit_code != .Exited or exit_code.Exited != 0) {
        print("Flatpak not available\n", .{});
        return;
    }

    print("Exporting Flatpak packages...\n", .{});

    const flatpak_file = try std.fmt.allocPrint(allocator, "{s}/packages-flatpak.txt", .{output_dir});
    defer allocator.free(flatpak_file);

    // --app flag gets just applications, not runtimes
    var flatpak_child = std.process.Child.init(&[_]String{ "flatpak", "list", "--app" }, allocator);

    flatpak_child.stdout_behavior = .Pipe;
    flatpak_child.stderr_behavior = .Pipe;

    try flatpak_child.spawn();

    const stdout = try flatpak_child.stdout.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stdout);

    const stderr = try flatpak_child.stderr.?.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(stderr);

    const flatpak_exit = try flatpak_child.wait();

    if (flatpak_exit != .Exited or flatpak_exit.Exited != 0) {
        print("Flatpak export failed: {s}\n", .{stderr});
        return;
    }

    const file = try fs.createFileAbsolute(flatpak_file, .{});
    defer file.close();

    try file.writeAll(stdout);

    print("Flatpak packages exported\n", .{});
}

pub fn restorePackages(allocator: std.mem.Allocator, backup_dir: String) !void {
    const current_info = try detectDistro(allocator);
    defer current_info.deinit(allocator);
    const pkg_mgr = PackageManager.forDistro(current_info.distro_type);

    print("Restoring packages using {s}...\n", .{pkg_mgr.name});

    const packages_file = try std.fmt.allocPrint(allocator, "{s}/packages-{s}.txt", .{ backup_dir, pkg_mgr.name });
    defer allocator.free(packages_file);

    // check if we have a package file for this distro
    fs.accessAbsolute(packages_file, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            print("No package file found for {s}\n", .{pkg_mgr.name});
            // TODO: cross-distro package mapping would be useful here
            return;
        },
        else => return err,
    };

    print("Found package list: {s}\n", .{packages_file});

    const content = try fs.cwd().readFileAlloc(allocator, packages_file, 10 * 1024 * 1024);
    defer allocator.free(content);

    // not auto-installing for safety - show user what needs installing
    print("\nPreparing package restoration...\n", .{});
    print("  Automatic installation requires sudo privileges.\n", .{});
    print("  Packages will be listed for manual installation.\n\n", .{});

    var package_list = ArrayList(String).init(allocator);
    defer package_list.deinit();

    // parse package names - just grab first token from each line
    // format varies (pacman: "pkg version", apt: "pkg/release version")
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0 and !std.mem.startsWith(u8, trimmed, "#")) {
            var parts = std.mem.splitScalar(u8, trimmed, ' ');
            if (parts.next()) |pkg_name| {
                if (pkg_name.len > 0) {
                    try package_list.append(pkg_name);
                }
            }
        }
    }

    print("Packages to install:\n", .{});
    for (package_list.items, 0..) |pkg, i| {
        if (i < 10) {
            print("  • {s}\n", .{pkg});
        }
    }
    if (package_list.items.len > 10) {
        print("  ... and {d} more\n", .{package_list.items.len - 10});
    }

    print("\nTo install all packages, run:\n", .{});
    print("  sudo {s} ", .{pkg_mgr.install_command});
    for (package_list.items, 0..) |pkg, i| {
        if (i < 5) {
            print("{s} ", .{pkg});
        }
    }
    if (package_list.items.len > 5) {
        print("...");
    }
    print("\n\nPackage list saved in: {s}\n", .{packages_file});
}
