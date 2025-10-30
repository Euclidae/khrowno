const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "krowno",
        .root_module = exe_module,
    });

    exe.linkLibC();
    exe.addIncludePath(b.path("src"));

    // Linux-only dependencies (GTK/GLib/curl/zlib)
    if (target.result.os.tag == .linux) {
        // Add GTK4 include paths (try both common locations)
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/gtk-4.0" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/pango-1.0" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/cairo" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/gdk-pixbuf-2.0" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/graphene-1.0" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/libpng16" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/gio-unix-2.0" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/include/glib-2.0" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/lib64/glib-2.0/include" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu/glib-2.0/include" });
        exe.addIncludePath(.{ .cwd_relative = "/usr/lib64/graphene-1.0/include" });

        // Link GTK4 and GLib
        exe.linkSystemLibrary("gtk-4");
        exe.linkSystemLibrary("glib-2.0");
        exe.linkSystemLibrary("gobject-2.0");
        exe.linkSystemLibrary("gio-2.0");
        exe.linkSystemLibrary("curl");
        exe.linkSystemLibrary("z");
    }

    // C bindings are Linux-only
    if (target.result.os.tag == .linux) {
        if (std.fs.cwd().access("src/c_bindings.c", .{})) |_| {
            exe.addCSourceFile(.{
                .file = b.path("src/c_bindings.c"),
                .flags = &[_][]const u8{
                    "-std=c11",
                    "-D_GNU_SOURCE",
                    "-O2",
                    "-fstack-protector",
                    "-D_FORTIFY_SOURCE=2",
                    "-Wall",
                    "-Wextra",
                },
            });
        } else |_| {
            std.debug.print("Note: C bindings not found, using Zig-only implementation\n", .{});
        }
    }

    b.installArtifact(exe);

    // Run command for testing
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the backup tool");
    run_step.dependOn(&run_cmd.step);

    // Test step for integration tests
    const test_step = b.step("test", "Run integration tests");

    const test_files = [_][]const u8{
        "tests/integration/distro_test.zig",
        "tests/integration/backup_test.zig",
        "tests/integration/restore_test.zig",
        "tests/integration/package_test.zig",
        "tests/integration/config_test.zig",
    };

    for (test_files) |test_file| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });

        const test_exe = b.addTest(.{
            .root_module = test_module,
        });

        test_exe.linkLibC();
        if (target.result.os.tag == .linux) {
            test_exe.linkSystemLibrary("curl");
            test_exe.linkSystemLibrary("z");
        }

        const run_test = b.addRunArtifact(test_exe);
        test_step.dependOn(&run_test.step);
    }

    // Simple completion message
    const print_info = b.addSystemCommand(&[_][]const u8{ "echo", "Krowno backup tool build complete!" });
    b.getInstallStep().dependOn(&print_info.step);
}
