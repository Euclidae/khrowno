const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const HashMap = std.HashMap;
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;
const network = @import("../utils/network.zig");
const distro = @import("../system/distro.zig");

// this is the hardest part of the whole project
//mapping packages seems tedious but i did build a network module to help out with that.

// To be honest the idea of package resolution is intimidating.
// I guess I can write a some kind of string parser to colloberate my initial idea of using python.
//Recall, a lot of packages are just not the same on linux. For example, if you dnf install something in fedora
// you will find that sdl2 will be sdl2-devel but in ubuntu it might be something like libSDL2. Thinking about it,
// the cases aren't that comprehensive so... perhaps one way to do it is to webscrape as I mentioned, network module is
//actually helpful here.. Maybe I can extend it. Fedora has websites for dnf with search bar so what if I
// cleaned string -> base package. common patterns be like libSDL2-dev so if we find -dev, we remove it, if we find lib, we remove it.
// it's just string manipulation. I guess the first thing to do here is to actually figure out all the things that can go wrong.
// zig has stuff like std.mem(i think it was).startsWith and endsWith so that should be helpful.
// Also, fuzzy matching might be helpful here. If I can find a way to calculate string similarity, that would be great.
pub const PackageResolverError = error{
    PackageNotFound,
    NetworkError,
    ParsingError,
    UnsupportedDistro,
    RateLimited,
    DatabaseCorrupted,
};

pub const PackageMapping = struct {
    canonical_name: String,
    fedora_name: ?String,
    ubuntu_name: ?String,
    debian_name: ?String,
    arch_name: ?String,
    opensuse_name: ?String,
    description: ?String,
    category: PackageCategory,
    popularity: f32, //added this to prioritize common packages
    last_verified: types.Timestamp, //unix timestamp, need to update these regularly

    //TODO: add more distros? manjaro should be easy since its arch-based
    //maybe elementary OS too since its ubuntu-based

    // Because i know what packages I will actually need, I ended up
    // spending way too long on the package mapping database. As mentioned earlier some packages have completely different names across distros
    // Firefox is easy (usually "firefox") but something like
    // SDL2" becomes "sdl2-dev" or "libsdl2-dev" making this a little annoying, I won't lie. string parsing is the first idea but
    // I'd like to explore a few options fo rnow.

    const Self = @This();

    pub fn init(canonical_name: String) Self {
        return Self{
            .canonical_name = canonical_name,
            .fedora_name = null,
            .ubuntu_name = null,
            .debian_name = null,
            .arch_name = null,
            .opensuse_name = null,
            .description = null,
            .category = .unknown,
            .popularity = 0.0,
            .last_verified = 0,
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.canonical_name);
        if (self.fedora_name) |s| allocator.free(s);
        if (self.ubuntu_name) |s| allocator.free(s);
        if (self.debian_name) |s| allocator.free(s);
        if (self.arch_name) |s| allocator.free(s);
        if (self.opensuse_name) |s| allocator.free(s); // NB. Remember that openSUSE comes with two flavors.
        if (self.description) |s| allocator.free(s);
    }

    pub fn getNameForDistro(self: *const Self, target_distro: distro.DistroType) ?String {
        return switch (target_distro) {
            .fedora => self.fedora_name,
            .ubuntu => self.ubuntu_name,
            .debian => self.debian_name orelse self.ubuntu_name,
            .arch => self.arch_name,
            .opensuse_leap, .opensuse_tumbleweed => self.opensuse_name, // both use same package name
            .unknown => null,
            .mint, .nixos => null, // handled elsewhere
        };
    }

    pub fn hasMapping(self: *const Self, target_distro: distro.DistroType) bool {
        return self.getNameForDistro(target_distro) != null;
    }
};

pub const PackageCategory = enum {
    development,
    multimedia,
    system,
    library,
    desktop,
    server,
    gaming,
    security,
    network,
    unknown,

    pub fn fromString(str: String) PackageCategory { // let me cook. I think I might be causing a small smell by overcommenting here but
        // am convinced this is my greatest obstacle.
        // ever noticed how when you run update on a given package, you tend to see these? qt etc etc?
        //
        if (std.mem.indexOf(u8, str, "dev") != null or
            std.mem.indexOf(u8, str, "devel") != null) return .development;
        if (std.mem.indexOf(u8, str, "lib") != null) return .library;
        if (std.mem.indexOf(u8, str, "gtk") != null or
            std.mem.indexOf(u8, str, "qt") != null) return .desktop;
        if (std.mem.indexOf(u8, str, "server") != null or
            std.mem.indexOf(u8, str, "daemon") != null) return .server;
        return .unknown;
    }
};

