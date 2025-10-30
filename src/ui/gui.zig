//! Khrowno Backup Tool - GTK4 GUI Implementation
//! GTK4 works on all distros but theme issues on KDE are annoying

//!TODO: fix theme issues on KDE - something weird with Adwaita

const std = @import("std");
const backup = @import("../core/backup.zig");
const khr_format = @import("../core/khr_format.zig");
const types = @import("../utils/types.zig");
const errors = @import("../utils/errors.zig");
const config = @import("../core/config.zig");
const String = types.String; //still love this type alias

const c = @cImport({
    @cInclude("gtk/gtk.h");
    @cInclude("glib.h");
});

//global vars are bad but GTK callbacks need them
//tried to avoid this but couldnt figure out a better way
var g_allocator: std.mem.Allocator = undefined;
var g_main_window: ?*c.GtkWindow = null;
var g_progress_bar: ?*c.GtkProgressBar = null;
var g_status_label: ?*c.GtkLabel = null;
var g_output_path_entry: ?*c.GtkEntry = null;
var g_password_entry: ?*c.GtkEntry = null;
var g_confirm_password_entry: ?*c.GtkEntry = null;
var g_encrypt_check: ?*c.GtkCheckButton = null;
var g_theme_combo: ?*c.GtkComboBoxText = null;
var g_password_strength_label: ?*c.GtkLabel = null;
var g_password_strength_bar: ?*c.GtkProgressBar = null;

// Strategy radio buttons
var g_minimal_radio: ?*c.GtkCheckButton = null;
var g_standard_radio: ?*c.GtkCheckButton = null;
var g_comprehensive_radio: ?*c.GtkCheckButton = null;
var g_paranoid_radio: ?*c.GtkCheckButton = null;

// Current selected output path (owned by allocator)
var g_selected_output_path: ?[]u8 = null;

// CSS Provider for theming
var g_css_provider: ?*c.GtkCssProvider = null;

// Progress tracking state
const ProgressState = struct {
    current: usize,
    total: usize,
    operation: String,
    mutex: std.Thread.Mutex,
    is_active: bool,

    fn init() ProgressState {
        return .{
            .current = 0,
            .total = 100,
            .operation = "Ready",
            .mutex = .{},
            .is_active = false,
        };
    }

    fn update(self: *ProgressState, op: String, current: usize, total: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.operation = op;
        self.current = current;
        self.total = total;
    }

    fn setActive(self: *ProgressState, active: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.is_active = active;
    }

    fn isActive(self: *ProgressState) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.is_active;
    }
};

var g_progress_state: ProgressState = undefined;
var g_timeout_source_id: c.guint = 0;

fn loadTheme(theme_name: String) !void {
    const exe_path = try std.fs.selfExePathAlloc(g_allocator);
    defer g_allocator.free(exe_path);

    const exe_dir = std.fs.path.dirname(exe_path) orelse ".";

    // Try multiple possible locations for themes
    const possible_paths = [_][]const u8{
        try std.fmt.allocPrint(g_allocator, "{s}/../styles/{s}.css", .{ exe_dir, theme_name }),
        try std.fmt.allocPrint(g_allocator, "{s}/../../styles/{s}.css", .{ exe_dir, theme_name }),
        try std.fmt.allocPrint(g_allocator, "styles/{s}.css", .{theme_name}),
        try std.fmt.allocPrint(g_allocator, "/usr/share/khrowno/styles/{s}.css", .{theme_name}),
    };

    defer for (possible_paths) |path| g_allocator.free(path);

    if (g_css_provider == null) {
        g_css_provider = c.gtk_css_provider_new();
    }

    // Try each path until one works
    for (possible_paths) |theme_path| {
        std.fs.cwd().access(theme_path, .{}) catch continue;

        const path_z = try g_allocator.dupeZ(u8, theme_path);
        defer g_allocator.free(path_z);

        c.gtk_css_provider_load_from_path(g_css_provider, path_z.ptr);
        break;
    } else {
        // No theme file found, continue without custom styling
        return;
    }

    // Apply to display
    // See: https://docs.gtk.org/gtk4/method.StyleContext.add_provider_for_display.html
    const display = c.gdk_display_get_default();
    c.gtk_style_context_add_provider_for_display(display, @ptrCast(g_css_provider), c.GTK_STYLE_PROVIDER_PRIORITY_USER);
}

export fn on_theme_changed(combo: *c.GtkComboBoxText, user_data: ?*anyopaque) void {
    _ = user_data;

    const active_text = c.gtk_combo_box_text_get_active_text(combo);
    if (active_text) |text| {
        defer c.g_free(text);
        const theme_name = std.mem.span(text);

        var lower_buf: [64]u8 = undefined;
        const lower = std.ascii.lowerString(&lower_buf, theme_name);

        loadTheme(lower) catch |err| {
            errors.logError(err, null);
        };
    }
}

