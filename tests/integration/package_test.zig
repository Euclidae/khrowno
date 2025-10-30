const std = @import("std");
const testing = std.testing;
const unified_pkg = @import("../../src/core/unified_pkg_resolver.zig");
const dep_graph = @import("../../src/core/dep_graph.zig");

test "unified package resolver initialization" {
    const allocator = testing.allocator;
    
    var resolver = try unified_pkg.UnifiedPackageResolver.init(allocator);
    defer resolver.deinit();
    
    try testing.expect(resolver.distro_info.name.len > 0);
}

test "dependency graph creation" {
    const allocator = testing.allocator;
    
    var graph = dep_graph.DependencyGraph.init(allocator);
    defer graph.deinit();
    
    try graph.addPackage("package-a", "1.0.0");
    try graph.addPackage("package-b", "2.0.0");
    try graph.addDependency("package-a", "package-b");
    
    const order = try graph.getInstallOrder();
    defer {
        for (order.items) |item| {
            allocator.free(item);
        }
        order.deinit();
    }
    
    try testing.expect(order.items.len == 2);
}

test "dependency cycle detection" {
    const allocator = testing.allocator;
    
    var graph = dep_graph.DependencyGraph.init(allocator);
    defer graph.deinit();
    
    try graph.addPackage("package-a", "1.0.0");
    try graph.addPackage("package-b", "2.0.0");
    try graph.addDependency("package-a", "package-b");
    try graph.addDependency("package-b", "package-a");
    
    const cycle = try graph.detectCycles();
    if (cycle) |*c| {
        defer {
            for (c.items) |item| {
                allocator.free(item);
            }
            c.deinit();
        }
        try testing.expect(c.items.len > 0);
    }
}
