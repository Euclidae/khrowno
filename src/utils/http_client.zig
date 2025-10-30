const std = @import("std");
const print = std.debug.print;
const ArrayList = std.ArrayList;
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const String = types.String;

const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const HttpError = error{
    CurlInitFailed,
    CurlSetOptFailed,
    CurlPerformFailed,
    MemoryAllocationFailed,
    InvalidUrl,
    Timeout,
    ConnectionFailed,
};

pub const HttpResponse = struct {
    status_code: u16,
    headers: ArrayList(HttpHeader),
    body: []u8,
    allocator: Allocator,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        for (self.headers.items) |h| {
            self.allocator.free(h.name);
            self.allocator.free(h.value);
        }
        self.headers.deinit();
        self.allocator.free(self.body);
    }

    pub fn getHeader(self: *const Self, name: String) ?String {
        for (self.headers.items) |header| {
            if (std.mem.eql(u8, header.name, name)) {
                return header.value;
            }
        }
        return null;
    }
};

pub const HttpHeader = struct {
    name: String,
    value: []u8,
};

pub const HttpClient = struct {
    allocator: Allocator,
    user_agent: String,
    timeout_ms: u32,
    max_redirects: u8,
    curl: ?*c.CURL,

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        const curl_result = c.curl_global_init(c.CURL_GLOBAL_DEFAULT);
        if (curl_result != c.CURLE_OK) {
            return HttpError.CurlInitFailed;
        }

        return Self{
            .allocator = allocator,
            .user_agent = "Krowno-Backup-Tool/0.3.0 (Linux; +https://github.com/user/khrowno)",
            .timeout_ms = 30000, // 30 seconds
            .max_redirects = 5,
            .curl = c.curl_easy_init(),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.curl) |curl| {
            c.curl_easy_cleanup(curl);
        }
        c.curl_global_cleanup();
    }

    pub fn get(self: *Self, url: String) !HttpResponse {
        if (self.curl == null) {
            return HttpError.CurlInitFailed;
        }

        const curl = self.curl.?;
        c.curl_easy_reset(curl);
        if (c.curl_easy_setopt(curl, c.CURLOPT_URL, url.ptr) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_USERAGENT, self.user_agent.ptr) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(self.timeout_ms))) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_MAXREDIRS, @as(c_long, @intCast(self.max_redirects))) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_FOLLOWLOCATION, @as(c_long, 1)) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_SSL_VERIFYPEER, @as(c_long, 1)) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        var response_body = ArrayList(u8).init(self.allocator);
        var response_headers = ArrayList(HttpHeader).init(self.allocator);
        if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEFUNCTION, writeCallback) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_WRITEDATA, &response_body) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_HEADERFUNCTION, headerCallback) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        if (c.curl_easy_setopt(curl, c.CURLOPT_HEADERDATA, &response_headers) != c.CURLE_OK) {
            return HttpError.CurlSetOptFailed;
        }

        const perform_result = c.curl_easy_perform(curl);
        if (perform_result != c.CURLE_OK) {
            for (response_headers.items) |h| {
                response_headers.allocator.free(h.name);
                response_headers.allocator.free(h.value);
            }
            response_headers.deinit();
            response_body.deinit();

            return switch (perform_result) {
                c.CURLE_OPERATION_TIMEDOUT => HttpError.Timeout,
                c.CURLE_COULDNT_CONNECT => HttpError.ConnectionFailed,
                else => HttpError.CurlPerformFailed,
            };
        }

        var status_code: c_long = 0;
        if (c.curl_easy_getinfo(curl, c.CURLINFO_RESPONSE_CODE, &status_code) != c.CURLE_OK) {
            for (response_headers.items) |h| {
                response_headers.allocator.free(h.name);
                response_headers.allocator.free(h.value);
            }
            response_headers.deinit();
            response_body.deinit();
            return HttpError.CurlPerformFailed;
        }

        return HttpResponse{
            .status_code = @intCast(status_code),
            .headers = response_headers,
            .body = response_body.toOwnedSlice() catch return HttpError.MemoryAllocationFailed,
            .allocator = self.allocator,
        };
    }
};

