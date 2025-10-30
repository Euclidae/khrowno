const std = @import("std");
const print = std.debug.print;
const fs = std.fs;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator; // The idea of allocators is still a little weird if you ask me. But I guess that's why no one asks me.

const types = @import("../utils/types.zig");
const ansi = @import("../utils/ansi.zig");
const String = types.String;
const Path = types.Path;
const Result = types.Result;
const Option = types.Option;
const Timestamp = types.Timestamp;
const startsWith = types.startsWith;
const endsWith = types.endsWith;
const trim = types.trim;

// System and platform detection
const distro = @import("../system/distro.zig");
const security = @import("../security/crypto.zig");
const network = @import("../utils/network.zig");

// different distros = different package formats, why linux backup is annoying
const package_resolver = @import("package_resolver.zig");
const unified_pkg = @import("unified_pkg_resolver.zig");
const dep_graph = @import("dep_graph.zig");
const repo_crawler = @import("../utils/repo_crawler.zig");
const khr_format = @import("khr_format.zig");

const parallel_backup = @import("parallel_backup.zig");
const keyring = @import("../security/keyring.zig");
const streaming_crypto = @import("../security/streaming_crypto.zig");
const deduplication = @import("deduplication.zig");

// Init system handlers
const systemd = @import("../system/init_systems/systemd.zig");
const openrc = @import("../system/init_systems/openrc.zig");
const runit = @import("../system/init_systems/runit.zig");

// init system support: systemd, openrc, runit

// Desktop environment handlers
const gnome = @import("../system/desktop_environments/gnome.zig");
const kde = @import("../system/desktop_environments/kde.zig");
const i3_de = @import("../system/desktop_environments/i3.zig");
const xfce = @import("../system/desktop_environments/xfce.zig");

const flatpak_support = @import("flatpak_support.zig");

const builtin = @import("builtin");

const DEFAULT_BACKUP_PATHS = [_]String{
    "Documents",             "Desktop",

    // dev directories - everyone organizes code differently so just check common names
    "Projects",              "Code",
    "Repos",                 "Workspace",
    "Work",                  "Dev",
    "Development",

    // The important stuff - your configs and dotfiles.
    // Lose these and you'll be reconfiguring everything from scratch. Not fun.
              ".config",
    ".local/share",          ".ssh",
    ".gnupg",                ".bashrc",
    ".zshrc",                ".bash_profile",
    ".profile",              ".vimrc",
    ".gitconfig",

    // app settings - browsers, email, etc (not cache files, those are huge)
               ".mozilla",
    ".thunderbird",          ".config/google-chrome",
    ".config/chromium",      ".config/firefox",
    ".config/brave-browser", ".config/keepassxc",
    ".config/bitwarden",     ".config/1password",
    ".config/code",          ".config/vscode",
    ".config/atom",          ".config/sublime-text",
    ".config/nvim",          ".vim",
    ".emacs.d",              ".config/systemd",
    ".config/pulse",         ".config/alsa",
    ".config/discord",       ".config/slack",
    ".config/telegram",      ".config/spotify",
    ".config/vlc",           ".config/obs-studio",
};

fn detectHostnameAlloc(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, if (builtin.os.tag == .windows) "COMPUTERNAME" else "HOSTNAME")) |name| {
        return name;
    } else |_| {}
    return allocator.dupe(u8, "unknown");
}

fn detectUsernameAlloc(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, if (builtin.os.tag == .windows) "USERNAME" else "USER")) |u| {
        return u;
    } else |_| {}
    return allocator.dupe(u8, "user");
}

fn detectHomeDirAlloc(allocator: Allocator) ![]u8 {
    if (std.process.getEnvVarOwned(allocator, "HOME")) |h| {
        return h;
    } else |_| {}
    if (std.process.getEnvVarOwned(allocator, "USERPROFILE")) |up| {
        return up;
    } else |_| {}
    return allocator.dupe(u8, "/");
}

const EXTENDED_BACKUP_PATHS = [_]String{
    // Desktop environment configs
    ".config/kde",        ".config/gnome",   ".config/xfce",          ".config/i3",
    ".config/qt5ct",      ".config/qt6ct",

    // IDE suites
      ".config/jetbrains",     ".config/intellij",
    ".config/pycharm",    ".config/clion",   ".config/webstorm",

    // Gaming and runtimes
         ".config/steam",
    ".local/share/Steam", ".config/lutris",  ".local/share/lutris",   ".config/wine",

    // Tools
    ".config/authy",      ".config/yubikey", ".config/gnome-keyring", ".config/htop",
    ".config/neofetch",   ".config/ranger",  ".config/tmux",          ".config/screen",

    // Heavy media dirs included only in comprehensive+
    "Pictures",           "Music",           "Videos",
};

pub const BackupStrategy = enum {
    minimal,
    standard,
    comprehensive,
    paranoid,

    // strategies: minimal=configs, standard=docs+configs, comprehensive=+media, paranoid=everything
    pub fn getDescription(self: BackupStrategy) String {
        return switch (self) {
            .minimal => "Minimal (critical configs + keys)",
            .standard => "Standard (Documents + dev dirs + configs; excludes media)",
            .comprehensive => "Comprehensive (standard + heavy media and extras)",
            .paranoid => "Paranoid (complete snapshot)",
        };
    }

    pub fn getPaths(self: BackupStrategy) []const String {
        return switch (self) {
            .minimal => &[_]String{ ".config", ".ssh", ".bashrc", ".zshrc" },
            .standard => &DEFAULT_BACKUP_PATHS,
            .comprehensive, .paranoid => &(DEFAULT_BACKUP_PATHS ++ EXTENDED_BACKUP_PATHS),
        };
    }

    pub fn includesDependencyAnalysis(self: BackupStrategy) bool {
        return switch (self) {
            .minimal, .standard => false,
            .comprehensive, .paranoid => true,
        };
    }

    pub fn includesRepoSnapshots(self: BackupStrategy) bool {
        return self == .paranoid;
    }
};

pub const BackupError = error{
    FileNotFound,
    PermissionDenied,
    InsufficientSpace,
    CorruptedBackup,
    NetworkError,
    EncryptionFailed,
    AuthenticationFailed,
    UserNotFound,
    InvalidPassword,
    OutOfMemory,
    SecurityInitFailed,
    PackageResolutionFailed,
    RepositoryAccessFailed,
    UserAborted,
    DiskSpaceInsufficient,
};

