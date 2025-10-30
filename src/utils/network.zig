const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const String = types.String;
const http_client = @import("http_client.zig");
pub const HttpClient = http_client.HttpClient;
pub const HttpResponse = http_client.HttpResponse;
pub const HttpError = http_client.HttpError;
pub const RepositoryChecker = http_client.RepositoryChecker;
pub const RateLimiter = struct {
    last_request_time: types.Timestamp,
    min_interval_ms: u64,

    const Self = @This();

    pub fn init(min_interval_ms: u64) Self {
        return Self{
            .last_request_time = 0,
            .min_interval_ms = min_interval_ms,
        };
    }

    pub fn waitIfNeeded(self: *Self) void {
        const current_time = std.time.milliTimestamp();
        const elapsed = current_time - self.last_request_time;

        if (elapsed < @as(i64, @intCast(self.min_interval_ms))) {
            const sleep_time = self.min_interval_ms - @as(u64, @intCast(elapsed));
            std.time.sleep(sleep_time * std.time.ns_per_ms);
        }

        self.last_request_time = std.time.milliTimestamp();
    }
};

pub fn isOnline() bool {
    const test_url = "https://www.google.com";
    var client = HttpClient.init(std.heap.page_allocator) catch return false;
    defer client.deinit();

    var response = client.get(test_url) catch return false;
    defer response.deinit();

    return response.status_code >= 200 and response.status_code < 400;
}

pub const NetworkManager = struct {
    allocator: Allocator,
    client: HttpClient,
    repository_checker: RepositoryChecker,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .allocator = allocator,
            .client = try HttpClient.init(allocator),
            .repository_checker = try RepositoryChecker.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.repository_checker.deinit();
        self.client.deinit();
    }

    pub fn checkRepository(self: *Self, url: String) !bool {
        return self.repository_checker.checkRepository(url);
    }

    pub fn getPackageInfo(self: *Self, repo_url: String, package_name: String) !?String {
        return self.repository_checker.getPackageInfo(repo_url, package_name);
    }

    pub fn request(self: *Self, url: String) !HttpResponse {
        return self.client.get(url);
    }
};