fn writeCallback(contents: [*c]u8, size: usize, nmemb: usize, userp: ?*anyopaque) callconv(.C) usize {
    const real_size = size * nmemb;
    const response_body = @as(*ArrayList(u8), @ptrCast(@alignCast(userp)));

    response_body.appendSlice(contents[0..real_size]) catch return 0;
    return real_size;
}

fn headerCallback(contents: [*c]u8, size: usize, nmemb: usize, userp: ?*anyopaque) callconv(.C) usize {
    const real_size = size * nmemb;
    const response_headers = @as(*ArrayList(HttpHeader), @ptrCast(@alignCast(userp)));

    const header_line = contents[0..real_size];

    if (header_line.len <= 2 or std.mem.indexOf(u8, header_line, ":") == null) {
        return real_size;
    }

    if (std.mem.indexOf(u8, header_line, ":")) |colon_pos| {
        const name = header_line[0..colon_pos];
        var value_start = colon_pos + 1;
        while (value_start < header_line.len and header_line[value_start] == ' ') {
            value_start += 1;
        }
        const value = header_line[value_start .. header_line.len - 2]; // Remove \r\n
        // Duplicate into owned memory since libcurl reuses buffers per callback
        const alloc = response_headers.allocator;
        const name_copy = alloc.dupe(u8, name) catch return 0;
        const value_copy = alloc.dupe(u8, value) catch {
            alloc.free(name_copy);
            return 0;
        };

        const header = HttpHeader{
            .name = name_copy,
            .value = value_copy,
        };

        response_headers.append(header) catch {
            alloc.free(name_copy);
            alloc.free(value_copy);
            return 0;
        };
    }

    return real_size;
}

pub const RepositoryChecker = struct {
    client: HttpClient,
    cache: std.HashMap(String, bool, std.hash_map.StringContext, std.hash_map.default_max_load_percentage),

    const Self = @This();

    pub fn init(allocator: Allocator) !Self {
        return Self{
            .client = try HttpClient.init(allocator),
            .cache = std.HashMap(String, bool, std.hash_map.StringContext, std.hash_map.default_max_load_percentage).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var iterator = self.cache.iterator();
        while (iterator.next()) |entry| {
            self.client.allocator.free(entry.key_ptr.*);
        }
        self.cache.deinit();
        self.client.deinit();
    }

    pub fn checkRepository(self: *Self, url: String) !bool {
        if (self.cache.get(url)) |cached_result| {
            return cached_result;
        }

        print("Checking repository: {s}\n", .{url});

        const response = self.client.get(url) catch |err| {
            print("Failed to check repository {s}: {any}\n", .{ url, err });
            const result = false;
            if (self.client.allocator.dupe(u8, url)) |key| {
                self.cache.put(key, result) catch {};
            } else |_| {}
            return result;
        };
        defer response.deinit();

        const is_accessible = response.status_code >= 200 and response.status_code < 400;

        if (self.client.allocator.dupe(u8, url)) |key| {
            self.cache.put(key, is_accessible) catch {};
        } else |_| {}

        print("Repository {s} is {s} (status: {d})\n", .{ url, if (is_accessible) "accessible" else "inaccessible", response.status_code });

        return is_accessible;
    }

    pub fn getPackageInfo(self: *Self, repo_url: String, package_name: String) !?String {
        const package_url = try std.fmt.allocPrint(self.client.allocator, "{s}/packages/{s}", .{ repo_url, package_name });
        defer self.client.allocator.free(package_url);

        const response = self.client.get(package_url) catch |err| {
            print("Failed to get package info for {s}: {any}\n", .{ package_name, err });
            return null;
        };
        defer response.deinit();

        if (response.status_code == 200) {
            const copy = try self.client.allocator.dupe(u8, response.body);
            return copy;
        }

        return null;
    }
};