const BackupMetadata = struct {
    version: String,
    timestamp: types.Timestamp,
    hostname: String,
    username: String,
    distro_info: distro.DistroInfo,
    file_count: u32,
    total_size: types.FileSize,
    backup_strategy: BackupStrategy,
    security_level: u8,
    encryption_algorithm: String,
    key_derivation: String,
    integrity_verified: bool,
    total_packages: u32,
    resolved_packages: u32,
    unresolved_packages: u32,
    cross_platform_compatible: bool,
    created_online: bool,
    repo_snapshot_included: bool,
    user_credentials: ?UserCredentials,

    const Self = @This();

    pub fn init(allocator: Allocator, strategy: BackupStrategy) !Self {
        // system metadata for backup header
        const hostname = try detectHostnameAlloc(allocator);
        errdefer allocator.free(hostname);
        const username = try detectUsernameAlloc(allocator);
        errdefer allocator.free(username);

        const distro_info = if (builtin.os.tag == .linux) blk: {
            break :blk try distro.detectDistro(allocator);
        } else blk: {
            break :blk distro.DistroInfo{
                .name = try allocator.dupe(u8, "unknown"),
                .version = try allocator.dupe(u8, "unknown"),
                .codename = null,
                .distro_type = .unknown,
                .package_manager = try allocator.dupe(u8, "unknown"),
                .kernel_version = try allocator.dupe(u8, "unknown"),
            };
        };

        return Self{
            .version = "0.3.0",
            .timestamp = std.time.timestamp(),
            .hostname = hostname,
            .username = username,
            .distro_info = distro_info,
            .file_count = 0,
            .total_size = 0,
            .backup_strategy = strategy,
            .security_level = 3,
            .encryption_algorithm = "ChaCha20-Poly1305",
            .key_derivation = "Argon2id",
            .integrity_verified = false,
            .total_packages = 0,
            .resolved_packages = 0,
            .unresolved_packages = 0,
            .cross_platform_compatible = false,
            .created_online = network.isOnline(),
            .repo_snapshot_included = false,
            .user_credentials = null,
        };
    }

    pub fn deinit(self: Self, allocator: Allocator) void {
        allocator.free(self.hostname);
        allocator.free(self.username);
        self.distro_info.deinit(allocator);
    }
};

pub const ProgressCallback = *const fn (operation: String, current: usize, total: usize) void;

pub const BackupEntry = struct {
    path: Path,
    size: types.FileSize,
    mode: types.FileMode,
    mtime: types.Timestamp,
    is_dir: bool,
    data: ?String,

    pub fn deinit(self: *BackupEntry, allocator: Allocator) void {
        self.path.deinit(allocator);
        if (self.data) |data| {
            allocator.free(data);
        }
    }
};

pub const BackupOptions = struct {
    strategy: BackupStrategy,
    output_path: String,
    password: ?String,
    use_parallel: bool,
    thread_count: usize,
    backup_init_system: bool,
    backup_desktop_env: bool,
    use_keyring: bool,

    pub fn default() BackupOptions {
        // 4 threads works well on most machines (tested 2-16 cores). I run an AMD Ryzen 9 5600HX if you are curious
        return BackupOptions{
            .strategy = .standard,
            .output_path = "backup.khr",
            .password = null,
            .use_parallel = true,
            .thread_count = 4, //Sweet spot
            .backup_init_system = true,
            .backup_desktop_env = true,
            .use_keyring = false, // experimental
        };
    }
};