fn calculatePasswordStrength(password: String) struct { score: f64, label: String, css_class: String } {
    if (password.len == 0) {
        return .{ .score = 0.0, .label = "Password strength: None", .css_class = "error" };
    }

    var score: f64 = 0.0;
    var has_lower = false;
    var has_upper = false;
    var has_digit = false;
    var has_special = false;

    for (password) |ch| {
        if (ch >= 'a' and ch <= 'z') has_lower = true;
        if (ch >= 'A' and ch <= 'Z') has_upper = true;
        if (ch >= '0' and ch <= '9') has_digit = true;
        if (!std.ascii.isAlphanumeric(ch)) has_special = true;
    }

    // Length score (up to 0.4)
    if (password.len >= 8) score += 0.1;
    if (password.len >= 12) score += 0.1;
    if (password.len >= 16) score += 0.1;
    if (password.len >= 20) score += 0.1;

    // Complexity score (up to 0.6)
    if (has_lower) score += 0.15;
    if (has_upper) score += 0.15;
    if (has_digit) score += 0.15;
    if (has_special) score += 0.15;

    // Determine label and CSS class
    if (score < 0.3) {
        return .{ .score = score, .label = "Password strength: Weak", .css_class = "error" };
    } else if (score < 0.6) {
        return .{ .score = score, .label = "Password strength: Fair", .css_class = "warning" };
    } else if (score < 0.8) {
        return .{ .score = score, .label = "Password strength: Good", .css_class = "success" };
    } else {
        return .{ .score = score, .label = "Password strength: Strong", .css_class = "success" };
    }
}

export fn on_password_changed(entry: *c.GtkEntry, user_data: ?*anyopaque) void {
    _ = user_data;

    if (g_password_strength_label == null or g_password_strength_bar == null) return;

    const text_ptr = c.gtk_editable_get_text(@ptrCast(entry));
    if (text_ptr == null) return;

    const password = std.mem.span(text_ptr);
    const strength = calculatePasswordStrength(password);

    c.gtk_label_set_text(g_password_strength_label, strength.label.ptr);
    c.gtk_progress_bar_set_fraction(g_password_strength_bar, strength.score);
    c.gtk_widget_remove_css_class(@ptrCast(@alignCast(g_password_strength_bar)), "error");
    c.gtk_widget_remove_css_class(@ptrCast(@alignCast(g_password_strength_bar)), "warning");
    c.gtk_widget_remove_css_class(@ptrCast(@alignCast(g_password_strength_bar)), "success");
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(g_password_strength_bar)), strength.css_class.ptr);
}

export fn on_file_dialog_response(dialog: *c.GtkDialog, response_id: c_int, user_data: ?*anyopaque) void {
    _ = user_data;

    if (response_id == c.GTK_RESPONSE_ACCEPT) {
        const chooser: *c.GtkFileChooser = @ptrCast(dialog);
        const file = c.gtk_file_chooser_get_file(chooser);

        if (file) |f| {
            defer c.g_object_unref(f);

            const path = c.g_file_get_path(f);
            if (path) |p| {
                defer c.g_free(path);
                const path_str = std.mem.span(p);

                // Free old path if exists
                if (g_selected_output_path) |old| {
                    g_allocator.free(old);
                }

                g_selected_output_path = g_allocator.dupe(u8, path_str) catch null;
                if (g_output_path_entry) |entry| {
                    c.gtk_editable_set_text(@ptrCast(entry), p);
                }
            }
        }
    }

    c.gtk_window_destroy(@ptrCast(dialog));
}

export fn on_choose_file_clicked(button: *c.GtkButton, user_data: ?*anyopaque) void {
    _ = button;
    _ = user_data;

    const dialog = c.gtk_file_chooser_dialog_new(
        "Choose Backup Location",
        g_main_window,
        c.GTK_FILE_CHOOSER_ACTION_SAVE,
        "_Cancel",
        c.GTK_RESPONSE_CANCEL,
        "_Save",
        c.GTK_RESPONSE_ACCEPT,
        @as(?*anyopaque, @ptrFromInt(0)),
    );

    c.gtk_file_chooser_set_current_name(@ptrCast(dialog), "backup.khr");
    const filter = c.gtk_file_filter_new();
    c.gtk_file_filter_set_name(filter, "Khrowno Backups (*.khr)");
    c.gtk_file_filter_add_pattern(filter, "*.khr");
    c.gtk_file_chooser_add_filter(@ptrCast(dialog), filter);
    c.g_object_unref(filter);

    c.gtk_widget_show(@ptrCast(dialog));
    _ = c.g_signal_connect_data(
        dialog,
        "response",
        @ptrCast(&on_file_dialog_response),
        null,
        null,
        0,
    );
}

