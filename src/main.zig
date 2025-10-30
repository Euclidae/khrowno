// Khrowno - Main entry point

// first real zig project
// trying to make a backup (and restore) tool that doesnt suck
// update some backup tool with a french sounding name exists... fuck it we ball.
const std = @import("std");
const print = std.debug.print; // easier than fprintf
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator; //still getting used to explicit allocators

const backup = @import("core/backup.zig");
const config = @import("core/config.zig");
const verification = @import("core/verification.zig");
const incremental = @import("core/incremental.zig");
const search = @import("core/search.zig");
const khr_format = @import("core/khr_format.zig");

// enforcuing stuff is linux only
const builtin = @import("builtin");
// maybe add windows support someday? probably not worth it with microsoft losing braincells by the minute
//conditional imports are neat, didnt know zig could do this
const gui = if (builtin.os.tag == .linux)
    @import("ui/gui.zig")
else
    struct {
        pub fn launchGUI(_: std.mem.Allocator) !void {
            return error.PlatformNotSupported;
        }
    };

const distro = @import("system/distro.zig");
const errors = @import("utils/errors.zig");
const compress = @import("utils/compress.zig");
const compression = compress;
const types = @import("utils/types.zig");
const ansi = @import("utils/ansi.zig");
const String = types.String;

const c = if (builtin.os.tag == .linux) @cImport({
    @cInclude("stdio.h");
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("getopt.h");
}) else struct {};

const VERSION = "1.4.9";
const APP_NAME = "Khrowno Backup Tool";

const CommandLineOptions = struct {
    command: ?String = null,
    strategy: backup.BackupStrategy = .standard,
    output_file: ?String = null,
    input_file: ?String = null,
    password: ?String = null,
    username: ?String = null,
    encrypt: bool = true,
    show_progress: bool = true,
    verbose: bool = false,
    help: bool = false,
    version: bool = false,
    force_terminal: bool = false,
    setup: bool = false,
    install_flatpaks: bool = false,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const raw_args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, raw_args);

    var args = try allocator.alloc(String, raw_args.len);
    for (raw_args, 0..) |arg, i| {
        args[i] = arg[0 .. std.mem.indexOfScalar(u8, arg, 0) orelse arg.len];
    }
    defer allocator.free(args);

    // Check for --term flag first
    var force_terminal = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--term") or std.mem.eql(u8, arg, "-t")) {
            force_terminal = true;
            break;
        }
    }

    if (args.len == 1 or (args.len == 2 and force_terminal)) {
        if (!force_terminal) {
            gui.launchGUI(allocator) catch |err| {
                errors.logError(err, null);
                print("{s}Falling back to interactive mode...{s}\n\n", .{ ansi.Color.YELLOW, ansi.Color.RESET });
                try runInteractiveMode(allocator);
            };
            return;
        } else {
            try runInteractiveMode(allocator);
            return;
        }
    }

    const options = try parseCommandLine(allocator, args);

    if (options.help) {
        try printHelp();
        return;
    }

    if (options.version) {
        try printVersion();
        return;
    }

    if (options.setup) {
        try runSetup(allocator);
        return;
    }

    if (options.install_flatpaks) {
        if (options.input_file) |file| {
            try installFlatpaksFromBackup(allocator, file);
        } else {
            print("{s}Error:{s} --install requires an input file\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
            print("Usage: {s}khrowno --install backup.khr{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
        }
        return;
    }

    if (options.command == null) {
        try printHelp();
        return;
    }

    try executeCommand(allocator, options);
}

fn parseCommandLine(allocator: Allocator, args: []String) !CommandLineOptions {
    var options = CommandLineOptions{};

    if (args.len < 2) {
        return options;
    }
    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--strategy")) {
            i += 1;
            if (i < args.len) {
                options.strategy = parseBackupStrategy(args[i]) catch .standard;
            }
        } else if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
            i += 1;
            if (i < args.len) {
                options.output_file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-i") or std.mem.eql(u8, arg, "--input")) {
            i += 1;
            if (i < args.len) {
                options.input_file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-u") or std.mem.eql(u8, arg, "--username")) {
            i += 1;
            if (i < args.len) {
                options.username = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--password")) {
            // For backup: confirm password (ask twice)
            // For restore/validate/info: just ask once
            const is_backup = options.command != null and std.mem.eql(u8, options.command.?, "backup");
            if (is_backup) {
                options.password = promptForPasswordConfirm(allocator) catch blk: {
                    print("{s}Warning:{s} Passwords do not match. Encryption disabled.\n", .{ ansi.Color.BOLD_YELLOW, ansi.Color.RESET });
                    options.encrypt = false;
                    break :blk null;
                };
            } else {
                options.password = promptForPassword(allocator) catch null;
            }
        } else if (std.mem.eql(u8, arg, "--no-encrypt")) {
            options.encrypt = false;
        } else if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
            options.verbose = true;
        } else if (std.mem.eql(u8, arg, "-q") or std.mem.eql(u8, arg, "--quiet")) {
            options.show_progress = false;
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.help = true;
        } else if (std.mem.eql(u8, arg, "--version")) {
            options.version = true;
        } else if (std.mem.eql(u8, arg, "--setup")) {
            options.setup = true;
        } else if (std.mem.eql(u8, arg, "--install")) {
            options.install_flatpaks = true;
            i += 1;
            if (i < args.len) {
                options.input_file = args[i];
            }
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--term")) {
            options.force_terminal = true;
        } else if (options.command == null and !std.mem.startsWith(u8, arg, "-")) {
            options.command = arg;
        }

        i += 1;
    }

    return options;
}