pub const BackupEngine = struct {
    allocator: Allocator,
    security_context: ?*security.CryptoContext,
    package_resolver: ?*package_resolver.PackageResolver,
    unified_resolver: ?*unified_pkg.UnifiedPackageResolver,
    dependency_graph: ?*dep_graph.DependencyGraph,
    repo_crawler: ?*repo_crawler.RepoCrawler,
    keyring_mgr: ?*keyring.Keyring,
    parallel_engine: ?*parallel_backup.ParallelBackupEngine,
    dedup_db: ?*deduplication.DeduplicationDatabase,
    network_available: bool,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const sec_ctx: ?*security.CryptoContext = null;
        var pkg_resolver: ?*package_resolver.PackageResolver = null;
        var uni_resolver: ?*unified_pkg.UnifiedPackageResolver = null;
        var dep_graph_ptr: ?*dep_graph.DependencyGraph = null;
        var crawler: ?*repo_crawler.RepoCrawler = null;
        var keyring_ptr: ?*keyring.Keyring = null;

        const is_online = network.isOnline();
        if (is_online) {
            pkg_resolver = try allocator.create(package_resolver.PackageResolver);
            errdefer allocator.destroy(pkg_resolver.?);
            pkg_resolver.?.* = try package_resolver.PackageResolver.init(allocator);
            errdefer pkg_resolver.?.deinit();

            uni_resolver = try allocator.create(unified_pkg.UnifiedPackageResolver);
            errdefer allocator.destroy(uni_resolver.?);
            uni_resolver.?.* = try unified_pkg.UnifiedPackageResolver.init(allocator);
            errdefer uni_resolver.?.deinit();

            dep_graph_ptr = try allocator.create(dep_graph.DependencyGraph);
            errdefer allocator.destroy(dep_graph_ptr.?);
            dep_graph_ptr.?.* = dep_graph.DependencyGraph.init(allocator);
            errdefer dep_graph_ptr.?.deinit();

            crawler = try allocator.create(repo_crawler.RepoCrawler);
            errdefer allocator.destroy(crawler.?);
            crawler.?.* = try repo_crawler.RepoCrawler.init(allocator);
            errdefer crawler.?.deinit();
        }

        keyring_ptr = try allocator.create(keyring.Keyring);
        errdefer allocator.destroy(keyring_ptr.?);
        keyring_ptr.?.* = try keyring.Keyring.init(allocator);
        errdefer keyring_ptr.?.deinit();

        return Self{
            .allocator = allocator,
            .security_context = sec_ctx,
            .package_resolver = pkg_resolver,
            .unified_resolver = uni_resolver,
            .dependency_graph = dep_graph_ptr,
            .repo_crawler = crawler,
            .keyring_mgr = keyring_ptr,
            .parallel_engine = null,
            .dedup_db = null,
            .network_available = is_online,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.security_context) |ctx| {
            ctx.deinit();
            self.allocator.destroy(ctx);
        }
        if (self.package_resolver) |resolver| {
            resolver.deinit();
            self.allocator.destroy(resolver);
        }
        if (self.unified_resolver) |resolver| {
            resolver.deinit();
            self.allocator.destroy(resolver);
        }
        if (self.dependency_graph) |graph| {
            graph.deinit();
            self.allocator.destroy(graph);
        }
        if (self.repo_crawler) |crawler| {
            crawler.deinit();
            self.allocator.destroy(crawler);
        }
        if (self.keyring_mgr) |mgr| {
            mgr.deinit();
            self.allocator.destroy(mgr);
        }
        if (self.parallel_engine) |engine| {
            engine.deinit();
            self.allocator.destroy(engine);
        }
        if (self.dedup_db) |db| {
            db.deinit();
            self.allocator.destroy(db);
        }
    }

    pub fn enableDeduplication(self: *Self, storage_path: String) !void {
        if (self.dedup_db == null) {
            const db = try self.allocator.create(deduplication.DeduplicationDatabase);
            db.* = try deduplication.DeduplicationDatabase.init(self.allocator, storage_path);
            self.dedup_db = db;
            print("Deduplication enabled at: {s}\n", .{storage_path});
        }
    }

    pub fn getDedupStats(self: *Self) ?deduplication.DeduplicationDatabase.DeduplicationStats {
        if (self.dedup_db) |db| {
            return db.getStats();
        }
        return null;
    }

    pub fn createBackup(self: *Self, strategy: BackupStrategy, output_path: String, password: ?String, progress_callback: ?ProgressCallback, compression: khr_format.CompressionType) !void {
        var metadata = try BackupMetadata.init(self.allocator, strategy);
        defer metadata.deinit(self.allocator);

        if (progress_callback) |callback| {
            callback("Initializing backup", 0, 100);
        }

        if (password != null) {
            if (self.security_context == null) {
                const ctx = try self.allocator.create(security.CryptoContext);
                ctx.* = security.CryptoContext.init(self.allocator);
                self.security_context = ctx;
            }
        }

        var system_analysis = try self.analyzeCurrentSystem(&metadata);
        defer system_analysis.deinit();

        if (progress_callback) |callback| {
            callback("Analyzing packages", 20, 100);
        }

        var package_manifest: ?PackageManifest = null;
        if (self.package_resolver != null and self.network_available) {
            package_manifest = try self.createPackageManifest(&metadata);
        }
        defer if (package_manifest) |*manifest| manifest.deinit();

        if (progress_callback) |callback| {
            callback("Preparing backup", 1, 5);
        }

        const backup_entries = try self.collectBackupData(strategy, &metadata, progress_callback);
        defer {
            for (backup_entries.items) |*entry| {
                entry.deinit(self.allocator);
            }
            backup_entries.deinit();
        }

        if (progress_callback) |callback| {
            callback("Creating repository snapshots", 70, 100);
        }

        var repo_snapshots: ?RepoSnapshots = null;
        if (strategy == .paranoid and self.repo_crawler != null) {
            repo_snapshots = try self.createRepoSnapshots();
        }
        defer if (repo_snapshots) |*snapshots| snapshots.deinit();

        try self.saveBackup(output_path, &metadata, backup_entries.items, package_manifest, repo_snapshots, password, progress_callback, compression);

        if (progress_callback) |callback| {
            callback("Backup complete", 100, 100);
        }

        print("{s}Backup created successfully!{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
        print("Strategy: {s}\n", .{strategy.getDescription()});
        print("Files backed up: {s}{d}{s}\n", .{ ansi.Color.CYAN, metadata.file_count, ansi.Color.RESET });
        print("Total size: {s}{d}{s} bytes\n", .{ ansi.Color.CYAN, metadata.total_size, ansi.Color.RESET });
        if (package_manifest) |_| {
            print("Packages resolved: {s}{d}/{d}{s}\n", .{ ansi.Color.CYAN, metadata.resolved_packages, metadata.total_packages, ansi.Color.RESET });
        }
    }

    pub fn restoreBackup(self: *Self, backup_path: String, password: ?String, target_username: ?String, progress_callback: ?ProgressCallback) !void {
        if (progress_callback) |callback| {
            callback("Loading backup", 0, 100);
        }

        if (!khr_format.isKhrFile(backup_path)) return BackupError.CorruptedBackup;

        const restore_dir = try std.fmt.allocPrint(self.allocator, "krowno_restore_{d}", .{std.time.timestamp()});
        defer self.allocator.free(restore_dir);

        if (progress_callback) |callback| {
            callback("Decrypting and extracting", 10, 100);
        }

        try khr_format.extractKhrBackup(self.allocator, backup_path, password, restore_dir);

        if (progress_callback) |callback| {
            callback("Restore complete", 100, 100);
        }

        print("KHR restore completed: extracted to ./{s}\n", .{restore_dir});
        self.applySystemRestore(restore_dir, target_username, progress_callback) catch |err| {
            print("Post-restore mapping failed: {s}\n", .{@errorName(err)});
        };
        return;
    }

    pub fn restoreBackupTo(self: *Self, backup_path: String, password: ?String, target_username: ?String, extract_to: String, progress_callback: ?ProgressCallback) !void {
        if (progress_callback) |callback| {
            callback("Loading backup", 0, 100);
        }

        if (!khr_format.isKhrFile(backup_path)) return BackupError.CorruptedBackup;

        if (progress_callback) |callback| {
            callback("Decrypting and extracting", 10, 100);
        }

        try khr_format.extractKhrBackup(self.allocator, backup_path, password, extract_to);

        if (progress_callback) |callback| {
            callback("Restore complete", 100, 100);
        }
        // Apply system restore: map extracted paths into target user's environment
        self.applySystemRestore(extract_to, target_username, progress_callback) catch |err| {
            print("Post-restore mapping failed: {s}\n", .{@errorName(err)});
        };
    }

    fn applySystemRestore(self: *Self, restore_dir: String, target_username: ?String, progress_callback: ?ProgressCallback) !void {
        if (builtin.os.tag != .linux) return;

        print("\n{s}=== System Restore ==={s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });
        print("Mapping files to user home directories...\n", .{});

        if (progress_callback) |callback| {
            callback("Applying system restore", 0, 100);
        }

        var src_user: ?[]u8 = null;
        var old_hostname: ?[]u8 = null;

        const tmp_dir_path = try std.fmt.allocPrint(self.allocator, "{s}/tmp", .{restore_dir});
        defer self.allocator.free(tmp_dir_path);

        var tmp_dir = fs.cwd().openDir(tmp_dir_path, .{ .iterate = true }) catch null;
        if (tmp_dir) |*td| {
            defer td.close();
            var it = td.iterate();
            while (it.next() catch null) |entry| {
                if (std.mem.startsWith(u8, entry.name, "krowno_meta_") and entry.kind == .file) {
                    const meta_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ tmp_dir_path, entry.name });
                    defer self.allocator.free(meta_path);
                    const f = fs.cwd().openFile(meta_path, .{}) catch break;
                    defer f.close();
                    const data = f.readToEndAlloc(self.allocator, 4096) catch break;
                    defer self.allocator.free(data);

                    const uname_key = "\"username\":\"";
                    if (std.mem.indexOf(u8, data, uname_key)) |idx| {
                        const start = idx + uname_key.len;
                        if (std.mem.indexOfScalarPos(u8, data, start, '"')) |end| {
                            src_user = try self.allocator.dupe(u8, data[start..end]);
                        }
                    }
                    const host_key = "\"hostname\":\"";
                    if (std.mem.indexOf(u8, data, host_key)) |idx| {
                        const start = idx + host_key.len;
                        if (std.mem.indexOfScalarPos(u8, data, start, '"')) |end| {
                            old_hostname = try self.allocator.dupe(u8, data[start..end]);
                        }
                    }
                    break;
                }
            }
        }

        if (src_user == null) {
            const home_root = try std.fmt.allocPrint(self.allocator, "{s}/home", .{restore_dir});
            defer self.allocator.free(home_root);
            var home_dir = fs.cwd().openDir(home_root, .{ .iterate = true }) catch null;
            if (home_dir) |*hd| {
                defer hd.close();
                var it2 = hd.iterate();
                while (it2.next() catch null) |entry| {
                    if (entry.kind == .directory) {
                        src_user = try self.allocator.dupe(u8, entry.name);
                        break;
                    }
                }
            }
        }

        if (src_user == null) return; // Nothing to map
        defer self.allocator.free(src_user.?);

        const tgt_user: String = target_username orelse blk: {
            const cur = try detectUsernameAlloc(self.allocator);
            defer self.allocator.free(cur);
            break :blk cur;
        };

        var target_home: []u8 = undefined;
        if (target_username) |u| {
            target_home = try std.fmt.allocPrint(self.allocator, "/home/{s}", .{u});
        } else {
            target_home = try detectHomeDirAlloc(self.allocator);
        }
        defer self.allocator.free(target_home);

        const src_home = try std.fmt.allocPrint(self.allocator, "{s}/home/{s}", .{ restore_dir, src_user.? });
        defer self.allocator.free(src_home);

        print("Copying files from {s} to {s}...\n", .{ src_user.?, tgt_user });
        if (progress_callback) |callback| {
            callback("Copying user files", 30, 100);
        }
        try self.copyTree(src_home, target_home);
        print("{s}✓ Files copied successfully{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });

        print("Installing packages from backup manifest...\n", .{});
        if (progress_callback) |callback| {
            callback("Installing packages", 60, 100);
        }
        self.installPackagesFromTmp(tmp_dir_path) catch {
            print("{s}⚠ Package installation skipped or failed{s}\n", .{ ansi.Color.BOLD_YELLOW, ansi.Color.RESET });
        };
        if (target_username) |u| {
            const owner = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ u, u });
            defer self.allocator.free(owner);
            var child = std.process.Child.init(&[_]String{ "sudo", "chown", "-R", owner, target_home }, self.allocator);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            child.spawn() catch {};
            _ = child.wait() catch {};
        }

        if (old_hostname) |hn| {
            print("Setting hostname to '{s}'...\n", .{hn});
            if (progress_callback) |callback| {
                callback("Updating hostname", 90, 100);
            }
            var child = std.process.Child.init(&[_]String{ "hostnamectl", "set-hostname", hn }, self.allocator);
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
            if (child.spawn()) |_| {
                _ = child.wait() catch {};
                print("{s}✓ Hostname updated{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
            } else |_| {
                print("{s}⚠ Hostname update failed (requires sudo){s}\n", .{ ansi.Color.BOLD_YELLOW, ansi.Color.RESET });
            }
            self.allocator.free(hn);
        }

        if (progress_callback) |callback| {
            callback("System restore complete", 100, 100);
        }
        print("{s}=== System Restore Complete ==={s}\n\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
    }

    fn copyTree(self: *Self, src: String, dst: String) !void {
        var dir = fs.cwd().openDir(src, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            const src_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ src, entry.name });
            defer self.allocator.free(src_path);
            const dst_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dst, entry.name });
            defer self.allocator.free(dst_path);
            switch (entry.kind) {
                .directory => {
                    fs.cwd().makePath(dst_path) catch {};
                    try self.copyTree(src_path, dst_path);
                },
                .file => {
                    const in_f = fs.cwd().openFile(src_path, .{}) catch continue;
                    defer in_f.close();
                    // Ensure parent dir
                    if (std.fs.path.dirname(dst_path)) |d| fs.cwd().makePath(d) catch {};
                    const out_f = fs.cwd().createFile(dst_path, .{}) catch continue;
                    defer out_f.close();
                    var buf: [128 * 1024]u8 = undefined;
                    while (true) {
                        const n = in_f.read(&buf) catch break;
                        if (n == 0) break;
                        _ = out_f.writeAll(buf[0..n]) catch break;
                    }
                },
                else => {},
            }
        }
    }

    fn installPackagesFromTmp(self: *Self, tmp_dir_path: String) !void {
        var dir = fs.cwd().openDir(tmp_dir_path, .{ .iterate = true }) catch return;
        defer dir.close();
        var pkgs = std.ArrayList([]u8).init(self.allocator);
        defer {
            for (pkgs.items) |p| self.allocator.free(p);
            pkgs.deinit();
        }
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.startsWith(u8, entry.name, "krowno_packages_")) continue;
            const fpath = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ tmp_dir_path, entry.name });
            defer self.allocator.free(fpath);
            const f = fs.cwd().openFile(fpath, .{}) catch continue;
            defer f.close();
            const data = f.readToEndAlloc(self.allocator, std.math.maxInt(usize)) catch continue;
            defer self.allocator.free(data);
            var lines = std.mem.splitScalar(u8, data, '\n');
            while (lines.next()) |line| {
                if (std.mem.startsWith(u8, line, "PKG: ")) {
                    const name = std.mem.trim(u8, line[5..], " \r\n\t");
                    if (name.len > 0) try pkgs.append(try self.allocator.dupe(u8, name));
                }
            }
        }
        if (pkgs.items.len == 0) {
            print("  No package manifest found\n", .{});
            return;
        }

        print("  Found {d} packages to install\n", .{pkgs.items.len});

        const d = try distro.detectDistro(self.allocator);
        defer d.deinit(self.allocator);

        var argv = std.ArrayList(String).init(self.allocator);
        defer argv.deinit();
        if (std.mem.indexOf(u8, d.package_manager, "apt")) |_| {
            try argv.appendSlice(&[_]String{ "sudo", "apt-get", "install", "-y" });
        } else if (std.mem.indexOf(u8, d.package_manager, "dnf")) |_| {
            try argv.appendSlice(&[_]String{ "sudo", "dnf", "install", "-y" });
        } else if (std.mem.indexOf(u8, d.package_manager, "pacman")) |_| {
            try argv.appendSlice(&[_]String{ "sudo", "pacman", "-S", "--noconfirm" });
        } else if (std.mem.indexOf(u8, d.package_manager, "zypper")) |_| {
            try argv.appendSlice(&[_]String{ "sudo", "zypper", "in", "-y" });
        } else {
            return; // unsupported
        }
        for (pkgs.items) |p| try argv.append(p);

        print("  Running package manager (this may take a while)...\n", .{});
        var child = std.process.Child.init(argv.items, self.allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        child.spawn() catch {
            print("Failed to spawn package manager\n", .{});
            return;
        };
        const term = child.wait() catch {
            print(" ackage manager process failed\n", .{});
            return;
        };
        if (term == .Exited and term.Exited == 0) {
            print("  {s}Packages installed successfully{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
        } else {
            print("  {s}Some packages may have failed to install{s}\n", .{ ansi.Color.BOLD_YELLOW, ansi.Color.RESET });
        }

        flatpak_support.installFlatpaksFromDirectory(self.allocator, tmp_dir_path) catch {};
    }

    fn analyzeCurrentSystem(self: *Self, metadata: *BackupMetadata) !SystemAnalysis {
        var analysis = SystemAnalysis.init(self.allocator);

        if (self.package_resolver) |resolver| {
            const packages = try resolver.getInstalledPackages();
            defer packages.deinit();

            metadata.total_packages = @intCast(packages.items.len);
            analysis.installed_packages = try packages.clone();
        }

        return analysis;
    }

    fn createPackageManifest(self: *Self, metadata: *BackupMetadata) !PackageManifest {
        var manifest = PackageManifest.init(self.allocator);

        if (self.package_resolver) |resolver| {
            const source_packages = try resolver.getInstalledPackages();
            manifest.source_packages = source_packages;

            var resolved_count: u32 = 0;
            for (source_packages.items) |package| {
                const mappings = try resolver.resolveCrossPlatform(package);
                if (mappings.items.len > 0) {
                    resolved_count += 1;
                }
                const key = try self.allocator.dupe(u8, package);
                try manifest.resolved_mappings.put(key, mappings);
            }

            metadata.resolved_packages = resolved_count;
            metadata.unresolved_packages = metadata.total_packages - resolved_count;
            metadata.cross_platform_compatible = if (metadata.total_packages > 0) (resolved_count * 100 / metadata.total_packages) >= 80 else false;
        }

        return manifest;
    }

    fn createRepoSnapshots(self: *Self) !RepoSnapshots {
        var snapshots = RepoSnapshots.init(self.allocator);

        if (self.repo_crawler) |crawler| {
            try crawler.captureCurrentRepos(&snapshots);
            snapshots.snapshot_timestamp = std.time.timestamp();
        }

        return snapshots;
    }

    fn collectBackupData(self: *Self, strategy: BackupStrategy, metadata: *BackupMetadata, progress_callback: ?ProgressCallback) !ArrayList(BackupEntry) {
        var entries = ArrayList(BackupEntry).init(self.allocator);
        errdefer {
            for (entries.items) |*e| e.deinit(self.allocator);
            entries.deinit();
        }
        const paths = strategy.getPaths();
        const home_dir = try detectHomeDirAlloc(self.allocator);
        defer self.allocator.free(home_dir);
        var total_files: u32 = 0;
        var total_size: types.FileSize = 0;

        for (paths, 0..) |rel_path, i| {
            if (progress_callback) |callback| {
                callback("Scanning files", i + 1, paths.len);
            }

            const full_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ home_dir, rel_path });
            defer self.allocator.free(full_path);

            try self.scanPath(strategy, full_path, &entries, &total_files, &total_size);
        }

        metadata.file_count = total_files;
        metadata.total_size = total_size;

        return entries;
    }

    pub fn scanPath(self: *Self, strategy: BackupStrategy, path: String, entries: *ArrayList(BackupEntry), file_count: *u32, total_size: *u64) !void {
        if (shouldSkipFile(strategy, path)) return;
        const stat = fs.cwd().statFile(path) catch |err| switch (err) {
            error.FileNotFound => return,
            error.AccessDenied => return,
            else => return err,
        };

        if (stat.kind == .directory) {
            var dir = fs.cwd().openDir(path, .{ .iterate = true }) catch return;
            defer dir.close();

            var iterator = dir.iterate();
            while (try iterator.next()) |entry| {
                const child_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ path, entry.name });
                defer self.allocator.free(child_path);
                if (!shouldSkipFile(strategy, entry.name)) {
                    try self.scanPath(strategy, child_path, entries, file_count, total_size);
                }
            }
        } else {
            // Files are streamed during archive creation to avoid memory bloat
            const duplicated_path = try self.allocator.dupe(u8, path);
            errdefer self.allocator.free(duplicated_path);

            const entry = BackupEntry{
                .path = Path.init(duplicated_path),
                .size = stat.size,
                .mode = @intCast(stat.mode),
                .mtime = @intCast(stat.mtime),
                .is_dir = false,
                .data = null,
            };

            try entries.append(entry);
            file_count.* += 1;
            total_size.* += stat.size;
        }
    }

    fn saveBackup(self: *Self, output_path: String, metadata: *const BackupMetadata, entries: []const BackupEntry, package_manifest: ?PackageManifest, repo_snapshots: ?RepoSnapshots, user_password: ?String, progress_callback: ?ProgressCallback, requested_compression: khr_format.CompressionType) !void {
        var khr_path: []u8 = undefined;
        if (endsWith(output_path, ".khr")) {
            khr_path = try self.allocator.dupe(u8, output_path);
        } else {
            khr_path = try std.fmt.allocPrint(self.allocator, "{s}.khr", .{output_path});
        }
        defer self.allocator.free(khr_path);

        print("Saving backup as KHR format: {s}\n", .{khr_path});

        const dir = std.fs.path.dirname(khr_path) orelse ".";
        const ten_percent: types.FileSize = metadata.total_size / 10;
        const sixteen_mib: types.FileSize = 16 * 1024 * 1024;
        const overhead: types.FileSize = if (sixteen_mib > ten_percent) sixteen_mib else ten_percent;
        const ds = checkDiskSpace(dir, metadata.total_size + overhead);
        if (ds.isError()) return BackupError.DiskSpaceInsufficient;

        var source_paths = ArrayList(String).init(self.allocator);
        defer source_paths.deinit();
        var owned_paths = ArrayList(String).init(self.allocator);
        defer {
            for (owned_paths.items) |p| self.allocator.free(p);
            owned_paths.deinit();
        }

        for (entries) |entry| {
            fs.cwd().access(entry.path.value, .{}) catch continue;
            try source_paths.append(entry.path.value);
        }

        var temp_paths = ArrayList(String).init(self.allocator);
        defer {
            for (temp_paths.items) |p| self.allocator.free(p);
            temp_paths.deinit();
        }

        if (package_manifest) |manifest| {
            const manifest_path = try std.fmt.allocPrint(self.allocator, "/tmp/krowno_packages_{d}.txt", .{std.time.timestamp()});
            defer self.allocator.free(manifest_path);

            const manifest_file = try fs.cwd().createFile(manifest_path, .{});
            defer manifest_file.close();

            try manifest_file.writer().print("KROWNO_PACKAGE_MANIFEST\n", .{});
            try manifest_file.writer().print("TIMESTAMP: {d}\n", .{std.time.timestamp()});
            try manifest_file.writer().print("TOTAL_PACKAGES: {d}\n", .{manifest.source_packages.items.len});

            for (manifest.source_packages.items) |pkg| {
                try manifest_file.writer().print("PKG: {s}\n", .{pkg});
            }

            const manifest_tmp_copy = try self.allocator.dupe(u8, manifest_path);
            errdefer self.allocator.free(manifest_tmp_copy);
            try temp_paths.append(manifest_tmp_copy);

            const manifest_path_copy = try self.allocator.dupe(u8, manifest_path);
            try source_paths.append(manifest_path_copy);
            try owned_paths.append(manifest_path_copy);
        }

        blk: {
            const flatpak_path = try std.fmt.allocPrint(self.allocator, "/tmp/krowno_flatpaks_{d}.txt", .{std.time.timestamp()});
            defer self.allocator.free(flatpak_path);

            flatpak_support.saveFlatpakList(self.allocator, flatpak_path) catch break :blk;
            fs.cwd().access(flatpak_path, .{}) catch break :blk;
            const flatpak_tmp_copy = try self.allocator.dupe(u8, flatpak_path);
            errdefer self.allocator.free(flatpak_tmp_copy);
            try temp_paths.append(flatpak_tmp_copy);

            const flatpak_path_copy = try self.allocator.dupe(u8, flatpak_path);
            try source_paths.append(flatpak_path_copy);
            try owned_paths.append(flatpak_path_copy);
        }

        if (repo_snapshots) |snapshots| {
            const snapshots_path = try std.fmt.allocPrint(self.allocator, "/tmp/krowno_repos_{d}.txt", .{std.time.timestamp()});
            defer self.allocator.free(snapshots_path);

            const snapshots_file = try fs.cwd().createFile(snapshots_path, .{});
            defer snapshots_file.close();

            try snapshots_file.writer().print("KROWNO_REPO_SNAPSHOTS\n", .{});
            try snapshots_file.writer().print("TIMESTAMP: {d}\n", .{snapshots.snapshot_timestamp});
            try snapshots_file.writer().print("REPOSITORY_COUNT: {d}\n", .{snapshots.repository_count});
            try snapshots_file.writer().print("PACKAGE_COUNT: {d}\n", .{snapshots.package_count});

            for (snapshots.metadata.items) |meta| {
                try snapshots_file.writer().print("REPO: {s}\n", .{meta});
            }

            const snapshots_tmp_copy = try self.allocator.dupe(u8, snapshots_path);
            errdefer self.allocator.free(snapshots_tmp_copy);
            try temp_paths.append(snapshots_tmp_copy);

            const snapshots_path_copy = try std.fmt.allocPrint(self.allocator, "{s}", .{snapshots_path});
            try source_paths.append(snapshots_path_copy);
            try owned_paths.append(snapshots_path_copy);
        }

        {
            const meta_path = try std.fmt.allocPrint(self.allocator, "/tmp/krowno_meta_{d}.json", .{std.time.timestamp()});
            defer self.allocator.free(meta_path);

            const meta_file = try fs.cwd().createFile(meta_path, .{});
            defer meta_file.close();

            const home_meta = try detectHomeDirAlloc(self.allocator);
            defer self.allocator.free(home_meta);

            try meta_file.writer().print(
                "{{\"hostname\":\"{s}\",\"username\":\"{s}\",\"home\":\"{s}\",\"timestamp\":{d}}}\n",
                .{ metadata.hostname, metadata.username, home_meta, metadata.timestamp },
            );

            const meta_tmp_copy = try self.allocator.dupe(u8, meta_path);
            errdefer self.allocator.free(meta_tmp_copy);
            try temp_paths.append(meta_tmp_copy);

            const meta_path_copy = try self.allocator.dupe(u8, meta_path);
            try source_paths.append(meta_path_copy);
            try owned_paths.append(meta_path_copy);
        }

        const compression = requested_compression;
        var password: ?String = user_password;
        const LARGE_FILE_COUNT: usize = 5000;
        const LARGE_TOTAL_SIZE: u64 = 1_000_000_000; // 1 GiB
        if (password != null and (source_paths.items.len > LARGE_FILE_COUNT or metadata.total_size > LARGE_TOTAL_SIZE)) {
            print("{s}Warning:{s} encryption temporarily disabled for large backups (streaming encryption pending). Files: {d}, Size: {d} bytes\n", .{ ansi.Color.BOLD_YELLOW, ansi.Color.RESET, source_paths.items.len, metadata.total_size });
            password = null;
        }

        print("Creating archive with {d} files ({d} bytes total)...\n", .{ source_paths.items.len, metadata.total_size });
        print("Using streaming mode (files read on-demand, no memory bloat)\n", .{});
        if (progress_callback) |cb| cb("Saving files", 0, source_paths.items.len);

        try khr_format.createKhrBackup(
            self.allocator,
            source_paths.items,
            khr_path,
            password,
            compression,
            if (progress_callback) |cb| @ptrCast(cb) else null,
        );

        if (progress_callback) |cb| cb("Finalizing archive", source_paths.items.len, source_paths.items.len);

        for (temp_paths.items) |p| {
            fs.cwd().deleteFile(p) catch {};
        }

        print("{s}Backup saved successfully:{s} {s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET, khr_path });
    }

    fn migrateUsername(self: *Self, credentials: UserCredentials, new_username: String) !void {
        print("Migrating from user '{s}' to '{s}'\n", .{ credentials.username, new_username });

        var cmd1 = [_]String{ "sudo", "useradd", "-m", "-s", credentials.shell, new_username };
        try self.runCommandArgv(&cmd1);

        const src_path = try std.fmt.allocPrint(self.allocator, "{s}/", .{credentials.home_directory});
        defer self.allocator.free(src_path);
        const dst_path = try std.fmt.allocPrint(self.allocator, "/home/{s}/", .{new_username});
        defer self.allocator.free(dst_path);
        var cmd2 = [_]String{ "sudo", "rsync", "-a", "--info=progress2", src_path, dst_path };
        try self.runCommandArgv(&cmd2);

        const home_dir = try std.fmt.allocPrint(self.allocator, "/home/{s}", .{new_username});
        defer self.allocator.free(home_dir);
        const owner = try std.fmt.allocPrint(self.allocator, "{s}:{s}", .{ new_username, new_username });
        defer self.allocator.free(owner);
        var cmd3 = [_]String{ "sudo", "chown", "-R", owner, home_dir };
        try self.runCommandArgv(&cmd3);

        print("User migration completed for '{s}' -> '{s}' (check for shell/profile differences)\n", .{ credentials.username, new_username });
    }

    fn runCommandArgv(self: *Self, argv: []const String) !void {
        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
        try child.spawn();
        const term = try child.wait();
        if (!(term == .Exited and term.Exited == 0)) {
            print("Command failed: {s}\n", .{argv[0]});
            return BackupError.PermissionDenied;
        }
    }

    fn installResolvedPackages(self: *Self, manifest: PackageManifest) !void {
        if (self.package_resolver) |resolver| {
            const current_distro = try distro.detectDistro(self.allocator);
            defer current_distro.deinit(self.allocator);

            for (manifest.source_packages.items) |package| {
                if (manifest.resolved_mappings.get(package)) |mappings| {
                    for (mappings.items) |mapping| {
                        if (std.mem.eql(u8, mapping.target_distro, current_distro.name)) {
                            try resolver.installPackage(mapping.package_name);
                            break;
                        }
                    }
                }
            }
        }
    }

    fn restoreFiles(_: *Self, entries: []const BackupEntry, progress_callback: ?ProgressCallback) !void {
        for (entries, 0..) |entry, i| {
            if (progress_callback) |callback| {
                callback("Restoring files", 60 + (i * 20 / entries.len), 100);
            }

            if (entry.is_dir) {
                try fs.cwd().makePath(entry.path.value);
            } else {
                const parent_dir = fs.path.dirname(entry.path.value);
                if (parent_dir) |dir| {
                    fs.cwd().makePath(dir) catch {};
                }

                if (entry.data) |data| {
                    try fs.cwd().writeFile(.{ .sub_path = entry.path.value, .data = data });
                }
            }
        }
    }

    fn applyPostRestoreConfig(_: *Self, metadata: *const BackupMetadata) !void {
        print("Applying post-restore configuration...\n", .{});

        if (builtin.os.tag == .linux) {
            const hostname_file = std.fs.cwd().readFileAlloc(std.heap.page_allocator, "/etc/hostname", 256) catch return;
            defer std.heap.page_allocator.free(hostname_file);
            const current = std.mem.trim(u8, hostname_file, " \n\r\t");
            if (!std.mem.eql(u8, current, metadata.hostname)) {
                print("Consider updating hostname from '{s}' to '{s}'\n", .{ current, metadata.hostname });
            }
        }
    }

    fn printPostRestoreRecommendations(_: *Self, metadata: *const BackupMetadata) void {
        print("\nPost-restore recommendations:\n", .{});
        print("1. Reboot system to ensure all changes take effect\n", .{});
        print("2. Check that all applications launch correctly\n", .{});
        print("3. Update package cache: sudo {s} update\n", .{metadata.distro_info.package_manager});
        print("4. Review SSH keys and regenerate if necessary\n", .{});

        if (metadata.cross_platform_compatible and metadata.total_packages > 0) {
            const percentage = (metadata.resolved_packages * 100) / metadata.total_packages;
            print("5. Cross-platform compatibility: {d}% packages resolved\n", .{percentage});
        }

        if (metadata.user_credentials != null) {
            print("6. User credentials were restored - verify login works\n", .{});
        }
    }
};

