const std = @import("std");
const crypto = std.crypto;
const Allocator = std.mem.Allocator;
const types = @import("../utils/types.zig");
const String = types.String;

// the reason we want this is because we are collecting user data, technically. We are collecting identifiable data (CSC262)
// this means that if this tool gains a bit of popularity, someone might just yoink the khr file and well...

pub const CryptoError = error{
    EncryptionFailed,
    DecryptionFailed,
    InvalidKey,
    InvalidPassword,
    AuthenticationFailed, // poly1305 MAC check failed - either wrong password or data corruption
};

const ChaCha20Poly1305 = crypto.aead.chacha_poly.ChaCha20Poly1305;
const Argon2 = crypto.pwhash.argon2;

// using chacha20-poly1305 instead of AES-GCM because:
// 1. faster on CPUs without AES-NI (most users likely wont have it)
// 2. constant-time implementation easier, less side-channel risk

pub const EncryptedData = struct {
    salt: [32]u8, // need unique salt per password for argon2
    nonce: [12]u8, // NEVER reuse nonce with same key
    ciphertext: []u8,
    tag: [16]u8, // poly1305 MAC for authenticated encryption

    pub fn deinit(self: *EncryptedData, allocator: Allocator) void {
        allocator.free(self.ciphertext);
    }
};

pub const CryptoContext = struct {
    allocator: Allocator,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return Self{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    fn deriveKey(self: *Self, password: String, salt: String, key_out: []u8) !void {
        // argon2 params tuned for ~300ms delay on ryzen 9 5600HX
        // want it slow enough attackers cant bruteforce but fast enough users dont complain
        const params = Argon2.Params{
            .t = 3, // iterations
            .m = 65536, // 64MB memory - makes parallelization expensive for attackers
            .p = 4, // threads
        };

        try Argon2.kdf(
            self.allocator,
            key_out,
            password,
            salt,
            params,
            .argon2id, // hybrid of argon2i and argon2d - best of both
        );
    }

    pub fn encrypt(self: *Self, plaintext: String, password: String) !EncryptedData {
        var result: EncryptedData = undefined;

        crypto.random.bytes(&result.salt);
        crypto.random.bytes(&result.nonce);
        var key: [32]u8 = undefined;
        try self.deriveKey(password, &result.salt, &key);
        defer crypto.utils.secureZero(u8, &key); // wipe key so it doesnt sit in memory

        result.ciphertext = try self.allocator.alloc(u8, plaintext.len);
        errdefer self.allocator.free(result.ciphertext); // cleanup on error
        ChaCha20Poly1305.encrypt(
            result.ciphertext,
            &result.tag,
            plaintext,
            &[_]u8{}, // no additional data
            result.nonce,
            key,
        );

        return result;
    }

    pub fn decrypt(self: *Self, encrypted: EncryptedData, password: String) ![]u8 {
        var key: [32]u8 = undefined;
        try self.deriveKey(password, &encrypted.salt, &key);
        defer crypto.utils.secureZero(u8, &key);

        const plaintext = try self.allocator.alloc(u8, encrypted.ciphertext.len);
        errdefer self.allocator.free(plaintext);
        ChaCha20Poly1305.decrypt(
            plaintext,
            encrypted.ciphertext,
            encrypted.tag,
            &[_]u8{}, // no additional data
            encrypted.nonce,
            key,
        ) catch {
            self.allocator.free(plaintext);
            return CryptoError.AuthenticationFailed;
        };

        return plaintext;
    }

    pub fn serializeEncrypted(self: *Self, encrypted: EncryptedData) ![]u8 {
        const header = "KHROWNO_ENC_V1\n";
        const total_size = header.len + 32 + 12 + 16 + 8 + encrypted.ciphertext.len;

        var result = try self.allocator.alloc(u8, total_size);
        var pos: usize = 0; 

        @memcpy(result[pos .. pos + header.len], header);
        pos += header.len;

        @memcpy(result[pos .. pos + 32], &encrypted.salt);
        pos += 32;

        @memcpy(result[pos .. pos + 12], &encrypted.nonce);
        pos += 12;

        @memcpy(result[pos .. pos + 16], &encrypted.tag);
        pos += 16;
        const len_bytes = std.mem.toBytes(@as(u64, @intCast(encrypted.ciphertext.len)));
        @memcpy(result[pos .. pos + 8], &len_bytes);
        pos += 8;

        @memcpy(result[pos .. pos + encrypted.ciphertext.len], encrypted.ciphertext);

        return result;
    }

    pub fn deserializeEncrypted(self: *Self, data: String) !EncryptedData {
        const header = "KHROWNO_ENC_V1\n";

        if (data.len < header.len + 32 + 12 + 16 + 8) {
            return CryptoError.InvalidKey;
        }

        if (!std.mem.eql(u8, data[0..header.len], header)) {
            return CryptoError.InvalidKey;
        }

        var pos: usize = header.len;
        var result: EncryptedData = undefined;

        @memcpy(&result.salt, data[pos .. pos + 32]);
        pos += 32;

        @memcpy(&result.nonce, data[pos .. pos + 12]);
        pos += 12;

        @memcpy(&result.tag, data[pos .. pos + 16]);
        pos += 16;

        var len_bytes: [8]u8 = undefined;
        @memcpy(&len_bytes, data[pos .. pos + 8]);
        const ciphertext_len = std.mem.bytesToValue(u64, &len_bytes);
        pos += 8;

        if (pos + ciphertext_len != data.len) {
            return CryptoError.InvalidKey;
        }

        result.ciphertext = try self.allocator.alloc(u8, ciphertext_len);
        @memcpy(result.ciphertext, data[pos .. pos + ciphertext_len]);

        return result;
    }
};

pub fn hashData(data: String) [32]u8 {
    var hash: [32]u8 = undefined;
    crypto.hash.sha2.Sha256.hash(data, &hash, .{});
    return hash;
}

pub fn verifyHash(data: String, expected_hash: [32]u8) bool {
    const actual_hash = hashData(data);
    return crypto.utils.timingSafeEql([32]u8, actual_hash, expected_hash);
}

pub fn hashPasswordWithSalt(allocator: Allocator, password: String, salt: String) ![]u8 {
    var key: [32]u8 = undefined;
    const params = Argon2.Params{
        .t = 3,
        .m = 65536,
        .p = 4,
    };

    try Argon2.kdf(
        allocator,
        &key,
        password,
        salt,
        params,
        .argon2id,
    );

    return try std.fmt.allocPrint(allocator, "{s}", .{std.fmt.fmtSliceHexLower(&key)});
}