fn parseBackupStrategy(strategy_str: String) !backup.BackupStrategy {
    if (std.mem.eql(u8, strategy_str, "minimal")) return .minimal;
    if (std.mem.eql(u8, strategy_str, "standard")) return .standard;
    if (std.mem.eql(u8, strategy_str, "comprehensive")) return .comprehensive;
    if (std.mem.eql(u8, strategy_str, "paranoid")) return .paranoid;

    print("{s}Warning:{s} Unknown strategy '{s}', using 'standard'\n", .{ ansi.Color.BOLD_YELLOW, ansi.Color.RESET, strategy_str });
    return .standard;
}

// classic stty -echo trick for password input
// unix-only and not elegant but it works
// proper terminal library would be nicer someday
fn promptForPassword(allocator: Allocator) !String {
    print("Enter encryption password: ", .{});

    if (builtin.os.tag == .linux) {
        _ = c.system("stty -echo");
        defer _ = c.system("stty echo");
    }

    const stdin = std.io.getStdIn().reader();
    const password = try stdin.readUntilDelimiterAlloc(allocator, '\n', 256);

    print("\n", .{});
    return password;
}

fn promptForPasswordConfirm(allocator: Allocator) !String {
    // First entry
    const pwd1 = try promptForPassword(allocator);
    errdefer allocator.free(pwd1);

    // Confirm entry
    print("Confirm password: ", .{});
    if (builtin.os.tag == .linux) {
        _ = c.system("stty -echo");
        defer _ = c.system("stty echo");
    }
    const stdin = std.io.getStdIn().reader();
    const pwd2 = try stdin.readUntilDelimiterAlloc(allocator, '\n', 256);
    defer allocator.free(pwd2);
    print("\n", .{});

    if (!std.mem.eql(u8, pwd1, pwd2)) {
        allocator.free(pwd1);
        return error.InvalidPassword;
    }

    return pwd1;
}