const UserCredentials = struct {
    username: String,
    password_hash: String,
    salt: String,
    home_directory: String,
    shell: String,
    uid: u32,
    gid: u32,

    const Self = @This();

    pub fn captureCurrent(allocator: Allocator) !Self {
        const username = std.posix.getenv("USER") orelse "unknown";
        const home_dir = std.posix.getenv("HOME") orelse "/home/unknown";
        const shell = std.posix.getenv("SHELL") orelse "/bin/bash";

        var salt_buf: [32]u8 = undefined;
        std.crypto.random.bytes(&salt_buf);

        return Self{
            .username = try allocator.dupe(u8, username),
            .password_hash = try allocator.alloc(u8, 64),
            .salt = try allocator.dupe(u8, &salt_buf),
            .home_directory = try allocator.dupe(u8, home_dir),
            .shell = try allocator.dupe(u8, shell),
            .uid = 1000, // Default UID
            .gid = 1000, // Default GID
        };
    }

    pub fn hashPassword(self: *Self, allocator: Allocator, password: String) !void {
        const hash = try security.hashPasswordWithSalt(allocator, password, self.salt);
        allocator.free(self.password_hash);
        self.password_hash = hash;
    }

    pub fn verifyPassword(self: Self, allocator: Allocator, password: String) !bool {
        const test_hash = try security.hashPasswordWithSalt(allocator, password, self.salt);
        defer allocator.free(test_hash);
        return std.mem.eql(u8, self.password_hash, test_hash);
    }

    pub fn deinit(self: Self, allocator: Allocator) void {
        allocator.free(self.username);
        allocator.free(self.password_hash);
        allocator.free(self.salt);
        allocator.free(self.home_directory);
        allocator.free(self.shell);
    }
};

