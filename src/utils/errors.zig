const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const String = types.String;
const FileSize = types.FileSize;
pub const KhrownoError = error{
    FileNotFound,
    FileAccessDenied,
    DirectoryNotFound,
    DirectoryAccessDenied,
    DiskFull,
    FileAlreadyExists,
    InvalidPath,
    BackupCreationFailed,
    BackupCorrupted,
    RestoreFailed,
    InvalidBackupFormat,
    BackupTooLarge,
    InsufficientSpace,

    EncryptionFailed,
    DecryptionFailed,
    InvalidPassword,
    WeakPassword,
    KeyDerivationFailed,
    AuthenticationFailed,

    CompressionFailed,
    DecompressionFailed,
    InvalidCompressedData,
    UnsupportedCompressionFormat,

    NetworkUnavailable,
    ConnectionFailed,
    DownloadFailed,
    TimeoutError,
    InvalidUrl,

    PackageManagerNotFound,
    PackageListEmpty,
    PackageInstallFailed,
    PackageResolutionFailed,
    UnsupportedDistribution,

    GuiInitializationFailed,
    InvalidGuiState,
    WidgetCreationFailed,

    InvalidConfiguration,
    ConfigurationNotFound,
    ConfigurationParseError,

    OutOfMemory,
    InvalidArgument,
    OperationCancelled,
    UnknownError,
};

pub const ErrorContext = struct {
    error_type: KhrownoError,
    message: String,
    file_path: ?String = null,
    line_number: ?u32 = null,
    additional_info: ?String = null,

    pub fn getUserMessage(self: *const ErrorContext) String {
        return self.message;
    }

    pub fn getDetailedMessage(self: *const ErrorContext, allocator: std.mem.Allocator) ![]u8 {
        var parts = std.ArrayList(u8).init(allocator);
        errdefer parts.deinit();

        try parts.writer().print("Error: {s}\n", .{self.message});

        if (self.file_path) |path| {
            try parts.writer().print("  File: {s}", .{path});
            if (self.line_number) |line| {
                try parts.writer().print(":{d}", .{line});
            }
            try parts.writer().writeAll("\n");
        }

        if (self.additional_info) |info| {
            try parts.writer().print("  Details: {s}\n", .{info});
        }

        return parts.toOwnedSlice();
    }
};