fn getSelectedStrategy() backup.BackupStrategy {
    if (g_minimal_radio) |radio| {
        if (c.gtk_check_button_get_active(radio) != 0) return .minimal;
    }
    if (g_comprehensive_radio) |radio| {
        if (c.gtk_check_button_get_active(radio) != 0) return .comprehensive;
    }
    if (g_paranoid_radio) |radio| {
        if (c.gtk_check_button_get_active(radio) != 0) return .paranoid;
    }
    return .standard; // default
}

fn updateProgressUI(user_data: ?*anyopaque) callconv(.C) c.gboolean {
    _ = user_data;
    if (!g_progress_state.isActive()) {
        g_timeout_source_id = 0;
        return 0;
    }

    g_progress_state.mutex.lock();
    defer g_progress_state.mutex.unlock();

    if (g_progress_bar) |bar| {
        const fraction = if (g_progress_state.total > 0)
            @as(f64, @floatFromInt(g_progress_state.current)) / @as(f64, @floatFromInt(g_progress_state.total))
        else
            0.0;
        c.gtk_progress_bar_set_fraction(bar, fraction);
        var text_buf: [256]u8 = undefined;
        const text = std.fmt.bufPrintZ(&text_buf, "{d}%", .{@as(u32, @intFromFloat(fraction * 100))}) catch "0%";
        c.gtk_progress_bar_set_text(bar, text.ptr);
        c.gtk_progress_bar_set_show_text(bar, 1);
    }

    if (g_status_label) |label| {
        var status_buf: [512]u8 = undefined;
        const status = std.fmt.bufPrintZ(&status_buf, "{s}: {d}/{d}", .{ g_progress_state.operation, g_progress_state.current, g_progress_state.total }) catch "Processing...";
        c.gtk_label_set_text(label, status.ptr);
    }

    return 1; // Continue calling
}

fn guiProgressCallback(operation: String, current: usize, total: usize) void {
    g_progress_state.update(operation, current, total);
}

fn performBackupThread(context: *BackupContext) void {
    defer {
        context.deinit();
        g_allocator.destroy(context);
    }

    var engine = backup.BackupEngine.init(g_allocator) catch |err| {
        errors.logError(err, null);
        const err_msg = std.fmt.allocPrint(g_allocator, "Backup failed: {s}", .{@errorName(err)}) catch "Backup failed: Out of memory";
        defer if (!std.mem.eql(u8, err_msg, "Backup failed: Out of memory")) g_allocator.free(err_msg);
        g_progress_state.update(err_msg, 0, 100);
        // Keep active for 3 seconds to show error
        std.time.sleep(3 * std.time.ns_per_s);
        g_progress_state.setActive(false);
        return;
    };
    defer engine.deinit();

    engine.createBackup(context.strategy, context.output_path, context.password, &guiProgressCallback, khr_format.CompressionType.gzip) catch |err| {
        errors.logError(err, null);
        const err_msg = std.fmt.allocPrint(g_allocator, "Backup failed: {s}", .{@errorName(err)}) catch "Backup failed: Unknown error";
        defer if (!std.mem.eql(u8, err_msg, "Backup failed: Unknown error")) g_allocator.free(err_msg);
        g_progress_state.update(err_msg, 0, 100);
        // Keep active for 3 seconds to show error
        std.time.sleep(3 * std.time.ns_per_s);
        g_progress_state.setActive(false);
        return;
    };

    g_progress_state.update("Backup completed successfully!", 100, 100);
    std.time.sleep(5 * std.time.ns_per_s);
    g_progress_state.setActive(false);
}

const BackupContext = struct {
    strategy: backup.BackupStrategy,
    output_path: String,
    password: ?String,

    fn deinit(self: *BackupContext) void {
        g_allocator.free(self.output_path);
        if (self.password) |pwd| {
            // Securely zero password memory before freeing
            // See: https://github.com/ziglang/zig/blob/master/lib/std/crypto/utils.zig
            @memset(@as([*]u8, @ptrCast(@constCast(pwd.ptr)))[0..pwd.len], 0);
            g_allocator.free(pwd);
        }
    }
};

const RestoreContext = struct {
    backup_path: String,
    password: ?String,

    fn deinit(self: *RestoreContext) void {
        g_allocator.free(self.backup_path);
        if (self.password) |pwd| {
            @memset(@as([*]u8, @ptrCast(@constCast(pwd.ptr)))[0..pwd.len], 0);
            g_allocator.free(pwd);
        }
    }
};