const PackageManifest = struct {
    allocator: Allocator,
    source_packages: ArrayList(String),
    resolved_mappings: HashMap(String, ArrayList(package_resolver.PackageResolver.CrossPlatformMapping), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    dependency_tree: HashMap(String, ArrayList(String), std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .source_packages = ArrayList(String).init(allocator),
            .resolved_mappings = HashMap(String, ArrayList(package_resolver.PackageResolver.CrossPlatformMapping), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .dependency_tree = HashMap(String, ArrayList(String), std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.source_packages.items) |pkg| {
            self.allocator.free(pkg);
        }
        self.source_packages.deinit();

        var iter = self.resolved_mappings.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |mapping| {
                self.allocator.free(mapping.source_package);
                self.allocator.free(mapping.package_name);
            }
            entry.value_ptr.deinit();
        }
        self.resolved_mappings.deinit();

        var dep_iter = self.dependency_tree.iterator();
        while (dep_iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            for (entry.value_ptr.items) |dep| {
                self.allocator.free(dep);
            }
            entry.value_ptr.deinit();
        }
        self.dependency_tree.deinit();
    }
};

const PackageMapping = struct {
    source_package: String,
    target_distro: String,
    package_name: String,
    confidence: f32,
};

const RepoSnapshots = struct {
    allocator: Allocator,
    package_count: u32,
    repository_count: u32,
    snapshot_timestamp: Timestamp,
    metadata: ArrayList(String),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .package_count = 0,
            .repository_count = 0,
            .snapshot_timestamp = 0,
            .metadata = ArrayList(String).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.metadata.items) |item| {
            self.allocator.free(item);
        }
        self.metadata.deinit();
    }
};