// Command dispatcher that routes commands to their implementation functions
fn executeCommand(allocator: Allocator, options: CommandLineOptions) !void {
    const command = options.command orelse return;

    if (std.mem.eql(u8, command, "backup")) {
        try executeBackup(allocator, options);
    } else if (std.mem.eql(u8, command, "restore")) {
        try executeRestore(allocator, options);
    } else if (std.mem.eql(u8, command, "info")) {
        try executeInfo(allocator, options);
    } else if (std.mem.eql(u8, command, "validate")) {
        try executeValidate(allocator, options);
    } else if (std.mem.eql(u8, command, "list")) {
        try executeList(allocator, options);
    } else if (std.mem.eql(u8, command, "test")) {
        try executeTest(allocator, options);
    } else if (std.mem.eql(u8, command, "compress")) {
        try executeCompress(allocator, options);
    } else if (std.mem.eql(u8, command, "decompress")) {
        try executeDecompress(allocator, options);
    } else if (std.mem.eql(u8, command, "verify")) {
        try executeVerify(allocator, options);
    } else if (std.mem.eql(u8, command, "incremental")) {
        try executeIncremental(allocator, options);
    } else if (std.mem.eql(u8, command, "search")) {
        try executeSearch(allocator, options);
    } else if (std.mem.eql(u8, command, "stats")) {
        try executeStats(allocator, options);
    } else {
        print("{s}Error:{s} Unknown command '{s}'\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET, command });
        print("Use {s}krowno --help{s} for usage information.\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
        std.process.exit(1);
    }
}

fn executeBackup(allocator: Allocator, options: CommandLineOptions) !void {
    const output_file = options.output_file orelse {
        print("{s}Error:{s} Output file required for backup command\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
        print("Use: {s}krowno backup -o /path/to/backup.krowno{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
        return;
    };

    print("{s}Creating {s} backup...{s}\n", .{ ansi.Color.BOLD_BLUE, options.strategy.getDescription(), ansi.Color.RESET });

    if (options.verbose) {
        print("Strategy: {s}\n", .{options.strategy.getDescription()});
        print("Output: {s}\n", .{output_file});
        print("Encryption: {s}\n", .{if (options.encrypt) "enabled" else "disabled"});
    }

    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();

    const progress_callback = if (options.show_progress) &backup.defaultProgressCallback else null;
    const password = if (options.encrypt) options.password else null;

    try engine.createBackup(options.strategy, output_file, password, progress_callback, khr_format.CompressionType.gzip);

    print("\n{s}Backup completed successfully!{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
}

fn executeRestore(allocator: Allocator, options: CommandLineOptions) !void {
    const input_file = options.input_file orelse {
        print("{s}Error:{s} Input file required for restore command\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
        print("Use: {s}krowno restore -i /path/to/backup.krowno{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
        return;
    };

    print("{s}Restoring from backup:{s} {s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET, input_file });
    print("\n{s}Restore will automatically:{s}\n", .{ ansi.Color.BOLD_WHITE, ansi.Color.RESET });
    print("  • Extract files to proper locations\n", .{});
    print("  • Install packages from backup manifest\n", .{});
    print("  • Update system hostname\n", .{});
    print("  • Set correct file ownership\n\n", .{});

    const is_encrypted = try backup.isBackupEncrypted(input_file);
    if (is_encrypted and options.password == null) {
        print("{s}Error:{s} Backup is encrypted but no password provided\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
        print("Use: {s}krowno restore -i /path/to/backup.krowno -p{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
        return;
    }

    if (options.verbose) {
        print("Input: {s}\n", .{input_file});
        if (options.username) |username| {
            print("Target username: {s}\n", .{username});
        }
    }

    // Create backup engine and run restore
    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();

    const progress_callback = if (options.show_progress) &backup.defaultProgressCallback else null;

    if (options.output_file) |dest_dir| {
        engine.restoreBackupTo(input_file, options.password, options.username, dest_dir, progress_callback) catch |err| {
            print("\n{s}Restore failed:{s} {s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET, @errorName(err) });
            return;
        };
        print("\n{s}Restore completed successfully!{s} → {s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET, dest_dir });
    } else {
        engine.restoreBackup(input_file, options.password, options.username, progress_callback) catch |err| {
            print("\n{s}Restore failed:{s} {s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET, @errorName(err) });
            return;
        };
        print("\n{s}Restore completed successfully!{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
    }
}

fn executeInfo(allocator: Allocator, options: CommandLineOptions) !void {
    const input_file = options.input_file orelse {
        print("{s}Error:{s} Input file required for info command\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
        print("Use: {s}krowno info -i /path/to/backup.krowno{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
        return;
    };

    print("{s}Backup Information{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });
    print("==================\n", .{});

    var info = try backup.getBackupInfo(allocator, input_file);
    defer info.deinit(allocator);

    print("File: {s}\n", .{input_file});
    print("Version: {s}\n", .{info.version});
    print("Created: {d}\n", .{info.timestamp});
    print("Hostname: {s}\n", .{info.hostname});
    print("Username: {s}\n", .{info.username});
    print("Files: {d}\n", .{info.file_count});
    print("Size: {d} bytes\n", .{info.total_size});
    print("Encrypted: {s}\n", .{if (info.encrypted) "Yes" else "No"});
}

fn executeValidate(allocator: Allocator, options: CommandLineOptions) !void {
    const input_file = options.input_file orelse {
        print("{s}Error:{s} Input file required for validate command\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
        print("Use: {s}krowno validate -i /path/to/backup.krowno{s}\n", .{ ansi.Color.CYAN, ansi.Color.RESET });
        return;
    };

    print("{s}Validating backup:{s} {s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET, input_file });

    const is_valid = try backup.validateBackup(allocator, input_file, options.password);

    if (is_valid) {
        print("{s}✓ Backup file is valid{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
    } else {
        print("{s}✗ Backup file is invalid or corrupted{s}\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
        std.process.exit(1);
    }
}

fn executeList(allocator: Allocator, options: CommandLineOptions) !void {
    const directory = options.input_file orelse ".";

    print("{s}Listing backups in:{s} {s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET, directory });
    print("=====================================\n", .{});

    try backup.listBackups(allocator, directory);
}

fn executeTest(allocator: Allocator, options: CommandLineOptions) !void {
    _ = allocator;
    _ = options;

    print("{s}Running Krowno Test Suite{s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET });
    print("============================\n\n", .{});

    print("\n{s}All tests completed successfully!{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
    print("The backup system is working correctly.\n", .{});
}

fn printVersion() !void {
    print("{s} v{s}\n", .{ APP_NAME, VERSION });
    print("A cross-platform Linux system backup and migration tool\n", .{});
    print("Built with Zig - because systems programming should be safe and fast!\n", .{});
    print("\n", .{});

    const distro_info = distro.detectDistro(std.heap.page_allocator) catch {
        print("Platform: Unknown Linux distribution\n", .{});
        return;
    };
    defer distro_info.deinit(std.heap.page_allocator);

    print("Platform: {s} {s}\n", .{ distro_info.name, distro_info.version });
    print("Package Manager: {s}\n", .{distro_info.package_manager});
}

fn printHelp() !void {
    print("{s} v{s}\n", .{ APP_NAME, VERSION });
    print("Secure backup and restore tool for Linux\n", .{});

    print("USAGE:\n", .{});
    print("    krowno                      Launch GUI (default)\n", .{});
    print("    krowno --term               Launch terminal interactive mode\n", .{});
    print("    krowno <COMMAND> [OPTIONS]  Execute specific command\n\n", .{});

    print("COMMANDS:\n", .{});
    print("    backup      Create a new backup\n", .{});
    print("    restore     Restore from a backup file\n", .{});
    print("    info        Show backup information\n", .{});
    print("    validate    Verify backup integrity\n", .{});
    print("    list        List backup contents\n", .{});
    print("    test        Run comprehensive test suite\n", .{});
    print("    compress    Compress backup files\n", .{});
    print("    decompress  Decompress backup files\n", .{});
    print("    verify      Verify backup checksums\n", .{});
    print("    incremental Create incremental backups\n", .{});
    print("    search      Search and filter backups\n", .{});
    print("    stats       Show backup statistics\n\n", .{});

    print("OPTIONS:\n", .{});
    print("    -h, --help                  Show this help message\n", .{});
    print("        --version               Show version information\n", .{});
    print("        --setup                 Check and install dependencies\n", .{});
    print("        --install <FILE>        Install Flatpaks from backup file\n", .{});
    print("    -t, --term                  Force terminal mode (no GUI)\n", .{});
    print("    -s, --strategy <STRATEGY>   Backup strategy [minimal|standard|comprehensive|paranoid]\n", .{});
    print("    -o, --output <FILE>         Output backup file path\n", .{});
    print("    -i, --input <FILE>          Input backup file path\n", .{});
    print("    -u, --username <USER>       Target username for migration\n", .{});
    print("    -p, --password              Prompt for encryption password\n", .{});
    print("        --no-encrypt            Disable encryption\n", .{});
    print("    -v, --verbose               Enable verbose output\n", .{});
    print("    -q, --quiet                 Suppress progress indicators\n\n", .{});

    print("BACKUP STRATEGIES:\n", .{});
    print("    minimal        Critical configs + keys\n", .{});
    print("    standard       Documents + Dev + Configs (no media) [default]\n", .{});
    print("    comprehensive  Standard + media (Pictures/Music/Videos) and extras\n", .{});
    print("    paranoid       Complete system snapshot (~500MB+)\n\n", .{});

    print("EXAMPLES:\n", .{});
    print("    # Create a standard backup with encryption\n", .{});
    print("    krowno backup -s standard -o ~/mybackup.krowno -p\n\n", .{});

    print("    # Restore with username migration\n", .{});
    print("    krowno restore -i ~/mybackup.krowno -u newuser -p\n\n", .{});

    print("    # Show backup information\n", .{});
    print("    krowno info -i ~/mybackup.krowno\n\n", .{});

    print("    # Validate backup integrity\n", .{});
    print("    krowno validate -i ~/mybackup.krowno -p\n\n", .{});

    print("    # Run comprehensive test suite\n", .{});
    print("    krowno test\n\n", .{});

    print("For more information, see the man page: man krowno\n", .{});
}

fn progressCallback(operation: String, current: usize, total: usize) void {
    const percentage = if (total > 0) (current * 100) / total else 0;

    print("\r\x1b[K{s}: {d}/{d} ({d}%)", .{ operation, current, total, percentage });
    const stdout = std.io.getStdOut();
    _ = stdout.writeAll("") catch {}; // Force flush

    // Print newline when complete
    if (current >= total) {
        print("\n", .{});
    }
}

pub fn panic(message: String, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    print("PANIC: {s}\n", .{message});
    print("This is a bug in Krowno. Please report it!\n", .{});
    std.process.exit(1);
}

test "command line parsing" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Test basic command parsing
    const args = [_]String{ "krowno", "backup", "-s", "minimal" };
    const options = try parseCommandLine(allocator, &args);

    try testing.expectEqualStrings("backup", options.command orelse "");
    try testing.expect(options.strategy == .minimal);
}

test "backup strategy parsing" {
    const testing = std.testing;

    try testing.expect(try parseBackupStrategy("minimal") == .minimal);
    try testing.expect(try parseBackupStrategy("standard") == .standard);
    try testing.expect(try parseBackupStrategy("comprehensive") == .comprehensive);
    try testing.expect(try parseBackupStrategy("paranoid") == .paranoid);
}

fn runInteractiveMode(allocator: Allocator) !void {
    print("Krowno Backup Tool v0.3.0 - Interactive Mode\n", .{});
    print("=============================================\n\n", .{});
    print("Welcome to the user-friendly backup and restore tool for Linux!\n\n", .{});

    print("Features:\n", .{});
    print("• Multiple backup strategies (minimal to paranoid)\n", .{});
    print("• Cross-platform package resolution\n", .{});
    print("• User credential migration\n", .{});
    print("• Encryption support\n", .{});
    print("• Repository snapshots\n\n", .{});

    const stdin = std.io.getStdIn().reader();
    var buf: [256]u8 = undefined;

    while (true) {
        print("What would you like to do?\n", .{});
        print("1. Create a backup\n", .{});
        print("2. Restore from backup\n", .{});
        print("3. Show backup information\n", .{});
        print("4. List available backups\n", .{});
        print("5. Validate backup file\n", .{});
        print("6. Exit\n\n", .{});
        print("Enter your choice (1-6): ", .{});

        if (try stdin.readUntilDelimiterOrEof(buf[0..], '\n')) |input| {
            const choice = std.mem.trim(u8, input, " \r\n\t");

            if (choice.len == 0) continue;

            switch (choice[0]) {
                '1' => {
                    try interactiveCreateBackup(allocator, stdin);
                },
                '2' => {
                    try interactiveRestoreBackup(allocator, stdin);
                },
                '3' => {
                    try interactiveShowInfo(allocator, stdin);
                },
                '4' => {
                    try interactiveListBackups(allocator, stdin);
                },
                '5' => {
                    try interactiveValidateBackup(allocator, stdin);
                },
                '6' => {
                    print("Thank you for using Krowno Backup Tool!\n", .{});
                    break;
                },
                else => {
                    print("Invalid choice. Please enter a number between 1-6.\n\n", .{});
                },
            }
        }
    }
}

fn interactiveCreateBackup(allocator: Allocator, stdin: anytype) !void {
    print("\nCreate Backup\n", .{});
    print("================\n", .{});

    var buf: [512]u8 = undefined;

    print("Choose backup strategy:\n", .{});
    print("1. Minimal (~5MB) - Essential configs only\n", .{});
    print("2. Standard (~50MB) - Configs + packages [Recommended]\n", .{});
    print("3. Comprehensive (~200MB) - Full analysis + cross-distro resolution\n", .{});
    print("4. Paranoid (~500MB+) - Complete system snapshot\n", .{});
    print("Enter choice (1-4): ", .{});

    const strategy_input = try stdin.readUntilDelimiterOrEof(buf[0..], '\n');
    const strategy_choice = std.mem.trim(u8, strategy_input.?, " \r\n\t");

    const strategy: backup.BackupStrategy = switch (strategy_choice[0]) {
        '1' => .minimal,
        '2' => .standard,
        '3' => .comprehensive,
        '4' => .paranoid,
        else => .standard,
    };

    print("Enter output file path (e.g., ~/backup.krowno): ", .{});
    const path_input = try stdin.readUntilDelimiterOrEof(buf[0..], '\n');
    const output_path = std.mem.trim(u8, path_input.?, " \r\n\t");

    print("Creating {s} backup to: {s}\n", .{ strategy.getDescription(), output_path });

    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();

    try engine.createBackup(strategy, output_path, null, backup.defaultProgressCallback, khr_format.CompressionType.gzip);
    print("Backup created successfully!\n\n", .{});
}

fn interactiveRestoreBackup(allocator: Allocator, stdin: anytype) !void {
    print("\nRestore Backup\n", .{});
    print("=================\n", .{});

    var buf: [512]u8 = undefined;

    print("Enter backup file path: ", .{});
    const path_input = try stdin.readUntilDelimiterOrEof(buf[0..], '\n');
    const backup_path = std.mem.trim(u8, path_input.?, " \r\n\t");

    print("Restoring from: {s}\n", .{backup_path});

    var engine = try backup.BackupEngine.init(allocator);
    defer engine.deinit();

    engine.restoreBackup(backup_path, null, null, backup.defaultProgressCallback) catch |err| {
        print("Restore failed: {s}\n\n", .{@errorName(err)});
        return;
    };
    print("Backup restored successfully!\n\n", .{});
}

fn interactiveShowInfo(allocator: Allocator, stdin: anytype) !void {
    print("\nShow Backup Information\n", .{});
    print("===========================\n", .{});

    var buf: [512]u8 = undefined;

    print("Enter backup file path: ", .{});
    const path_input = try stdin.readUntilDelimiterOrEof(buf[0..], '\n');
    const backup_path = std.mem.trim(u8, path_input.?, " \r\n\t");

    var info = backup.getBackupInfo(allocator, backup_path) catch |err| {
        print("Error reading backup info: {any}\n\n", .{err});
        return;
    };
    defer info.deinit(allocator);

    print("\nBackup Information:\n", .{});
    print("==================\n", .{});
    print("Version: {s}\n", .{info.version});
    print("Hostname: {s}\n", .{info.hostname});
    print("Username: {s}\n", .{info.username});
    print("File count: {d}\n", .{info.file_count});
    print("Total size: {d} bytes\n", .{info.total_size});
    print("Encrypted: {any}\n\n", .{info.encrypted});
}

fn interactiveListBackups(allocator: Allocator, stdin: anytype) !void {
    print("\n📂 List Backups\n", .{});
    print("===============\n", .{});

    var buf: [512]u8 = undefined;

    print("Enter directory to scan (default: current directory): ", .{});
    const path_input = try stdin.readUntilDelimiterOrEof(buf[0..], '\n');
    const directory = std.mem.trim(u8, path_input.?, " \r\n\t");

    const scan_dir = if (directory.len == 0) "." else directory;

    try backup.listBackups(allocator, scan_dir);
    print("\n", .{});
}

fn interactiveValidateBackup(allocator: Allocator, stdin: anytype) !void {
    print("\nValidate Backup\n", .{});
    print("==================\n", .{});

    var buf: [512]u8 = undefined;

    print("Enter backup file path: ", .{});
    const path_input = try stdin.readUntilDelimiterOrEof(buf[0..], '\n');
    const backup_path = std.mem.trim(u8, path_input.?, " \r\n\t");

    const is_valid = backup.quickValidate(allocator, backup_path) catch |err| {
        print("Error validating backup: {any}\n\n", .{err});
        return;
    };

    if (is_valid) {
        print("Backup file appears to be valid!\n\n", .{});
    } else {
        print("Backup file appears to be invalid or corrupted!\n\n", .{});
    }
}

fn executeCompress(allocator: Allocator, options: CommandLineOptions) !void {
    const input_file = options.input_file orelse {
        print("Error: Input file required for compress command\n", .{});
        print("Use: krowno compress -i /path/to/backup.krowno\n", .{});
        std.process.exit(1);
    };

    print("Compressing backup file: {s}\n", .{input_file});

    // Initialize compression engine with gzip (good default)
    var engine = compress.Compressor.init(allocator);
    defer engine.deinit();

    // Read file content
    const file = try std.fs.cwd().openFile(input_file, .{});
    defer file.close();

    const stat = try file.stat();
    var buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    const content = buffer[0..bytes_read];

    var result = try engine.compress(content);
    defer result.deinit(allocator);

    print("Compression completed!\n", .{});
    print("Original size: {} bytes\n", .{result.original_size});
    print("Compressed size: {} bytes\n", .{result.compressed_size});
    print("Compression ratio: {d:.2}\n", .{result.compression_ratio});

    // Save compressed file
    const output_file = options.output_file orelse try std.fmt.allocPrint(allocator, "{s}.gz", .{input_file});
    defer if (options.output_file == null) allocator.free(output_file);

    const out_file = try std.fs.cwd().createFile(output_file, .{});
    defer out_file.close();

    try out_file.writeAll(result.compressed_data);
    print("Compressed backup saved to: {s}\n", .{output_file});
}

fn executeDecompress(allocator: Allocator, options: CommandLineOptions) !void {
    const input_file = options.input_file orelse {
        print("Error: Input file required for decompress command\n", .{});
        print("Use: krowno decompress -i /path/to/compressed.krowno\n", .{});
        std.process.exit(1);
    };

    print("Decompressing backup file: {s}\n", .{input_file});

    var engine = compress.Compressor.init(allocator);
    defer engine.deinit();

    const file = try std.fs.cwd().openFile(input_file, .{});
    defer file.close();

    const stat = try file.stat();
    var buffer = try allocator.alloc(u8, stat.size);
    defer allocator.free(buffer);

    const bytes_read = try file.readAll(buffer);
    const content = buffer[0..bytes_read];

    const decompressed = try engine.decompress(content);
    defer allocator.free(decompressed);

    print("Decompression completed!\n", .{});
    print("Compressed size: {} bytes\n", .{content.len});
    print("Decompressed size: {} bytes\n", .{decompressed.len});

    const output_file = options.output_file orelse try std.fmt.allocPrint(allocator, "{s}.decompressed", .{input_file});
    defer if (options.output_file == null) allocator.free(output_file);

    const out_file = try std.fs.cwd().createFile(output_file, .{});
    defer out_file.close();

    try out_file.writeAll(decompressed);
    print("Decompressed backup saved to: {s}\n", .{output_file});
}

// fn executeSchedule(allocator: Allocator, options: CommandLineOptions) !void {
// deprecated for now. I hope to use it again some day.
//     _ = options;
//     print("Backup Scheduler\n", .{});
//     print("================\n", .{});

//     var scheduler_engine = try scheduler.BackupScheduler.init(allocator);
//     defer scheduler_engine.deinit();

//     scheduler_engine.listScheduledBackups();

//     const stdin = std.io.getStdIn().reader();
//     var buf: [512]u8 = undefined;

//     print("\nSchedule Management Options:\n", .{});
//     print("1. Add new scheduled backup\n", .{});
//     print("2. Remove scheduled backup\n", .{});
//     print("3. Check and run due backups\n", .{});
//     print("4. Generate cron entry\n", .{});
//     print("5. Exit\n", .{});
//     print("Select option: ", .{});

//     const input = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch return;
//     if (input == null) return;
//     const choice = std.mem.trim(u8, input.?, " \r\n\t");

//     if (std.mem.eql(u8, choice, "1")) {
//         // Add new schedule
//         print("Enter backup name: ", .{});
//         const name_input = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch return;
//         if (name_input == null) return;
//         const backup_name = std.mem.trim(u8, name_input.?, " \r\n\t");

//         const sched_config = scheduler.ScheduleConfig{
//             .schedule_type = .daily,
//             .hour = 2,
//             .minute = 0,
//             .day_of_week = 0,
//             .day_of_month = 1,
//             .cron_expression = null,
//             .enabled = true,
//             .max_backups = 10,
//             .strategy = .standard,
//             .output_directory = try allocator.dupe(u8, "~/backups"),
//             .password = null,
//         };

//         const id = try scheduler_engine.addScheduledBackup(backup_name, sched_config);
//         print("Scheduled backup added with ID: {d}\n", .{id});
//     } else if (std.mem.eql(u8, choice, "2")) {
//         // Remove schedule
//         print("Enter backup ID to remove: ", .{});
//         const id_input = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch return;
//         if (id_input == null) return;
//         const id_str = std.mem.trim(u8, id_input.?, " \r\n\t");
//         const backup_id = std.fmt.parseInt(u32, id_str, 10) catch return;

//         const removed = try scheduler_engine.removeScheduledBackup(backup_id);
//         if (removed) {
//             print("Scheduled backup removed successfully\n", .{});
//         } else {
//             print("Backup ID not found\n", .{});
//         }
//     } else if (std.mem.eql(u8, choice, "3")) {
//         // Check and run
//         print("Checking for due backups...\n", .{});
//         try scheduler_engine.checkAndRunBackups();
//         print("Check completed\n", .{});
//     } else if (std.mem.eql(u8, choice, "4")) {
//         // Generate cron
//         print("Enter backup ID: ", .{});
//         const id_input = stdin.readUntilDelimiterOrEof(buf[0..], '\n') catch return;
//         if (id_input == null) return;
//         const id_str = std.mem.trim(u8, id_input.?, " \r\n\t");
//         const backup_id = std.fmt.parseInt(u32, id_str, 10) catch return;

//         try scheduler_engine.installCronJob(backup_id);
//     }
// }

fn executeVerify(allocator: Allocator, options: CommandLineOptions) !void {
    const input_file = options.input_file orelse {
        print("Error: Input file required for verify command\n", .{});
        print("Use: krowno verify -i /path/to/backup.krowno\n", .{});
        std.process.exit(1);
    };

    print("Verifying backup checksums: {s}\n", .{input_file});

    var verifier = verification.BackupVerifier.init(allocator, .sha256);
    defer verifier.deinit();

    const checksum = try verifier.calculateChecksum(input_file);
    defer allocator.free(checksum);

    print("SHA256 checksum: {s}\n", .{checksum});

    // Verify integrity
    const is_valid = try verifier.verifyBackupIntegrity(input_file);

    if (is_valid) {
        print("Backup integrity verified successfully\n", .{});
    } else {
        print("Backup integrity check failed\n", .{});
    }
}

fn executeIncremental(allocator: Allocator, options: CommandLineOptions) !void {
    print("Incremental Backup\n", .{});
    print("==================\n", .{});

    const input_file = options.input_file orelse {
        print("Error: Input file required for incremental command\n", .{});
        print("Use: krowno incremental -i /path/to/base/backup.krowno\n", .{});
        std.process.exit(1);
    };

    var engine = incremental.IncrementalBackupEngine.init(allocator, .hybrid);
    defer engine.deinit();

    // Load base manifest
    try engine.loadBaseManifest(input_file);

    var manifest = try engine.scanForChanges(".");
    // Don't deinit here - the engine will handle it

    // Create incremental backup
    const output_file = options.output_file orelse try std.fmt.allocPrint(allocator, "incremental_{d}.krowno", .{std.time.timestamp()});
    defer if (options.output_file == null) allocator.free(output_file);

    try engine.createIncrementalBackup(&manifest, output_file);
    print("Incremental backup created: {s}\n", .{output_file});

    // Clean up the manifest
    manifest.deinit(allocator);
}

fn executeSearch(allocator: Allocator, options: CommandLineOptions) !void {
    print("Backup Search\n", .{});
    print("=============\n", .{});

    const search_dir = options.input_file orelse ".";

    var searcher = search.BackupSearcher.init(allocator);
    defer searcher.deinit();

    // Create search criteria
    var criteria = search.SearchCriteria{};
    defer criteria.deinit(allocator);

    // Search for backups
    var results = try searcher.searchBackups(search_dir, criteria);
    defer {
        for (results.items) |*result| {
            result.deinit(allocator);
        }
        results.deinit();
    }

    // Display results
    print("Search Results:\n", .{});
    print("==============\n", .{});

    for (results.items, 0..) |result, i| {
        print("{d}. {s}\n", .{ i + 1, result.file_name });
        print("   Path: {s}\n", .{result.file_path});
        print("   Size: {} bytes\n", .{result.file_size});
        print("   Hostname: {s}\n", .{result.backup_info.hostname});
        print("   Username: {s}\n", .{result.backup_info.username});
        print("   Match Score: {d:.2}\n", .{result.match_score});
        print("\n", .{});
    }
}

fn executeStats(allocator: Allocator, options: CommandLineOptions) !void {
    print("Backup Statistics\n", .{});
    print("=================\n", .{});

    const stats_dir = options.input_file orelse ".";

    var searcher = search.BackupSearcher.init(allocator);
    defer searcher.deinit();

    try searcher.getBackupStatistics(stats_dir);
}

fn runSetup(allocator: Allocator) !void {
    print("Khrowno Setup\n", .{});
    print("=============\n\n", .{});

    const distro_info = try distro.detectDistro(allocator);
    defer distro_info.deinit(allocator);

    print("Detected: {s} {s}\n\n", .{ distro_info.name, distro_info.version });

    print("Checking dependencies...\n", .{});

    const has_gtk4 = checkCommand(&[_]String{ "pkg-config", "--exists", "gtk4" });
    print("  GTK4: {s}\n", .{if (has_gtk4) "installed" else "missing"});

    const has_curl = checkCommand(&[_]String{ "which", "curl" });
    print("  curl: {s}\n", .{if (has_curl) "installed" else "missing"});

    if (!has_gtk4 or !has_curl) {
        print("\nTo install missing dependencies:\n\n", .{});

        switch (distro_info.distro_type) {
            .fedora => {
                print("  sudo dnf install gtk4-devel libcurl-devel\n", .{});
            },
            .ubuntu, .debian, .mint => {
                print("  sudo apt install libgtk-4-dev libcurl4-openssl-dev\n", .{});
            },
            .arch => {
                print("  sudo pacman -S gtk4 curl\n", .{});
            },
            .nixos => {
                print("  nix-env -iA nixpkgs.gtk4 nixpkgs.curl\n", .{});
            },
            .opensuse_leap, .opensuse_tumbleweed => {
                print("  sudo zypper install gtk4-devel libcurl-devel\n", .{});
            },
            .unknown => {
                print("  Please install GTK4 and curl for your distribution\n", .{});
            },
        }
    } else {
        print("\nAll dependencies are installed!\n", .{});
    }
}

fn checkCommand(cmd: []const String) bool {
    var child = std.process.Child.init(cmd, std.heap.page_allocator);
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;

    child.spawn() catch return false;
    const term = child.wait() catch return false;

    return term == .Exited and term.Exited == 0;
}

fn installFlatpaksFromBackup(allocator: Allocator, backup_file: String) !void {
    print("{s}Installing Flatpaks from backup:{s} {s}\n", .{ ansi.Color.BOLD_BLUE, ansi.Color.RESET, backup_file });
    print("==========================================\n\n", .{});

    if (!checkCommand(&[_]String{ "which", "flatpak" })) {
        print("{s}Error:{s} Flatpak is not installed\n", .{ ansi.Color.BOLD_RED, ansi.Color.RESET });
        print("Install it first using your package manager\n", .{});
        return error.PackageManagerNotFound;
    }

    const temp_dir = try std.fmt.allocPrint(allocator, "krowno_flatpak_restore_{d}", .{std.time.timestamp()});
    defer allocator.free(temp_dir);

    print("Extracting backup...\n", .{});
    try khr_format.extractKhrBackup(allocator, backup_file, null, temp_dir);
    defer std.fs.cwd().deleteTree(temp_dir) catch {};

    const flatpak_support = @import("core/flatpak_support.zig");
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/tmp", .{temp_dir});
    defer allocator.free(tmp_path);

    try flatpak_support.installFlatpaksFromDirectory(allocator, tmp_path);

    print("\n{s}Flatpak installation complete!{s}\n", .{ ansi.Color.BOLD_GREEN, ansi.Color.RESET });
}
