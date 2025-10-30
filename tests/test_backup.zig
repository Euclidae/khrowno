const std = @import("std");
const testing = std.testing;
const backup = @import("backup.zig");
const security = @import("security.zig");
const network = @import("network.zig");

// Comprehensive test suite for the backup system
// Because untested code is broken code, and we're not shipping broken code
pub fn runTests() !void {
    std.debug.print("Running Krowno Backup Test Suite...\n", .{});

    try testBackupStrategies();
    try testSecurityContext();
    try testHttpClient();
    try testFileOperations();
    try testEncryptionDecryption();
    try testNetworkOperations();

    std.debug.print("All tests passed!\n", .{});
}

fn testBackupStrategies() !void {
    std.debug.print("Testing backup strategies...\n", .{});

    // Test strategy descriptions
    try testing.expectEqualStrings("Minimal backup (essential configs only, ~5MB)", backup.BackupStrategy.minimal.getDescription());
    try testing.expectEqualStrings("Standard backup (configs + user data, ~50MB)", backup.BackupStrategy.standard.getDescription());
    try testing.expectEqualStrings("Comprehensive backup (all user data + configs + browser data + passwords, ~200MB)", backup.BackupStrategy.comprehensive.getDescription());
    try testing.expectEqualStrings("Paranoid backup (complete system snapshot including all files, ~500MB+)", backup.BackupStrategy.paranoid.getDescription());

    // Test path inclusion
    const minimal_paths = backup.BackupStrategy.minimal.getPaths();
    try testing.expect(minimal_paths.len == 4); // .config, .ssh, .bashrc, .zshrc

    const standard_paths = backup.BackupStrategy.standard.getPaths();
    try testing.expect(standard_paths.len > minimal_paths.len);

    const comprehensive_paths = backup.BackupStrategy.comprehensive.getPaths();
    try testing.expect(comprehensive_paths.len > standard_paths.len);

    // Test dependency analysis flags
    try testing.expect(!backup.BackupStrategy.minimal.includesDependencyAnalysis());
    try testing.expect(!backup.BackupStrategy.standard.includesDependencyAnalysis());
    try testing.expect(backup.BackupStrategy.comprehensive.includesDependencyAnalysis());
    try testing.expect(backup.BackupStrategy.paranoid.includesDependencyAnalysis());

    std.debug.print("Backup strategies test passed\n", .{});
}