const SystemAnalysis = struct {
    allocator: Allocator,
    file_count: u32,
    total_size: types.FileSize,
    installed_packages: ?ArrayList(String),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .file_count = 0,
            .total_size = 0,
            .installed_packages = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.installed_packages) |*packages| {
            for (packages.items) |pkg| {
                self.allocator.free(pkg);
            }
            packages.deinit();
        }
    }
};

const BackupData = struct {
    metadata: BackupMetadata,
    entries: []const BackupEntry,
    package_manifest: ?PackageManifest,
    repo_snapshots: ?RepoSnapshots,
};

fn shouldSkipFile(strategy: BackupStrategy, name: String) bool {
    const blacklist_patterns = [_]String{
        ".cache",      ".tmp", ".log",   ".lock", "node_modules", ".git",
        "__pycache__", ".pyc", "target", "build",
    };

    for (blacklist_patterns) |pattern| {
        if (std.mem.indexOf(u8, name, pattern) != null) {
            return true;
        }
    }

    const is_heavy_exclusion = (strategy == .minimal or strategy == .standard);
    if (is_heavy_exclusion) {
        const heavy_dirs = [_]String{"Screenshots"};
        for (heavy_dirs) |pattern| {
            if (std.mem.indexOf(u8, name, pattern) != null) return true;
        }
        const heavy_exts = [_]String{ ".mp4", ".mkv", ".mov", ".flac", ".wav", ".iso" };
        for (heavy_exts) |ext| {
            if (std.mem.endsWith(u8, name, ext)) return true;
        }
    }

    return false;
}