export fn on_backup_clicked(button: *c.GtkButton, user_data: ?*anyopaque) void {
    _ = button;
    _ = user_data;

    const output_path = if (g_output_path_entry) |entry| blk: {
        const text = c.gtk_editable_get_text(@ptrCast(entry));
        break :blk if (text) |t| std.mem.span(t) else null;
    } else null;

    if (output_path == null or output_path.?.len == 0) {
        if (g_status_label) |label| {
            c.gtk_label_set_text(label, "Error: Please choose an output file");
        }
        return;
    }

    errors.validatePath(output_path.?) catch {
        if (g_status_label) |label| {
            c.gtk_label_set_text(label, "Error: Invalid file path");
        }
        return;
    };

    const password = if (g_encrypt_check) |check| blk: {
        const active = c.gtk_check_button_get_active(check);
        if (active != 0 and g_password_entry != null) {
            const text = c.gtk_editable_get_text(@ptrCast(g_password_entry.?));
            if (text) |t| {
                const pwd = std.mem.span(t);
                if (pwd.len > 0) {
                    errors.validatePassword(pwd) catch {
                        if (g_status_label) |label| {
                            c.gtk_label_set_text(label, "Error: Password too weak (min 8 chars, mixed case + numbers)");
                        }
                        return;
                    };
                    // Confirm password matches
                    if (g_confirm_password_entry == null) {
                        if (g_status_label) |label| {
                            c.gtk_label_set_text(label, "Error: Please confirm your password");
                        }
                        return;
                    }
                    const confirm_text = c.gtk_editable_get_text(@ptrCast(g_confirm_password_entry.?));
                    if (confirm_text) |ct| {
                        const confirm = std.mem.span(ct);
                        if (!std.mem.eql(u8, pwd, confirm)) {
                            if (g_status_label) |label| {
                                c.gtk_label_set_text(label, "Error: Passwords do not match");
                            }
                            return;
                        }
                    } else {
                        if (g_status_label) |label| {
                            c.gtk_label_set_text(label, "Error: Please confirm your password");
                        }
                        return;
                    }
                    break :blk pwd;
                }
            }
        }
        break :blk null;
    } else null;

    const strategy = getSelectedStrategy();
    const context = g_allocator.create(BackupContext) catch {
        if (g_status_label) |label| {
            c.gtk_label_set_text(label, "Error: Out of memory");
        }
        return;
    };

    context.* = .{
        .strategy = strategy,
        .output_path = g_allocator.dupe(u8, output_path.?) catch {
            g_allocator.destroy(context);
            if (g_status_label) |label| {
                c.gtk_label_set_text(label, "Error: Out of memory");
            }
            return;
        },
        .password = if (password) |pwd| g_allocator.dupe(u8, pwd) catch null else null,
    };

    g_progress_state.update("Starting backup...", 0, 100);
    g_progress_state.setActive(true);
    if (g_timeout_source_id != 0) {
        _ = c.g_source_remove(g_timeout_source_id);
        g_timeout_source_id = 0;
    }

    const thread = std.Thread.spawn(.{}, performBackupThread, .{context}) catch {
        context.deinit();
        g_allocator.destroy(context);
        g_progress_state.setActive(false);
        if (g_status_label) |label| {
            c.gtk_label_set_text(label, "Error: Failed to start backup thread");
        }
        return;
    };
    thread.detach();
    g_timeout_source_id = c.g_timeout_add(100, updateProgressUI, null);
}

export fn on_restore_dialog_response(dialog: *c.GtkDialog, response_id: c_int, user_data: ?*anyopaque) void {
    _ = user_data;

    if (response_id == c.GTK_RESPONSE_ACCEPT) {
        const chooser: *c.GtkFileChooser = @ptrCast(dialog);
        const file = c.gtk_file_chooser_get_file(chooser);

        if (file) |f| {
            defer c.g_object_unref(f);

            const path = c.g_file_get_path(f);
            if (path) |p| {
                defer c.g_free(path);
                const path_str = std.mem.span(p);

                const is_encrypted = backup.isBackupEncrypted(path_str) catch false;
                if (is_encrypted) {
                    showPasswordDialog(path_str);
                } else {
                    performRestore(path_str, null);
                }
            }
        }
    }

    c.gtk_window_destroy(@ptrCast(dialog));
}