pub fn getErrorMessage(err: anyerror) String {
    return switch (err) {
        error.FileNotFound => "File not found. Please check the path and try again.",
        error.FileAccessDenied => "Access denied. You don't have permission to access this file.",
        error.DirectoryNotFound => "Directory not found. Please verify the path exists.",
        error.DirectoryAccessDenied => "Access denied. You don't have permission to access this directory.",
        error.DiskFull => "Disk is full. Please free up space and try again.",
        error.FileAlreadyExists => "File already exists. Choose a different name or delete the existing file.",
        error.InvalidPath => "Invalid file path. Please check the path format.",

        error.BackupCreationFailed => "Failed to create backup. Check disk space and permissions.",
        error.BackupCorrupted => "Backup file is corrupted or incomplete. Cannot restore.",
        error.RestoreFailed => "Failed to restore backup. Check the backup file integrity.",
        error.InvalidBackupFormat => "Invalid backup format. This file may not be a valid Khrowno backup.",
        error.BackupTooLarge => "Backup size exceeds available memory. Try a smaller backup strategy.",
        error.InsufficientSpace => "Not enough disk space to complete the operation.",

        error.EncryptionFailed => "Encryption failed. Your data was not encrypted.",
        error.DecryptionFailed => "Decryption failed. The backup file may be corrupted.",
        error.InvalidPassword => "Incorrect password. Please try again.",
        error.WeakPassword => "Password is too weak. Use at least 8 characters with mixed case and numbers.",
        error.KeyDerivationFailed => "Failed to derive encryption key from password.",
        error.AuthenticationFailed => "Authentication failed. The backup may have been tampered with.",

        error.CompressionFailed => "Failed to compress data. Check available memory.",
        error.DecompressionFailed => "Failed to decompress data. The backup may be corrupted.",
        error.InvalidCompressedData => "Invalid compressed data format.",
        error.UnsupportedCompressionFormat => "Unsupported compression format. Only gzip is supported.",

        error.NetworkUnavailable => "Network is unavailable. Check your internet connection.",
        error.ConnectionFailed => "Failed to connect to server. Check your network settings.",
        error.DownloadFailed => "Download failed. Please try again later.",
        error.TimeoutError => "Operation timed out. The server may be slow or unreachable.",
        error.InvalidUrl => "Invalid URL format.",

        error.PackageManagerNotFound => "Package manager not found. Is it installed on your system?",
        error.PackageListEmpty => "No packages found to backup.",
        error.PackageInstallFailed => "Failed to install package. Check your package manager.",
        error.PackageResolutionFailed => "Failed to resolve package dependencies.",
        error.UnsupportedDistribution => "Your Linux distribution is not supported. Supported: Fedora, Ubuntu, Debian, Mint, Arch, NixOS.",

        error.GuiInitializationFailed => "Failed to initialize GUI. Is GTK4 installed?",
        error.InvalidGuiState => "Invalid GUI state. Please restart the application.",
        error.WidgetCreationFailed => "Failed to create GUI widget.",

        error.InvalidConfiguration => "Invalid configuration. Check your config file.",
        error.ConfigurationNotFound => "Configuration file not found. Using defaults.",
        error.ConfigurationParseError => "Failed to parse configuration file.",

        error.OutOfMemory => "Out of memory. Close other applications and try again.",
        error.InvalidArgument => "Invalid argument provided. Check the command syntax.",
        error.OperationCancelled => "Operation was cancelled by user.",
        error.UnknownError => "An unknown error occurred. Please report this bug.",

        error.AccessDenied => "Access denied. Check file permissions.",
        error.IsDir => "Expected a file but found a directory.",
        error.NotDir => "Expected a directory but found a file.",
        error.NoSpaceLeft => "No space left on device.",
        error.PathAlreadyExists => "Path already exists.",
        error.FileTooBig => "File is too large to process.",
        error.NameTooLong => "File or directory name is too long.",
        error.InvalidUtf8 => "Invalid UTF-8 encoding in file.",
        error.BadPathName => "Invalid path name.",
        error.SymLinkLoop => "Symbolic link loop detected.",
        error.ProcessFdQuotaExceeded => "Too many open files.",
        error.SystemFdQuotaExceeded => "System file descriptor limit reached.",
        error.DeviceBusy => "Device is busy.",
        error.Unexpected => "An unexpected error occurred.",

        else => "An error occurred. Please check the logs for details.",
    };
}

pub fn logError(err: anyerror, context: ?ErrorContext) void {
    const stderr = std.io.getStdErr();

    stderr.writer().print("\n❌ Error: {s}\n", .{getErrorMessage(err)}) catch {};

    if (context) |ctx| {
        if (ctx.additional_info) |info| {
            stderr.writer().print("   Details: {s}\n", .{info}) catch {};
        }
        if (ctx.file_path) |path| {
            stderr.writer().print("   Location: {s}", .{path}) catch {};
            if (ctx.line_number) |line| {
                stderr.writer().print(":{d}", .{line}) catch {};
            }
            stderr.writeAll("\n") catch {};
        }
    }

    stderr.writeAll("\n") catch {};
}

pub fn makeContext(
    err: KhrownoError,
    message: String,
    file: ?String,
    line: ?u32,
    info: ?String,
) ErrorContext {
    return ErrorContext{
        .error_type = err,
        .message = message,
        .file_path = file,
        .line_number = line,
        .additional_info = info,
    };
}

pub fn validatePassword(password: String) !void {
    if (password.len < 8) {
        return error.WeakPassword;
    }

    var has_upper = false;
    var has_lower = false;
    var has_digit = false;

    for (password) |c| {
        if (c >= 'A' and c <= 'Z') has_upper = true;
        if (c >= 'a' and c <= 'z') has_lower = true;
        if (c >= '0' and c <= '9') has_digit = true;
    }

    const strength = @as(u8, @intFromBool(has_upper)) +
        @as(u8, @intFromBool(has_lower)) +
        @as(u8, @intFromBool(has_digit));

    if (strength < 2) {
        return error.WeakPassword;
    }
}

pub fn validatePath(path: String) !void {
    if (path.len == 0) {
        return error.InvalidPath;
    }

    for (path) |c| {
        if (c == 0) return error.InvalidPath;
    }
}

pub fn checkDiskSpace(path: String, required_bytes: FileSize) !void {
    // TODO: implement an actual free-space check (statfs/statvfs).
    _ = path;
    _ = required_bytes;

    // For now, rely on write operations to fail if space is insufficient.
}