pub fn createSimpleBackup(allocator: Allocator, output_path: String, password: ?String, _: []const String) !void {
    print("Creating simple backup to: {s}\n", .{output_path});

    var engine = try BackupEngine.init(allocator);
    defer engine.deinit();

    try engine.createBackup(.minimal, output_path, password, null, @import("khr_format.zig").CompressionType.gzip);
}

pub fn restoreSimpleBackup(allocator: Allocator, backup_path: String, password: ?String) !void {
    print("Restoring simple backup from: {s}\n", .{backup_path});

    var engine = try BackupEngine.init(allocator);
    defer engine.deinit();

    try engine.restoreBackup(backup_path, password, null, null);
}

pub fn defaultProgressCallback(operation: String, current: usize, total: usize) void {
    const percentage = if (total > 0) (current * 100) / total else 0;
    print("\r{s}: {d}/{d} ({d}%)   ", .{ operation, current, total, percentage });

    const stdout = std.io.getStdOut();
    stdout.writeAll("") catch {};
}

pub fn isBackupEncrypted(path: String) !bool {
    if (!khr_format.isKhrFile(path)) return false;
    const info = khr_format.getKhrInfo(std.heap.page_allocator, path) catch return false;
    return info.encrypted;
}

pub const BackupInfo = struct {
    version: String,
    timestamp: types.Timestamp,
    hostname: String,
    username: String,
    file_count: u32,
    total_size: types.FileSize,
    encrypted: bool,

    pub fn deinit(self: *BackupInfo, allocator: Allocator) void {
        allocator.free(self.version);
        allocator.free(self.hostname);
        allocator.free(self.username);
    }
};

pub fn getBackupInfo(allocator: Allocator, backup_path: String) !BackupInfo {
    if (khr_format.isKhrFile(backup_path)) {
        const info = try khr_format.getKhrInfo(allocator, backup_path);
        return BackupInfo{
            .version = try allocator.dupe(u8, "0.3.0 (KHR)"),
            .timestamp = std.time.timestamp(),
            .hostname = try allocator.dupe(u8, "unknown"),
            .username = try allocator.dupe(u8, "unknown"),
            .file_count = 0,
            .total_size = info.file_size,
            .encrypted = info.encrypted,
        };
    }

    return BackupInfo{
        .version = try allocator.dupe(u8, "0.3.0 (unknown)"),
        .timestamp = std.time.timestamp(),
        .hostname = try allocator.dupe(u8, "unknown"),
        .username = try allocator.dupe(u8, "unknown"),
        .file_count = 0,
        .total_size = 0,
        .encrypted = false,
    };
}