export fn on_restore_clicked(button: *c.GtkButton, user_data: ?*anyopaque) void {
    _ = button;
    _ = user_data;

    const dialog = c.gtk_file_chooser_dialog_new(
        "Choose Backup to Restore",
        g_main_window,
        c.GTK_FILE_CHOOSER_ACTION_OPEN,
        "_Cancel",
        c.GTK_RESPONSE_CANCEL,
        "_Open",
        c.GTK_RESPONSE_ACCEPT,
        @as(?*anyopaque, @ptrFromInt(0)),
    );

    // Add filter for backup files
    const filter = c.gtk_file_filter_new();
    c.gtk_file_filter_set_name(filter, "Khrowno Backups");
    c.gtk_file_filter_add_pattern(filter, "*.khr");
    c.gtk_file_filter_add_pattern(filter, "*.krowno");
    c.gtk_file_chooser_add_filter(@ptrCast(dialog), filter);
    c.g_object_unref(filter);

    c.gtk_widget_show(@ptrCast(dialog));

    _ = c.g_signal_connect_data(
        dialog,
        "response",
        @ptrCast(&on_restore_dialog_response),
        null,
        null,
        0,
    );
}

fn showPasswordDialog(backup_path_cstr: [*:0]const u8) void {
    const backup_path = std.mem.span(backup_path_cstr);

    const dialog = c.gtk_dialog_new_with_buttons(
        "Enter Password",
        g_main_window,
        c.GTK_DIALOG_MODAL,
        "_Cancel",
        c.GTK_RESPONSE_CANCEL,
        "_OK",
        c.GTK_RESPONSE_OK,
        @as(?*anyopaque, @ptrFromInt(0)),
    );

    const content_area = c.gtk_dialog_get_content_area(@ptrCast(dialog));
    c.gtk_widget_set_margin_start(content_area, 20);
    c.gtk_widget_set_margin_end(content_area, 20);
    c.gtk_widget_set_margin_top(content_area, 20);
    c.gtk_widget_set_margin_bottom(content_area, 20);

    const label = c.gtk_label_new("This backup is encrypted. Please enter the password:");
    c.gtk_box_append(@ptrCast(content_area), label);

    const password_entry = c.gtk_password_entry_new();
    c.gtk_widget_set_size_request(password_entry, 300, -1);
    c.gtk_box_append(@ptrCast(content_area), password_entry);

    const path_copy = g_allocator.dupeZ(u8, backup_path) catch {
        c.gtk_window_destroy(@ptrCast(dialog));
        return;
    };
    c.g_object_set_data_full(
        @ptrCast(dialog),
        "backup_path",
        path_copy.ptr,
        @ptrCast(&freeGString),
    );
    c.g_object_set_data(@ptrCast(dialog), "password_entry", password_entry);

    _ = c.g_signal_connect_data(
        dialog,
        "response",
        @ptrCast(&onPasswordDialogResponse),
        null,
        null,
        0,
    );

    c.gtk_widget_show(@ptrCast(dialog));
}

export fn onPasswordDialogResponse(dialog: *c.GtkDialog, response_id: c_int, user_data: ?*anyopaque) void {
    _ = user_data;

    if (response_id == c.GTK_RESPONSE_OK) {
        const backup_path_ptr = c.g_object_get_data(@ptrCast(dialog), "backup_path");
        const password_entry = c.g_object_get_data(@ptrCast(dialog), "password_entry");

        if (backup_path_ptr != null and password_entry != null) {
            const backup_path = std.mem.span(@as([*:0]const u8, @ptrCast(backup_path_ptr)));
            const password_text = c.gtk_editable_get_text(@ptrCast(password_entry));
            const password = if (password_text) |t| std.mem.span(t) else null;

            performRestore(backup_path, password);
        }
    }

    c.gtk_window_destroy(@ptrCast(dialog));
}

fn freeGString(data: ?*anyopaque) callconv(.C) void {
    if (data) |ptr| {
        const str = std.mem.span(@as([*:0]u8, @ptrCast(ptr)));
        g_allocator.free(str);
    }
}

fn performRestore(backup_path: String, password_param: ?String) void {
    const password = password_param;

    g_progress_state.update("Restoring backup...", 0, 100);
    g_progress_state.setActive(true);

    if (g_timeout_source_id != 0) {
        _ = c.g_source_remove(g_timeout_source_id);
        g_timeout_source_id = 0;
    }

    const context = g_allocator.create(RestoreContext) catch {
        g_progress_state.update("Restore failed", 0, 100);
        g_progress_state.setActive(false);
        return;
    };
    context.* = .{
        .backup_path = g_allocator.dupe(u8, backup_path) catch {
            g_allocator.destroy(context);
            g_progress_state.update("Restore failed", 0, 100);
            g_progress_state.setActive(false);
            return;
        },
        .password = if (password) |pwd| g_allocator.dupe(u8, pwd) catch null else null,
    };

    const thread = std.Thread.spawn(.{}, performRestoreThread, .{context}) catch {
        context.deinit();
        g_allocator.destroy(context);
        g_progress_state.setActive(false);
        return;
    };
    thread.detach();

    g_timeout_source_id = c.g_timeout_add(100, updateProgressUI, null);
}