fn testSecurityContext() !void {
    std.debug.print("Testing security context...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test initialization
    var sec_ctx = try security.SecurityContext.init(allocator, security.SecurityParams.default());
    defer sec_ctx.deinit();

    // Test password setting
    try sec_ctx.setPassword("test_password_123");
    try testing.expect(sec_ctx.master_key != null);

    // Test random byte generation
    var random_bytes: [32]u8 = undefined;
    try sec_ctx.generateRandomBytes(&random_bytes);

    // Verify we got some random data (not all zeros)
    var all_zero = true;
    for (random_bytes) |byte| {
        if (byte != 0) {
            all_zero = false;
            break;
        }
    }
    try testing.expect(!all_zero);

    std.debug.print("Security context test passed\n", .{});
}

fn testHttpClient() !void {
    std.debug.print("Testing HTTP client...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test initialization
    var client = try network.HttpClient.init(allocator);
    defer client.deinit();

    // Test basic request (using a reliable test endpoint)
    var response = client.get("https://httpbin.org/get") catch |err| {
        std.debug.print("HTTP test skipped (network unavailable): {any}\n", .{err});
        return;
    };
    defer response.deinit();

    try testing.expect(response.status_code >= 200);
    try testing.expect(response.status_code < 400);
    try testing.expect(response.body.len > 0);

    // Test header parsing
    const content_type = response.getHeader("content-type");
    try testing.expect(content_type != null);

    std.debug.print("HTTP client test passed\n", .{});
}

fn testFileOperations() !void {
    std.debug.print("Testing file operations...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test directory structure
    const test_dir = "test_backup_data";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test files
    const test_file = try std.fmt.allocPrint(allocator, "{s}/test.txt", .{test_dir});
    defer allocator.free(test_file);

    try std.fs.cwd().writeFile(.{ .sub_path = test_file, .data = "Hello, Krowno!" });

    // Test backup engine initialization
    var backup_engine = try backup.BackupEngine.init(allocator);
    defer backup_engine.deinit();

    // Test file scanning
    var entries = std.ArrayList(backup.BackupEntry).init(allocator);
    defer {
        for (entries.items) |*entry| {
            allocator.free(entry.path);
            if (entry.data) |data| {
                allocator.free(data);
            }
        }
        entries.deinit();
    }

    var file_count: u32 = 0;
    var total_size: u64 = 0;

    try backup_engine.scanPath(test_file, &entries, &file_count, &total_size);

    try testing.expect(file_count == 1);
    try testing.expect(total_size > 0);
    try testing.expect(entries.items.len == 1);
    try testing.expect(std.mem.eql(u8, entries.items[0].data.?, "Hello, Krowno!"));

    std.debug.print("File operations test passed\n", .{});
}

fn testEncryptionDecryption() !void {
    std.debug.print("Testing encryption/decryption...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize security context
    var sec_ctx = try security.SecurityContext.init(allocator, security.SecurityParams.default());
    defer sec_ctx.deinit();

    try sec_ctx.setPassword("test_encryption_password");

    // Test data
    const test_data = "This is sensitive backup data that needs encryption!";

    // Encrypt
    var encrypted_result = try sec_ctx.encryptData(test_data);
    defer encrypted_result.deinit(allocator);

    try testing.expect(encrypted_result.ciphertext.len > 0);
    try testing.expect(encrypted_result.nonce.len > 0);

    // Decrypt
    const decrypted_data = try sec_ctx.decryptData(&encrypted_result);
    defer allocator.free(decrypted_data);

    try testing.expectEqualStrings(test_data, decrypted_data);

    std.debug.print("Encryption/decryption test passed\n", .{});
}

fn testNetworkOperations() !void {
    std.debug.print("Testing network operations...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Test rate limiter
    var rate_limiter = network.RateLimiter.init(100); // 100ms
    const start_time = std.time.milliTimestamp();
    rate_limiter.waitIfNeeded();
    const end_time = std.time.milliTimestamp();

    // Should not have waited on first call
    try testing.expect(end_time - start_time < 50);

    // Test repository checker initialization
    var repo_checker = network.RepositoryChecker.init(allocator) catch |err| {
        std.debug.print("Repository checker test skipped (network unavailable): {any}\n", .{err});
        return;
    };
    defer repo_checker.deinit();

    // Test online check
    const is_online = network.isOnline();
    std.debug.print("Network online status: {any}\n", .{is_online});

    std.debug.print("Network operations test passed\n", .{});
}

// Integration test for full backup workflow
fn testFullBackupWorkflow() !void {
    std.debug.print("Testing full backup workflow...\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test environment
    const test_dir = "test_backup_workflow";
    std.fs.cwd().makeDir(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    // Create test files
    const test_files = [_][]const u8{
        "test_backup_workflow/config.txt",
        "test_backup_workflow/data.txt",
        "test_backup_workflow/subdir/nested.txt",
    };

    for (test_files) |file| {
        if (std.mem.indexOf(u8, file, "/")) |last_slash| {
            const dir_path = file[0..last_slash];
            std.fs.cwd().makePath(dir_path) catch {};
        }
        try std.fs.cwd().writeFile(.{ .sub_path = file, .data = "Test content for " ++ file });
    }

    // Initialize backup engine with encryption
    var backup_engine = try backup.BackupEngine.init(allocator);
    defer backup_engine.deinit();

    var sec_ctx = try security.SecurityContext.init(allocator, security.SecurityParams.default());
    defer sec_ctx.deinit();
    try sec_ctx.setPassword("workflow_test_password");
    backup_engine.security_context = &sec_ctx;

    // Create backup
    const output_file = "test_backup_workflow.krowno";
    try backup_engine.createBackup(backup.BackupStrategy.minimal, output_file, "workflow_test_password", null);

    // Verify backup file exists
    const backup_stat = try std.fs.cwd().statFile(output_file);
    try testing.expect(backup_stat.size > 0);

    // Clean up
    std.fs.cwd().deleteFile(output_file) catch {};

    std.debug.print("Full backup workflow test passed\n", .{});
}
