//! Package dependency graph - tracks what depends on what
//! Used during restore to figure out install order and detect circular deps.
//! package managers dont always get this right

//! some distros have circular dependencies (looking at you systemd)
//! need cycle detection to handle it

const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.hash_map.HashMap;
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;

pub const DependencyNode = struct {
    package_name: String,
    version: String,
    dependencies: ArrayList(String),
    dependents: ArrayList(String),
    optional: bool,
    installed: bool,

    // tracking both deps and dependents doubles memory but makes traversal faster
    // worth it for large package sets
    allocator: Allocator,

    pub fn init(allocator: Allocator, name: String, version: String) !DependencyNode {
        return DependencyNode{
            .package_name = try allocator.dupe(u8, name),
            .version = try allocator.dupe(u8, version),
            .dependencies = ArrayList(String).init(allocator),
            .dependents = ArrayList(String).init(allocator),
            .optional = false,
            .installed = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *DependencyNode) void {
        self.allocator.free(self.package_name);
        self.allocator.free(self.version);
        for (self.dependencies.items) |dep| {
            self.allocator.free(dep);
        }
        self.dependencies.deinit();
        for (self.dependents.items) |dep| {
            self.allocator.free(dep);
        }
        self.dependents.deinit();
    }
};

pub const DependencyGraph = struct {
    allocator: Allocator,
    nodes: HashMap(String, DependencyNode, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
            .nodes = HashMap(String, DependencyNode, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit();
        }
        self.nodes.deinit();
    }

    pub fn addPackage(self: *Self, name: String, version: String) !void {
        if (self.nodes.contains(name)) {
            return;
        }

        const node = try DependencyNode.init(self.allocator, name, version);
        const key = try self.allocator.dupe(u8, name);
        try self.nodes.put(key, node);
    }

    pub fn addDependency(self: *Self, package: String, dependency: String) !void {
        if (self.nodes.getPtr(package)) |node| {
            const dep_copy = try self.allocator.dupe(u8, dependency);
            try node.dependencies.append(dep_copy);
        }

        if (self.nodes.getPtr(dependency)) |dep_node| {
            const pkg_copy = try self.allocator.dupe(u8, package);
            try dep_node.dependents.append(pkg_copy);
        }
    }


    pub fn getInstallOrder(self: *Self) !ArrayList(String) {
        var order = ArrayList(String).init(self.allocator);
        var visited = HashMap(String, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer visited.deinit();

        // using recursive DFS instead of Kahn's algorithm.
        // watch out for stack overflow with huge dependency graphs. I don't think this is necessary but I have had weird
        // situations where you find hat I actually install something but it whines about dependencies. For example,
        // video players. Like tf, why don't you install them when you are installed, bitch. Gosh!
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            try self.topologicalSort(entry.key_ptr.*, &order, &visited);
        }

        return order;// Returns packages in topological order - dependencies before dependents. This is the order you should install packages to avoid missing deps.
        // Like if you install vlc right? it might ask for SDL1 or Relm might ask for GTK
    }

    fn topologicalSort(self: *Self, package: String, order: *ArrayList(String), visited: *HashMap(String, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage)) !void {
        if (visited.contains(package)) {
            return;
        }

        try visited.put(package, {});

        if (self.nodes.get(package)) |node| {
            for (node.dependencies.items) |dep| {
                try self.topologicalSort(dep, order, visited);
            }
        }

        try order.append(try self.allocator.dupe(u8, package));
    }

    pub fn detectCycles(self: *Self) !?ArrayList(String) {
        // We want to check for circular dependencies. Returns the cycle if found, null otherwise. Maybe Floyd Algorithm would be neat here??
        // but eh.
        // Circular deps are rare but they happen (looking at you, systemd).
        var visited = HashMap(String, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer visited.deinit();
        var rec_stack = HashMap(String, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(self.allocator);
        defer rec_stack.deinit();

        // recursion stack tracks current path to catch all cycles
        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            if (try self.hasCycle(entry.key_ptr.*, &visited, &rec_stack)) {
                var cycle = ArrayList(String).init(self.allocator);
                var stack_iter = rec_stack.iterator();
                while (stack_iter.next()) |stack_entry| {
                    try cycle.append(try self.allocator.dupe(u8, stack_entry.key_ptr.*));
                }
                return cycle;
            }
        }

        return null;
    }


    fn hasCycle(self: *Self, package: String, visited: *HashMap(String, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage), rec_stack: *HashMap(String, void, std.hash_map.StringContext, std.hash_map.default_max_load_percentage)) !bool {
        // DFS cycle detection using recursion stack... so... o(n) for linked list and do Floyd which is also o(n) but better...
        // meh.
        if (!visited.contains(package)) {
            try visited.put(package, {});
            try rec_stack.put(package, {});

            if (self.nodes.get(package)) |node| {
                for (node.dependencies.items) |dep| {
                    if (!visited.contains(dep)) {
                        if (try self.hasCycle(dep, visited, rec_stack)) {
                            return true;
                        }
                    } else if (rec_stack.contains(dep)) {
                        return true;
                    }
                }
            }
        }

        _ = rec_stack.remove(package);
        return false;
    }


    pub fn getMissingDependencies(self: *Self) !ArrayList(String) {
        var missing = ArrayList(String).init(self.allocator);

        var iter = self.nodes.iterator();
        while (iter.next()) |entry| {
            for (entry.value_ptr.dependencies.items) |dep| {
                if (!self.nodes.contains(dep)) {
                    try missing.append(try self.allocator.dupe(u8, dep));// Find dependencies that are
                    //referenced but not in the graph. These need to be resolved before we can proceed.
                }
            }
        }

        return missing;
    }

    pub fn findFallbacks(self: *Self, package: String) !ArrayList(String) {
        // Find alternative packages that could replace this one. Useful when a package isn't available on the target distro.
        var fallbacks = ArrayList(String).init(self.allocator);

        if (self.nodes.get(package)) |node| {
            var iter = self.nodes.iterator();
            while (iter.next()) |entry| {
                for (entry.value_ptr.dependencies.items) |dep| {
                    if (std.mem.eql(u8, dep, package)) {
                        for (node.dependencies.items) |alt_dep| {
                            if (!std.mem.eql(u8, alt_dep, package)) {
                                try fallbacks.append(try self.allocator.dupe(u8, alt_dep));
                            }
                        }
                    }
                }
            }
        }

        return fallbacks;
    }
};