fn performRestoreThread(context: *RestoreContext) void {
    defer {
        context.deinit();
        g_allocator.destroy(context);
    }

    var engine = backup.BackupEngine.init(g_allocator) catch |err| {
        errors.logError(err, null);
        const err_msg = std.fmt.allocPrint(g_allocator, "Restore failed: {s}", .{@errorName(err)}) catch "Restore failed: Out of memory";
        defer if (!std.mem.eql(u8, err_msg, "Restore failed: Out of memory")) g_allocator.free(err_msg);
        g_progress_state.update(err_msg, 0, 100);
        // Keep active for 3 seconds to show error
        std.time.sleep(3 * std.time.ns_per_s);
        g_progress_state.setActive(false);
        return;
    };
    defer engine.deinit();

    engine.restoreBackup(context.backup_path, context.password, null, &guiProgressCallback) catch |err| {
        errors.logError(err, null);
        const err_msg = std.fmt.allocPrint(g_allocator, "Restore failed: {s}", .{@errorName(err)}) catch "Restore failed: Unknown error";
        defer if (!std.mem.eql(u8, err_msg, "Restore failed: Unknown error")) g_allocator.free(err_msg);
        g_progress_state.update(err_msg, 0, 100);
        // Keep active for 3 seconds to show error
        std.time.sleep(3 * std.time.ns_per_s);
        g_progress_state.setActive(false);
        return;
    };

    g_progress_state.update("Restore completed successfully!", 100, 100);
    std.time.sleep(5 * std.time.ns_per_s);
    g_progress_state.setActive(false);
}