pub const PackageResolver = struct {
    allocator: Allocator,
    mappings: HashMap(String, PackageMapping, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),
    repo_checker: network.RepositoryChecker,
    rate_limiter: network.RateLimiter,
    cache_file: String,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const home_dir = std.process.getEnvVarOwned(allocator, "HOME") catch try allocator.dupe(u8, "/tmp");
        defer allocator.free(home_dir);

        var self = Self{
            .allocator = allocator,
            .mappings = HashMap(String, PackageMapping, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
            .repo_checker = try network.RepositoryChecker.init(allocator),
            .rate_limiter = network.RateLimiter.init(2000),
            .cache_file = try std.fs.path.join(allocator, &[_]String{ home_dir, ".config", "krowno", "package_mappings.json" }),
        };

        try self.loadBuiltinMappings();
        try self.loadCachedMappings();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.saveCachedMappings() catch |err| {
            print("Warning: Could not save package mappings: {any}\n", .{err});
        };

        var iterator = self.mappings.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.mappings.deinit();
        self.repo_checker.deinit();
        self.allocator.free(self.cache_file);
    }

    fn loadBuiltinMappings(self: *Self) !void {
        // Mind you, these are specific to my needs
        print("Loading built-in package mappings...\n", .{});

        try self.addMapping("sdl2-devel", .{
            .fedora_name = "SDL2-devel",
            .ubuntu_name = "libsdl2-dev",
            .debian_name = "libsdl2-dev",
            .arch_name = "sdl2",
            .opensuse_name = "libSDL2-devel",
            .description = "Simple DirectMedia Layer 2.0 development files",
            .category = .development,
            .popularity = 0.8,
        });

        // SDL3 development
        try self.addMapping("sdl3-devel", .{
            .fedora_name = "SDL3-devel",
            .ubuntu_name = "libsdl3-dev",
            .debian_name = "libsdl3-dev",
            .arch_name = "sdl3",
            .opensuse_name = "libSDL3-devel",
            .description = "Simple DirectMedia Layer 3.0 development files",
            .category = .development,
            .popularity = 0.3,
        });

        // GTK4 development
        try self.addMapping("gtk4-devel", .{
            .fedora_name = "gtk4-devel",
            .ubuntu_name = "libgtk-4-dev",
            .debian_name = "libgtk-4-dev",
            .arch_name = "gtk4",
            .opensuse_name = "gtk4-devel",
            .description = "GTK 4 GUI toolkit development files",
            .category = .development,
            .popularity = 0.7,
        });

        // Python development headers
        try self.addMapping("python3-devel", .{
            .fedora_name = "python3-devel",
            .ubuntu_name = "python3-dev",
            .debian_name = "python3-dev",
            .arch_name = "python",
            .opensuse_name = "python3-devel",
            .description = "Python 3 development headers and libraries",
            .category = .development,
            .popularity = 0.9,
        });

        // OpenSSL development
        try self.addMapping("openssl-devel", .{
            .fedora_name = "openssl-devel",
            .ubuntu_name = "libssl-dev",
            .debian_name = "libssl-dev",
            .arch_name = "openssl",
            .opensuse_name = "libopenssl-devel",
            .description = "OpenSSL cryptographic library development files",
            .category = .security,
            .popularity = 0.9,
        });

        // Add common package mappings
        try self.addCommonDevelopmentPackages();
        try self.addMediaPackages();
        try self.addSystemLibraries();

        print("Loaded {d} built-in package mappings\n", .{self.mappings.count()});
    }

    fn addCommonDevelopmentPackages(self: *Self) !void {
        // GCC compiler (I do wonder why the clankers won't use clang instead... just saying)
        try self.addMapping("gcc", .{
            .fedora_name = "gcc",
            .ubuntu_name = "gcc",
            .debian_name = "gcc",
            .arch_name = "gcc",
            .opensuse_name = "gcc",
            .description = "GNU Compiler Collection",
            .category = .development,
            .popularity = 0.95,
        });

        // Make
        try self.addMapping("make", .{
            .fedora_name = "make",
            .ubuntu_name = "make",
            .debian_name = "make",
            .arch_name = "make",
            .opensuse_name = "make",
            .description = "GNU Make build automation tool",
            .category = .development,
            .popularity = 0.9,
        });

        // CMake
        try self.addMapping("cmake", .{
            .fedora_name = "cmake",
            .ubuntu_name = "cmake",
            .debian_name = "cmake",
            .arch_name = "cmake",
            .opensuse_name = "cmake",
            .description = "Cross-platform build system generator",
            .category = .development,
            .popularity = 0.8,
        });

        // Git version control
        try self.addMapping("git", .{
            .fedora_name = "git",
            .ubuntu_name = "git",
            .debian_name = "git",
            .arch_name = "git",
            .opensuse_name = "git",
            .description = "Distributed version control system",
            .category = .development,
            .popularity = 0.95,
        });
    }

    fn addMediaPackages(self: *Self) !void {
        // FFmpeg
        try self.addMapping("ffmpeg", .{
            .fedora_name = "ffmpeg",
            .ubuntu_name = "ffmpeg",
            .debian_name = "ffmpeg",
            .arch_name = "ffmpeg",
            .opensuse_name = "ffmpeg",
            .description = "Complete multimedia framework",
            .category = .multimedia,
            .popularity = 0.8,
        });

        // GStreamer development
        try self.addMapping("gstreamer-devel", .{
            .fedora_name = "gstreamer1-devel",
            .ubuntu_name = "libgstreamer1.0-dev",
            .debian_name = "libgstreamer1.0-dev",
            .arch_name = "gstreamer",
            .opensuse_name = "gstreamer-devel",
            .description = "GStreamer multimedia framework development files",
            .category = .development,
            .popularity = 0.6,
        });
    }

    fn addSystemLibraries(self: *Self) !void {
        // zlib compression
        try self.addMapping("zlib-devel", .{
            .fedora_name = "zlib-devel",
            .ubuntu_name = "zlib1g-dev",
            .debian_name = "zlib1g-dev",
            .arch_name = "zlib",
            .opensuse_name = "zlib-devel",
            .description = "zlib compression library development files",
            .category = .library,
            .popularity = 0.9,
        });

        // libcurl
        try self.addMapping("curl-devel", .{
            .fedora_name = "libcurl-devel",
            .ubuntu_name = "libcurl4-openssl-dev",
            .debian_name = "libcurl4-openssl-dev",
            .arch_name = "curl",
            .opensuse_name = "libcurl-devel",
            .description = "libcurl development files",
            .category = .network,
            .popularity = 0.8,
        });
    }

    fn addMapping(self: *Self, canonical_name: String, config: struct {
        fedora_name: ?String = null,
        ubuntu_name: ?String = null,
        debian_name: ?String = null,
        arch_name: ?String = null,
        opensuse_name: ?String = null,
        description: ?String = null,
        category: PackageCategory = .unknown,
        popularity: f32 = 0.5,
    }) !void {
        var mapping = PackageMapping.init(try self.allocator.dupe(u8, canonical_name));
        mapping.fedora_name = if (config.fedora_name) |s| try self.allocator.dupe(u8, s) else null;
        mapping.ubuntu_name = if (config.ubuntu_name) |s| try self.allocator.dupe(u8, s) else null;
        mapping.debian_name = if (config.debian_name) |s| try self.allocator.dupe(u8, s) else null;
        mapping.arch_name = if (config.arch_name) |s| try self.allocator.dupe(u8, s) else null;
        mapping.opensuse_name = if (config.opensuse_name) |s| try self.allocator.dupe(u8, s) else null;
        mapping.description = if (config.description) |s| try self.allocator.dupe(u8, s) else null;
        mapping.category = config.category;
        mapping.popularity = config.popularity;
        mapping.last_verified = std.time.timestamp();

        const key = try self.allocator.dupe(u8, canonical_name);
        try self.mappings.put(key, mapping);
    }

    pub fn translatePackage(self: *Self, package_name: String, target_distro: distro.DistroType) !?String {
        print("Translating package '{s}' for {s}\n", .{ package_name, target_distro.toString() });

        if (self.mappings.get(package_name)) |mapping| {
            if (mapping.getNameForDistro(target_distro)) |translated| {
                print("Found exact mapping: {s} -> {s}\n", .{ package_name, translated });
                return try self.allocator.dupe(u8, translated);
            }
        }

        // We need to try fuzzy matching as it might be a slightly different name.
        const fuzzy_result = try self.fuzzyMatchPackage(package_name, target_distro);
        if (fuzzy_result) |result| {
            return result;
        }

        // If we have internet, try to discover the mapping
        if (network.isOnline()) {
            print("No mapping found, trying online discovery...\n");
            const discovered = try self.discoverPackageMapping(package_name, target_distro); // TODO : Explore this a little more to ensure completeness
            // current system is fine as you can probably export your own packages then install htem from a text file like "pip install  -r requirements.txt"
            if (discovered) |result| {
                return result;
            }
        }

        // Last resort - maybe it's the same name everywhere (unlikely but possible. firefox will always be firefox.)
        if (try self.verifyPackageExists(package_name, target_distro)) {
            print("Package exists with same name across distros: {s}\n", .{package_name});
            return try self.allocator.dupe(u8, package_name);
        }

        print("Could not translate package: {s}\n", .{package_name});
        return null;
    }

    fn fuzzyMatchPackage(self: *Self, package_name: String, target_distro: distro.DistroType) !?String {
        // Fuzzy matching for when package names are slightly different, which takes a decent edgecase off our heads.
        var best_match: ?String = null;
        var best_score: f32 = 0.7; // Minimum similarity threshold

        var iterator = self.mappings.iterator();
        while (iterator.next()) |entry| {
            const mapping = entry.value_ptr;

            // Check canonical name similarity
            const canonical_score = calculateSimilarity(package_name, mapping.canonical_name);
            if (canonical_score > best_score) {
                if (mapping.getNameForDistro(target_distro)) |translated| {
                    best_match = translated;
                    best_score = canonical_score;
                }
            }

            // Also check if the input matches any of the distro-specific names
            const distro_names = [_]?String{
                mapping.fedora_name,
                mapping.ubuntu_name,
                mapping.debian_name,
                mapping.arch_name,
                mapping.opensuse_name,
            };

            for (distro_names) |maybe_name| {
                if (maybe_name) |name| {
                    const score = calculateSimilarity(package_name, name);
                    if (score > best_score) {
                        if (mapping.getNameForDistro(target_distro)) |translated| {
                            best_match = translated;
                            best_score = score;
                        }
                    }
                }
            }
        }

        if (best_match) |match| {
            print("Found fuzzy match: {s} -> {s} (score: {d:.2})\n", .{ package_name, match, best_score });
            return try self.allocator.dupe(u8, match);
        }

        return null;
    }

    // Online discovery - the nuclear option
    fn discoverPackageMapping(self: *Self, package_name: String, target_distro: distro.DistroType) !?String {
        // Rate limiting - don't spam the repos
        self.rate_limiter.waitIfNeeded();

        // Try different naming patterns common across distros
        const patterns = [_]String{
            package_name, // Exact name
            // TODO : Remember to do this the other way round.
            try std.fmt.allocPrint(self.allocator, "lib{s}", .{package_name}), // lib prefix
            try std.fmt.allocPrint(self.allocator, "{s}-dev", .{package_name}), // -dev suffix
            try std.fmt.allocPrint(self.allocator, "{s}-devel", .{package_name}), // -devel suffix
            try std.fmt.allocPrint(self.allocator, "lib{s}-dev", .{package_name}), // lib + dev
        };
        defer {
            // Clean up allocated patterns
            for (patterns[1..]) |pattern| {
                self.allocator.free(pattern);
            }
        }

        for (patterns) |pattern| {
            const exists = switch (target_distro) {
                .fedora => blk: {
                    const url = try std.fmt.allocPrint(self.allocator, "https://packages.fedoraproject.org/pkgs/{s}/", .{pattern});
                    defer self.allocator.free(url);
                    break :blk self.repo_checker.checkRepository(url) catch false;
                },
                .ubuntu, .debian => blk: {
                    const url = try std.fmt.allocPrint(self.allocator, "https://packages.ubuntu.com/search?keywords={s}", .{pattern});
                    defer self.allocator.free(url);
                    break :blk self.repo_checker.checkRepository(url) catch false;
                },
                .arch => blk: {
                    const url = try std.fmt.allocPrint(self.allocator, "https://archlinux.org/packages/?q={s}", .{pattern});
                    defer self.allocator.free(url); // okay, off topic but I absolutely wanna thank mr. Andrew for this feature. It's pretty cool.
                    // I like rust, yeah but imo, it's too strict to be productive in. This is rust but more productive. I kinda wish it had traits though
                    // because in as much as polymorphism can be a dick to deal with, there are cases where it's stupidly useful. For example,
                    // imagine a state manager... wait, doesn't zig have a dynamic dispach thing?? what is comptime for again?
                    break :blk self.repo_checker.checkRepository(url) catch false;
                },
                else => false,
            };

            if (exists) {
                print("Discovered package mapping: {s} -> {s} on {s}\n", .{ package_name, pattern, target_distro.toString() });

                try self.cacheDiscoveredMapping(package_name, pattern, target_distro);

                // Rate limiter automatically records the request
                return try self.allocator.dupe(u8, pattern);
            }

            // Small delay between pattern checks
            std.time.sleep(500 * std.time.ns_per_ms);
        }

        // Rate limiter automatically records the request
        return null;
    }

    fn cacheDiscoveredMapping(self: *Self, original_name: String, discovered_name: String, target_distro: distro.DistroType) !void {
        // from this point I think it's actually pretty obvious. I am still insecure about the package search thingymagic but it should be fine?
        if (self.mappings.getPtr(original_name)) |existing| {
            switch (target_distro) {
                .fedora => {
                    if (existing.fedora_name) |old| self.allocator.free(old);
                    existing.fedora_name = try self.allocator.dupe(u8, discovered_name);
                },
                .ubuntu => {
                    if (existing.ubuntu_name) |old| self.allocator.free(old);
                    existing.ubuntu_name = try self.allocator.dupe(u8, discovered_name);
                },
                .debian => {
                    if (existing.debian_name) |old| self.allocator.free(old);
                    existing.debian_name = try self.allocator.dupe(u8, discovered_name);
                },
                .arch => {
                    if (existing.arch_name) |old| self.allocator.free(old);
                    existing.arch_name = try self.allocator.dupe(u8, discovered_name);
                },
                .opensuse_leap, .opensuse_tumbleweed => {
                    if (existing.opensuse_name) |old| self.allocator.free(old);
                    existing.opensuse_name = try self.allocator.dupe(u8, discovered_name);
                },
                .unknown, .mint, .nixos => return, // Can't cache for these
            }

            existing.category = PackageCategory.fromString(discovered_name);
            existing.last_verified = std.time.timestamp();
            return;
        }

        // Insert new mapping
        var mapping = PackageMapping.init(try self.allocator.dupe(u8, original_name));
        switch (target_distro) {
            .fedora => mapping.fedora_name = try self.allocator.dupe(u8, discovered_name),
            .ubuntu => mapping.ubuntu_name = try self.allocator.dupe(u8, discovered_name),
            .debian => mapping.debian_name = try self.allocator.dupe(u8, discovered_name),
            .arch => mapping.arch_name = try self.allocator.dupe(u8, discovered_name),
            .opensuse_leap, .opensuse_tumbleweed => mapping.opensuse_name = try self.allocator.dupe(u8, discovered_name),
            .unknown, .mint, .nixos => return, // Can't cache for these
        }
        mapping.category = PackageCategory.fromString(discovered_name);
        mapping.last_verified = std.time.timestamp();

        const key = try self.allocator.dupe(u8, original_name);
        try self.mappings.put(key, mapping);
    }

    fn verifyPackageExists(self: *Self, package_name: String, target_distro: distro.DistroType) !bool {
        return switch (target_distro) {
            .fedora => blk: {
                const url = try std.fmt.allocPrint(self.allocator, "https://packages.fedoraproject.org/pkgs/{s}/", .{package_name});
                defer self.allocator.free(url);
                break :blk self.repo_checker.checkRepository(url) catch false;
            },
            .ubuntu, .debian => blk: {
                const url = try std.fmt.allocPrint(self.allocator, "https://packages.ubuntu.com/search?keywords={s}", .{package_name});
                defer self.allocator.free(url);
                break :blk self.repo_checker.checkRepository(url) catch false;
            },
            .arch => blk: {
                const url = try std.fmt.allocPrint(self.allocator, "https://archlinux.org/packages/?q={s}", .{package_name});
                defer self.allocator.free(url);
                break :blk self.repo_checker.checkRepository(url) catch false;
            },
            else => false,
        };
    }

    // Load cached mappings from disk
    fn loadCachedMappings(self: *Self) !void {
        const file = std.fs.openFileAbsolute(self.cache_file, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                print("No cached package mappings found (this is normal for first run)\n", .{});
                return;
            },
            else => return err,
        };
        defer file.close();

        print("Loading cached package mappings from {s}\n", .{self.cache_file});

        const content = try file.readToEndAlloc(self.allocator, 10 * 1024 * 1024);
        defer self.allocator.free(content);

        // Lightweight line-based parsing
        // Format: canonical|fedora:name|ubuntu:name|...
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            if (line.len == 0 or line[0] == '#') continue; // Skip empty lines and comments

            // Parse lines like: canonical_name|fedora:name|ubuntu:name|...
            var parts = std.mem.splitScalar(u8, line, '|');
            const canonical = parts.next() orelse continue;

            var mapping = PackageMapping.init(try self.allocator.dupe(u8, canonical));

            while (parts.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t\r");
                if (trimmed.len == 0) continue;
                if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon_idx| {
                    const distro_name = trimmed[0..colon_idx];
                    const package_name = trimmed[colon_idx + 1 ..];

                    if (std.mem.eql(u8, distro_name, "fedora")) {
                        mapping.fedora_name = try self.allocator.dupe(u8, package_name);
                    } else if (std.mem.eql(u8, distro_name, "ubuntu")) {
                        mapping.ubuntu_name = try self.allocator.dupe(u8, package_name);
                    } else if (std.mem.eql(u8, distro_name, "debian")) {
                        mapping.debian_name = try self.allocator.dupe(u8, package_name);
                    } else if (std.mem.eql(u8, distro_name, "arch")) {
                        mapping.arch_name = try self.allocator.dupe(u8, package_name);
                    } else if (std.mem.eql(u8, distro_name, "opensuse")) {
                        mapping.opensuse_name = try self.allocator.dupe(u8, package_name);
                    }
                }
            }

            const key = try self.allocator.dupe(u8, canonical);
            try self.mappings.put(key, mapping);
        }

        print("Loaded {d} cached package mappings\n", .{self.mappings.count()});
    }

    fn saveCachedMappings(self: *Self) !void {
        // Ensure the config directory exists so we can actually save this to disk.
        const config_dir = std.fs.path.dirname(self.cache_file) orelse return;
        std.fs.makeDirAbsolute(config_dir) catch {};

        const file = try std.fs.createFileAbsolute(self.cache_file, .{});
        defer file.close();

        print("Saving package mappings to {s}\n", .{self.cache_file});

        try file.writeAll("# Krowno package mappings cache\n");
        try file.writeAll("# Format: canonical_name|distro:package_name|...\n\n");

        var iterator = self.mappings.iterator();
        while (iterator.next()) |entry| {
            const mapping = entry.value_ptr;

            try file.writer().print("{s}", .{mapping.canonical_name});

            if (mapping.fedora_name) |name| {
                try file.writer().print("|fedora:{s}", .{name});
            }
            if (mapping.ubuntu_name) |name| {
                try file.writer().print("|ubuntu:{s}", .{name});
            }
            if (mapping.debian_name) |name| {
                try file.writer().print("|debian:{s}", .{name});
            }
            if (mapping.arch_name) |name| {
                try file.writer().print("|arch:{s}", .{name});
            }
            if (mapping.opensuse_name) |name| {
                try file.writer().print("|opensuse:{s}", .{name});
            }

            try file.writeAll("\n");
        }

        print("Saved {d} package mappings\n", .{self.mappings.count()});
    }

    pub fn translatePackageList(self: *Self, packages: []const String, target_distro: distro.DistroType) !ArrayList(String) {
        var result = ArrayList(String).init(self.allocator);
        errdefer result.deinit();

        print("Batch translating {d} packages for {s}\n", .{ packages.len, target_distro.toString() });

        for (packages) |package| {
            if (try self.translatePackage(package, target_distro)) |translated| {
                try result.append(translated);
            } else {
                // Keep original name as fallback
                print("Warning: Could not translate '{s}', keeping original name\n", .{package});
                try result.append(try self.allocator.dupe(u8, package));
            }

            // Small delay between translations to avoid overwhelming repos
            if (packages.len > 10) {
                std.time.sleep(100 * std.time.ns_per_ms);
            }
        }

        return result;
    }

    pub fn installPackage(self: *Self, package_name: String) !void {
        print("Installing package: {s}\n", .{package_name});

        // Detect current distro to use correct package manager
        const current_distro = try distro.detectDistro(self.allocator);
        defer current_distro.deinit(self.allocator);

        const install_cmd = switch (current_distro.distro_type) {
            .fedora => try std.fmt.allocPrint(self.allocator, "sudo dnf install -y {s}", .{package_name}),
            .ubuntu, .debian, .mint => try std.fmt.allocPrint(self.allocator, "sudo apt install -y {s}", .{package_name}),
            .arch => try std.fmt.allocPrint(self.allocator, "sudo pacman -S --noconfirm {s}", .{package_name}),
            .opensuse_leap, .opensuse_tumbleweed => try std.fmt.allocPrint(self.allocator, "sudo zypper install -y {s}", .{package_name}),
            .nixos => try std.fmt.allocPrint(self.allocator, "nix-env -i {s}", .{package_name}),
            .unknown => {
                print("Unknown distribution, cannot install package: {s}\n", .{package_name});
                return;
            },
        };
        defer self.allocator.free(install_cmd);

        print("Running: {s}\n", .{install_cmd});

        // Execute the installation command.
        var child = std.process.Child.init(&[_]String{ "sh", "-c", install_cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);

        const term = try child.wait();

        if (term.Exited == 0) {
            print("Successfully installed package: {s}\n", .{package_name});
        } else {
            print("Failed to install package {s}: {s}\n", .{ package_name, stderr });
            return PackageResolverError.PackageNotFound;
        }
    }

    pub fn installFlatpakPackage(self: *Self, package_name: String) !void {
        print("Installing Flatpak package: {s}\n", .{package_name});

        const install_cmd = try std.fmt.allocPrint(self.allocator, "flatpak install -y {s}", .{package_name});
        defer self.allocator.free(install_cmd);

        print("Running: {s}\n", .{install_cmd});

        var child = std.process.Child.init(&[_]String{ "sh", "-c", install_cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);

        const term = try child.wait();

        if (term.Exited == 0) {
            print("Successfully installed Flatpak package: {s}\n", .{package_name});
        } else {
            print("Failed to install Flatpak package {s}: {s}\n", .{ package_name, stderr });
            return PackageResolverError.PackageNotFound;
        }
    }

    pub fn getFlatpakPackages(self: *Self) !ArrayList(String) {
        var packages = ArrayList(String).init(self.allocator);
        errdefer {
            for (packages.items) |pkg| {
                self.allocator.free(pkg);
            }
            packages.deinit();
        }

        const flatpak_cmd = "flatpak list --app --columns=application 2>/dev/null || echo 'flatpak not available'";
        print("Detecting Flatpak packages using: {s}\n", .{flatpak_cmd});

        var child = std.process.Child.init(&[_]String{ "sh", "-c", flatpak_cmd }, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stdout);

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 1024 * 1024);
        defer self.allocator.free(stderr);

        const term = try child.wait();

        if (term.Exited == 0) {
            var lines = std.mem.splitScalar(u8, stdout, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r\n");
                if (trimmed.len > 0 and !std.mem.eql(u8, trimmed, "flatpak not available")) {
                    try packages.append(try self.allocator.dupe(u8, trimmed));
                }
            }
        } else {
            print("Flatpak not available or failed: {s}\n", .{stderr});
        }

        return packages;
    }

    pub fn getInstalledPackages(self: *Self) !ArrayList(String) {
        var packages = ArrayList(String).init(self.allocator);
        errdefer {
            for (packages.items) |pkg| {
                self.allocator.free(pkg);
            }
            packages.deinit();
        }

        // Detect current distro to use correct package manager
        const current_distro = try distro.detectDistro(self.allocator);
        defer current_distro.deinit(self.allocator);

        var argv_buf: [6]String = undefined;
        var argv: []String = argv_buf[0..0];
        switch (current_distro.distro_type) {
            .fedora, .opensuse_leap, .opensuse_tumbleweed => {
                // rpm is fast and does not require python/dnf, both openSUSE variants use rpm
                argv = argv_buf[0..4];
                argv[0] = "rpm";
                argv[1] = "-qa";
                argv[2] = "--qf";
                argv[3] = "%{NAME}\n";
            },
            .ubuntu, .debian, .mint => {
                argv = argv_buf[0..3];
                argv[0] = "dpkg-query";
                argv[1] = "-W";
                argv[2] = "-f=${Package}\n";
            },
            .arch => {
                argv = argv_buf[0..3];
                argv[0] = "pacman";
                argv[1] = "-Qqe";
                argv[2] = "--color=never";
            },
            else => {
                // Fallback to some common packages
                try packages.append(try self.allocator.dupe(u8, "gcc"));
                try packages.append(try self.allocator.dupe(u8, "make"));
                try packages.append(try self.allocator.dupe(u8, "git"));
                try packages.append(try self.allocator.dupe(u8, "vim"));
                return packages;
            },
        }

        print("Detecting installed packages via argv: ", .{});
        for (argv, 0..) |a, i| if (i < argv.len and a.len > 0) print("{s} ", .{a});
        print("\n", .{});

        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();

        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 2 * 1024 * 1024);
        defer self.allocator.free(stdout);

        const stderr = try child.stderr.?.readToEndAlloc(self.allocator, 256 * 1024);
        defer self.allocator.free(stderr);

        const term = try child.wait();

        if (term == .Exited and term.Exited == 0) {
            var lines = std.mem.splitScalar(u8, stdout, '\n');
            var count: usize = 0;
            while (lines.next()) |line| : (count += 1) {
                if (count >= 200) break;
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;
                // Simple validation: package names are alnum plus '-','_','.'
                var valid = true;
                for (trimmed) |ch| {
                    if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.')) {
                        valid = false;
                        break;
                    }
                }
                if (!valid) continue;
                // For rpm-derived names, drop trailing .arch if present
                var clean = trimmed;
                if (current_distro.distro_type == .fedora or
                    current_distro.distro_type == .opensuse_leap or
                    current_distro.distro_type == .opensuse_tumbleweed)
                {
                    if (std.mem.indexOfScalar(u8, trimmed, '.')) |dot_pos| {
                        clean = trimmed[0..dot_pos];
                    }
                }
                try packages.append(try self.allocator.dupe(u8, clean));
            }
        } else {
            print("Failed to list packages (exit non-zero). stderr:\n{s}\n", .{stderr});
            // Fallback to some common packages
            try packages.append(try self.allocator.dupe(u8, "gcc"));
            try packages.append(try self.allocator.dupe(u8, "make"));
            try packages.append(try self.allocator.dupe(u8, "git"));
            try packages.append(try self.allocator.dupe(u8, "vim"));
        }

        return packages;
    }

    pub const CrossPlatformMapping = struct {
        source_package: String,
        target_distro: String,
        package_name: String,
        confidence: f32,
    };

    pub fn resolveCrossPlatform(self: *Self, package: String) !ArrayList(CrossPlatformMapping) {
        var mappings = ArrayList(CrossPlatformMapping).init(self.allocator);
        errdefer {
            // Clean up any allocated memory on error
            for (mappings.items) |mapping| {
                self.allocator.free(mapping.source_package);
                self.allocator.free(mapping.package_name);
            }
            mappings.deinit();
        }

        // Try to find actual mappings first
        if (self.mappings.get(package)) |mapping| {
            // Create mappings for each distro that has this package
            if (mapping.fedora_name) |name| {
                try mappings.append(.{
                    .source_package = try self.allocator.dupe(u8, package),
                    .target_distro = "fedora",
                    .package_name = try self.allocator.dupe(u8, name),
                    .confidence = 0.9,
                });
            }
            if (mapping.ubuntu_name) |name| {
                try mappings.append(.{
                    .source_package = try self.allocator.dupe(u8, package),
                    .target_distro = "ubuntu",
                    .package_name = try self.allocator.dupe(u8, name),
                    .confidence = 0.9,
                });
            }
            if (mapping.arch_name) |name| {
                try mappings.append(.{
                    .source_package = try self.allocator.dupe(u8, package),
                    .target_distro = "arch",
                    .package_name = try self.allocator.dupe(u8, name),
                    .confidence = 0.9,
                });
            }
        } else {
            // Fallback: assume package name is the same across distros
            try mappings.append(.{
                .source_package = try self.allocator.dupe(u8, package),
                .target_distro = "fedora",
                .package_name = try self.allocator.dupe(u8, package),
                .confidence = 0.5, // Lower confidence for fallback
            });
        }

        return mappings;
    }

    pub fn getStats(self: *const Self) PackageResolverStats {
        var stats = PackageResolverStats{
            .total_mappings = self.mappings.count(),
            .fedora_mappings = 0,
            .ubuntu_mappings = 0,
            .debian_mappings = 0,
            .arch_mappings = 0,
            .opensuse_mappings = 0,
            .categories = [_]u32{0} ** 10,
        };

        var iterator = self.mappings.iterator();
        while (iterator.next()) |entry| {
            const mapping = entry.value_ptr;

            if (mapping.fedora_name != null) stats.fedora_mappings += 1;
            if (mapping.ubuntu_name != null) stats.ubuntu_mappings += 1;
            if (mapping.debian_name != null) stats.debian_mappings += 1;
            if (mapping.arch_name != null) stats.arch_mappings += 1;
            if (mapping.opensuse_name != null) stats.opensuse_mappings += 1;

            const cat_idx = @intFromEnum(mapping.category);
            if (cat_idx < stats.categories.len) {
                stats.categories[cat_idx] += 1;
            }
        }

        return stats;
    }
};