pub fn validateBackup(allocator: Allocator, backup_path: String, password: ?String) !bool {
    _ = allocator;
    const file = fs.cwd().openFile(backup_path, .{}) catch return false;
    defer file.close();
    var magic: [8]u8 = undefined;
    _ = file.readAll(&magic) catch return false;
    if (!std.mem.eql(u8, &magic, "KHRONO01")) return false;
    try file.seekTo(0);
    const header = try khr_format.KhrHeader.read(file.reader());
    const data_start = try file.getPos();

    if (header.tar_size == 0) return false;

    const is_encrypted = (header.encryption.opslimit != 0 or header.encryption.memlimit != 0);

    if (header.version == 2) {
        try file.seekTo(data_start);

        if (is_encrypted) {
            const ENC_MAGIC = "KHROWNO_ENC_V1\n";
            var enc_hdr: [ENC_MAGIC.len]u8 = undefined;
            _ = file.readAll(&enc_hdr) catch return false;
            if (!std.mem.eql(u8, &enc_hdr, ENC_MAGIC)) return false;
            _ = password; // reserved for future deep validation
            return true;
        }
        const V2_MAGIC = "KHRV2\n";
        if (header.compression == .none) {
            var buf: [V2_MAGIC.len]u8 = undefined;
            _ = file.readAll(&buf) catch return false;
            return std.mem.eql(u8, &buf, V2_MAGIC);
        } else if (header.compression == .gzip) {
            var limited = std.io.limitedReader(file.reader(), header.tar_size);
            var dec = std.compress.gzip.decompressor(limited.reader());
            var r = dec.reader();
            var buf: [V2_MAGIC.len]u8 = undefined;
            const got = r.readAll(&buf) catch return false;
            if (got != V2_MAGIC.len) return false;
            return std.mem.eql(u8, &buf, V2_MAGIC);
        } else {
            return false;
        }
    }
    return false;
}

pub fn listBackups(allocator: Allocator, directory: String) !void {
    print("Scanning directory: {s}\n", .{directory});

    var dir = fs.cwd().openDir(directory, .{ .iterate = true }) catch |err| {
        print("Error opening directory: {any}\n", .{err});
        return;
    };
    defer dir.close();

    var count: u32 = 0;
    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        if (std.mem.endsWith(u8, entry.name, ".khr")) {
            count += 1;
            const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, entry.name });
            defer allocator.free(full_path);

            var info = getBackupInfo(allocator, full_path) catch |err| {
                print("  {s} - ERROR: {any}\n", .{ entry.name, err });
                continue;
            };
            defer info.deinit(allocator);

            const timestamp_str = try std.fmt.allocPrint(allocator, "{d}", .{info.timestamp});
            defer allocator.free(timestamp_str);

            print("  {s} - {s} ({d} files, {d} bytes)\n", .{ entry.name, timestamp_str, info.file_count, info.total_size });
        }
    }

    if (count == 0) {
        print("No backup files found in {s}\n", .{directory});
    } else {
        print("Found {d} backup file(s)\n", .{count});
    }
}

pub fn quickValidate(allocator: Allocator, backup_path: String) !bool {
    _ = allocator;
    print("Quick validation of: {s}\n", .{backup_path});

    const stat = fs.cwd().statFile(backup_path) catch |err| {
        print("  ❌ File not accessible: {any}\n", .{err});
        return false;
    };
    if (stat.size < 32) {
        print("  ❌ File too small to be valid backup\n", .{});
        return false;
    }
    const file = fs.cwd().openFile(backup_path, .{}) catch |err| {
        print("  ❌ Cannot open file: {any}\n", .{err});
        return false;
    };
    defer file.close();
    var magic: [8]u8 = undefined;
    _ = try file.readAll(&magic);
    if (std.mem.eql(u8, &magic, "KHRONO01")) {
        print("  ✅ KHR backup container\n", .{});
        return true;
    }
    print("  ❌ File doesn't look like a valid backup\n", .{});
    return false;
}

pub fn estimateBackupSize(strategy: BackupStrategy) types.FileSize {
    return switch (strategy) {
        .minimal => 5 * 1024 * 1024,
        .standard => 50 * 1024 * 1024,
        .comprehensive => 200 * 1024 * 1024,
        .paranoid => 500 * 1024 * 1024,
    };
}

pub fn checkDiskSpace(path: String, required_size: types.FileSize) Result {
    _ = path;
    _ = required_size;
    return Result.ok();
}

pub fn cleanupOldBackups(allocator: Allocator, directory: String, days_to_keep: u32) !void {
    print("Cleaning up backups older than {d} days in: {s}\n", .{ days_to_keep, directory });

    const now = std.time.timestamp();
    const cutoff: types.Timestamp = now - @as(types.Timestamp, @intCast(days_to_keep)) * 24 * 3600;

    var dir = fs.cwd().openDir(directory, .{ .iterate = true }) catch |err| {
        print("Cannot open directory: {any}\n", .{err});
        return;
    };
    defer dir.close();

    var deleted: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (!(std.mem.endsWith(u8, entry.name, ".khr") or std.mem.endsWith(u8, entry.name, ".krowno"))) continue;
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, entry.name });
        defer allocator.free(full_path);
        const st = fs.cwd().statFile(full_path) catch continue;
        const mtime: types.Timestamp = @intCast(st.mtime);
        if (mtime < cutoff) {
            fs.cwd().deleteFile(full_path) catch |err| {
                print("Failed to delete {s}: {any}\n", .{ full_path, err });
                continue;
            };
            deleted += 1;
            print("Deleted old backup: {s}\n", .{full_path});
        }
    }
    print("Cleanup complete. Deleted {d} file(s).\n", .{deleted});
}

pub fn compressBackup(allocator: Allocator, backup_path: String) !void {
    print("Compressing backup: {s}\n", .{backup_path});

    const file = try fs.cwd().openFile(backup_path, .{});
    defer file.close();
    const st = try file.stat();
    var buf = try allocator.alloc(u8, st.size);
    defer allocator.free(buf);
    const n = try file.readAll(buf);
    const content = buf[0..n];

    const compress_mod = @import("../utils/compress.zig");
    var engine = compress_mod.Compressor.init(allocator);
    defer engine.deinit();
    var result = try engine.compress(content);
    defer result.deinit(allocator);

    const out_path = try std.fmt.allocPrint(allocator, "{s}.gz", .{backup_path});
    defer allocator.free(out_path);
    const out_file = try fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try out_file.writeAll(result.compressed_data);
    print("Compressed to: {s}\n", .{out_path});
}

pub fn encryptBackup(allocator: Allocator, backup_path: String, password: String) !void {
    print("Encrypting backup: {s}\n", .{backup_path});

    const file = try fs.cwd().openFile(backup_path, .{});
    defer file.close();
    const st = try file.stat();
    var buf = try allocator.alloc(u8, st.size);
    defer allocator.free(buf);
    const n = try file.readAll(buf);
    const content = buf[0..n];

    var ctx = security.CryptoContext.init(allocator);
    defer ctx.deinit();
    // Password will be used when encrypting data

    var enc = try ctx.encrypt(content, password);
    defer enc.deinit(allocator);
    const serialized = try ctx.serializeEncrypted(enc);
    defer allocator.free(serialized);

    const out_path = try std.fmt.allocPrint(allocator, "{s}.enc", .{backup_path});
    defer allocator.free(out_path);
    const out_file = try fs.cwd().createFile(out_path, .{});
    defer out_file.close();
    try out_file.writeAll(serialized);
    print("Encrypted to: {s}\n", .{out_path});
}

pub const createBackup = BackupEngine.createBackup;
pub const restoreBackup = BackupEngine.restoreBackup;