export fn on_activate(app: *c.GtkApplication, user_data: ?*anyopaque) void {
    _ = user_data;

    // Create main window
    const window = c.gtk_application_window_new(app);
    g_main_window = @ptrCast(window);
    c.gtk_window_set_title(@ptrCast(window), "Khrowno Backup Tool");
    c.gtk_window_set_default_size(@ptrCast(window), 700, 600);

    // Create header bar
    const header = c.gtk_header_bar_new();
    c.gtk_window_set_titlebar(@ptrCast(window), header);

    // Add theme selector to header
    g_theme_combo = @ptrCast(c.gtk_combo_box_text_new());
    c.gtk_combo_box_text_append_text(g_theme_combo, "Fluent");
    c.gtk_combo_box_text_append_text(g_theme_combo, "Metro");
    c.gtk_combo_box_text_append_text(g_theme_combo, "Adwaita");
    c.gtk_combo_box_text_append_text(g_theme_combo, "Nord");
    c.gtk_combo_box_set_active(@ptrCast(@alignCast(g_theme_combo)), 0); // Default to Fluent
    _ = c.g_signal_connect_data(g_theme_combo, "changed", @ptrCast(&on_theme_changed), null, null, 0);
    c.gtk_header_bar_pack_end(@ptrCast(header), @ptrCast(@alignCast(g_theme_combo)));

    // Create scrolled window for content
    const scrolled = c.gtk_scrolled_window_new();
    c.gtk_scrolled_window_set_policy(@ptrCast(scrolled), c.GTK_POLICY_NEVER, c.GTK_POLICY_AUTOMATIC);
    c.gtk_window_set_child(@ptrCast(window), scrolled);

    // Create main box
    const main_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 12);
    c.gtk_widget_set_margin_start(main_box, 24);
    c.gtk_widget_set_margin_end(main_box, 24);
    c.gtk_widget_set_margin_top(main_box, 24);
    c.gtk_widget_set_margin_bottom(main_box, 24);
    c.gtk_scrolled_window_set_child(@ptrCast(scrolled), main_box);

    // Title
    const title = c.gtk_label_new("Khrowno Backup Tool");
    c.gtk_widget_add_css_class(title, "title-1");
    c.gtk_box_append(@ptrCast(main_box), title);

    // Subtitle
    const subtitle = c.gtk_label_new("Secure Linux backup and restore");
    c.gtk_widget_add_css_class(subtitle, "dim-label");
    c.gtk_box_append(@ptrCast(main_box), subtitle);

    // Strategy frame
    const strategy_frame = c.gtk_frame_new("Backup Strategy");
    c.gtk_box_append(@ptrCast(main_box), strategy_frame);

    const strategy_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_set_margin_start(strategy_box, 12);
    c.gtk_widget_set_margin_end(strategy_box, 12);
    c.gtk_widget_set_margin_top(strategy_box, 12);
    c.gtk_widget_set_margin_bottom(strategy_box, 12);
    c.gtk_frame_set_child(@ptrCast(strategy_frame), strategy_box);

    g_minimal_radio = @ptrCast(c.gtk_check_button_new_with_label("Minimal - Critical configs + keys"));
    g_standard_radio = @ptrCast(c.gtk_check_button_new_with_label("Standard - Documents + Dev + Configs (no media) [Recommended]"));
    g_comprehensive_radio = @ptrCast(c.gtk_check_button_new_with_label("Comprehensive - Includes media + extras"));
    g_paranoid_radio = @ptrCast(c.gtk_check_button_new_with_label("Paranoid (~500MB+) - Complete system snapshot"));

    c.gtk_check_button_set_group(g_standard_radio, g_minimal_radio);
    c.gtk_check_button_set_group(g_comprehensive_radio, g_minimal_radio);
    c.gtk_check_button_set_group(g_paranoid_radio, g_minimal_radio);
    c.gtk_check_button_set_active(g_standard_radio, 1);

    c.gtk_box_append(@ptrCast(strategy_box), @ptrCast(g_minimal_radio));
    c.gtk_box_append(@ptrCast(strategy_box), @ptrCast(g_standard_radio));
    c.gtk_box_append(@ptrCast(strategy_box), @ptrCast(g_comprehensive_radio));
    c.gtk_box_append(@ptrCast(strategy_box), @ptrCast(g_paranoid_radio));

    // Output file frame
    const file_frame = c.gtk_frame_new("Output File");
    c.gtk_box_append(@ptrCast(main_box), file_frame);

    const file_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
    c.gtk_widget_set_margin_start(file_box, 12);
    c.gtk_widget_set_margin_end(file_box, 12);
    c.gtk_widget_set_margin_top(file_box, 12);
    c.gtk_widget_set_margin_bottom(file_box, 12);
    c.gtk_frame_set_child(@ptrCast(file_frame), file_box);

    g_output_path_entry = @ptrCast(c.gtk_entry_new());
    c.gtk_entry_set_placeholder_text(@ptrCast(g_output_path_entry), "Choose backup location...");
    c.gtk_widget_set_hexpand(@ptrCast(g_output_path_entry), 1);
    c.gtk_box_append(@ptrCast(file_box), @ptrCast(g_output_path_entry));

    const choose_button = c.gtk_button_new_with_label("Browse...");
    _ = c.g_signal_connect_data(choose_button, "clicked", @ptrCast(&on_choose_file_clicked), null, null, 0);
    c.gtk_box_append(@ptrCast(file_box), choose_button);

    // Encryption frame
    const encrypt_frame = c.gtk_frame_new("Encryption");
    c.gtk_box_append(@ptrCast(main_box), encrypt_frame);

    const encrypt_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_set_margin_start(encrypt_box, 12);
    c.gtk_widget_set_margin_end(encrypt_box, 12);
    c.gtk_widget_set_margin_top(encrypt_box, 12);
    c.gtk_widget_set_margin_bottom(encrypt_box, 12);
    c.gtk_frame_set_child(@ptrCast(encrypt_frame), encrypt_box);

    g_encrypt_check = @ptrCast(c.gtk_check_button_new_with_label("Enable encryption (ChaCha20-Poly1305)"));
    c.gtk_check_button_set_active(g_encrypt_check, 0);
    c.gtk_box_append(@ptrCast(encrypt_box), @ptrCast(g_encrypt_check));

    g_password_entry = @ptrCast(c.gtk_entry_new());
    c.gtk_entry_set_placeholder_text(@ptrCast(g_password_entry), "Enter password (min 8 chars, mixed case + numbers)...");
    c.gtk_entry_set_visibility(@ptrCast(g_password_entry), 0);
    c.gtk_entry_set_input_purpose(@ptrCast(g_password_entry), c.GTK_INPUT_PURPOSE_PASSWORD);
    _ = c.g_signal_connect_data(g_password_entry, "changed", @ptrCast(&on_password_changed), null, null, 0);
    c.gtk_box_append(@ptrCast(encrypt_box), @ptrCast(g_password_entry));

    // Password strength indicator
    const strength_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 4);
    c.gtk_box_append(@ptrCast(encrypt_box), strength_box);

    g_password_strength_label = @ptrCast(c.gtk_label_new("Password strength: None"));
    c.gtk_widget_set_halign(@ptrCast(@alignCast(g_password_strength_label)), c.GTK_ALIGN_START);
    c.gtk_widget_add_css_class(@ptrCast(@alignCast(g_password_strength_label)), "dim-label");
    c.gtk_box_append(@ptrCast(strength_box), @ptrCast(@alignCast(g_password_strength_label)));

    g_password_strength_bar = @ptrCast(c.gtk_progress_bar_new());
    c.gtk_progress_bar_set_fraction(g_password_strength_bar, 0.0);
    c.gtk_widget_set_size_request(@ptrCast(@alignCast(g_password_strength_bar)), -1, 8);
    c.gtk_box_append(@ptrCast(strength_box), @ptrCast(@alignCast(g_password_strength_bar)));

    // Confirm password entry to prevent mistakes
    g_confirm_password_entry = @ptrCast(c.gtk_entry_new());
    c.gtk_entry_set_placeholder_text(@ptrCast(g_confirm_password_entry), "Confirm password...");
    c.gtk_entry_set_visibility(@ptrCast(g_confirm_password_entry), 0);
    c.gtk_entry_set_input_purpose(@ptrCast(g_confirm_password_entry), c.GTK_INPUT_PURPOSE_PASSWORD);
    c.gtk_box_append(@ptrCast(encrypt_box), @ptrCast(g_confirm_password_entry));

    // Info label about current encryption behavior - streaming module exists but not integrated yet
    const enc_note = c.gtk_label_new("Note: Large encrypted backups load fully into memory. Streaming encryption module exists but needs integration.");
    c.gtk_widget_add_css_class(enc_note, "dim-label");
    c.gtk_label_set_wrap(@ptrCast(enc_note), 1); // wrap text for better visibility on some themes
    c.gtk_box_append(@ptrCast(encrypt_box), enc_note);

    // Action buttons
    const button_box = c.gtk_box_new(c.GTK_ORIENTATION_HORIZONTAL, 12);
    c.gtk_widget_set_halign(button_box, c.GTK_ALIGN_CENTER);
    c.gtk_widget_set_margin_top(button_box, 12);
    c.gtk_box_append(@ptrCast(main_box), button_box);

    const backup_button = c.gtk_button_new_with_label("Create Backup");
    c.gtk_widget_add_css_class(backup_button, "suggested-action");
    c.gtk_widget_set_size_request(backup_button, 180, 40);
    _ = c.g_signal_connect_data(backup_button, "clicked", @ptrCast(&on_backup_clicked), null, null, 0);
    c.gtk_box_append(@ptrCast(button_box), backup_button);

    const restore_button = c.gtk_button_new_with_label("Restore Backup");
    c.gtk_widget_set_size_request(restore_button, 180, 40);
    _ = c.g_signal_connect_data(restore_button, "clicked", @ptrCast(&on_restore_clicked), null, null, 0);
    c.gtk_box_append(@ptrCast(button_box), restore_button);

    // Progress section
    const progress_frame = c.gtk_frame_new("Progress");
    c.gtk_box_append(@ptrCast(main_box), progress_frame);

    const progress_box = c.gtk_box_new(c.GTK_ORIENTATION_VERTICAL, 8);
    c.gtk_widget_set_margin_start(progress_box, 12);
    c.gtk_widget_set_margin_end(progress_box, 12);
    c.gtk_widget_set_margin_top(progress_box, 12);
    c.gtk_widget_set_margin_bottom(progress_box, 12);
    c.gtk_frame_set_child(@ptrCast(progress_frame), progress_box);

    g_progress_bar = @ptrCast(c.gtk_progress_bar_new());
    c.gtk_progress_bar_set_show_text(g_progress_bar, 1);
    c.gtk_box_append(@ptrCast(progress_box), @ptrCast(@alignCast(g_progress_bar)));

    g_status_label = @ptrCast(c.gtk_label_new("Ready"));
    c.gtk_widget_set_margin_top(@ptrCast(@alignCast(g_status_label)), 8);
    c.gtk_box_append(@ptrCast(progress_box), @ptrCast(@alignCast(g_status_label)));

    // Load default theme
    loadTheme("fluent") catch {};

    c.gtk_window_present(@ptrCast(window));
}

pub fn launchGUI(alloc: std.mem.Allocator) !void {
    _ = alloc;
    g_allocator = std.heap.c_allocator;
    g_progress_state = ProgressState.init();

    // Create GTK application
    // See: https://docs.gtk.org/gtk4/class.Application.html
    const app = c.gtk_application_new("com.khrowno.backup", c.G_APPLICATION_DEFAULT_FLAGS);
    defer c.g_object_unref(app);

    _ = c.g_signal_connect_data(
        app,
        "activate",
        @ptrCast(&on_activate),
        null,
        null,
        0,
    );

    // Run application
    const status = c.g_application_run(@ptrCast(app), 0, null);
    if (status != 0) {
        return error.GuiInitializationFailed;
    }

    // Cleanup
    if (g_selected_output_path) |path| {
        g_allocator.free(path);
    }

    // Cleanup CSS provider
    if (g_css_provider) |provider| {
        c.g_object_unref(provider);
        g_css_provider = null;
    }

    // Remove any remaining timeout
    if (g_timeout_source_id != 0) {
        _ = c.g_source_remove(g_timeout_source_id);
        g_timeout_source_id = 0;
    }
}