pub const PackageResolverStats = struct {
    total_mappings: u32,
    fedora_mappings: u32,
    ubuntu_mappings: u32,
    debian_mappings: u32,
    arch_mappings: u32,
    opensuse_mappings: u32,
    categories: [10]u32, // One for each PackageCategory enum value
};

fn calculateSimilarity(a: String, b: String) f32 {
    // Simple string similarity calculation using Levenshtein-ish algorithm
    // https://en.wikipedia.org/wiki/Levenshtein_distance
    if (a.len == 0 or b.len == 0) return 0.0;
    if (std.mem.eql(u8, a, b)) return 1.0;

    // Simple similarity based on common characters and length difference
    var common_chars: u32 = 0;
    const min_len = @min(a.len, b.len);

    for (a[0..min_len], b[0..min_len]) |char_a, char_b| {
        if (char_a == char_b) {
            common_chars += 1;
        }
    }

    const length_penalty = @as(f32, @floatFromInt(@max(a.len, b.len) - min_len)) * 0.1;
    const similarity = @as(f32, @floatFromInt(common_chars)) / @as(f32, @floatFromInt(@max(a.len, b.len))) - length_penalty;

    return @max(0.0, @min(1.0, similarity));
}

pub fn cleanPackageName(allocator: Allocator, raw_name: String) !String {
    // Remove version info (everything after @ or =)
    var name = raw_name;
    if (std.mem.indexOf(u8, name, "@")) |idx| {
        name = name[0..idx];
    }
    if (std.mem.indexOf(u8, name, "=")) |idx| {
        name = name[0..idx];
    }

    // Remove architecture info (everything after the last .)
    if (std.mem.lastIndexOfScalar(u8, name, '.')) |idx| {
        const possible_arch = name[idx + 1 ..];
        // Common architecture names
        if (std.mem.eql(u8, possible_arch, "x86_64") or
            std.mem.eql(u8, possible_arch, "i686") or
            std.mem.eql(u8, possible_arch, "aarch64") or
            std.mem.eql(u8, possible_arch, "noarch"))
        {
            name = name[0..idx];
        }
    }

    return try allocator.dupe(u8, std.mem.trim(u8, name, " \t\n\r"));
}
