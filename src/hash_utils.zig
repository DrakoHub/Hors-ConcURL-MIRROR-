const std = @import("std");

pub fn verifyFileSha256(init: std.process.Init, file: std.Io.File, expected_hex: []const u8) !bool {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    var file_offset: u64 = 0;

    const file_size = (try file.stat(init.io)).size;

    while (file_offset < file_size) {
        const bytes_read = try file.readPositionalAll(init.io, &buf, file_offset);
        if (bytes_read == 0) break;
        hasher.update(buf[0..bytes_read]);
        file_offset += bytes_read;
    }

    var digest: [32]u8 = undefined;
    hasher.final(&digest);

    var hex_buf: [64]u8 = undefined;
    const computed_hex = std.fmt.bytesToHex(digest, .lower);
    @memcpy(&hex_buf, &computed_hex);

    return std.ascii.eqlIgnoreCase(&hex_buf, expected_hex);
}
