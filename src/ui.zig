const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

const LinuxWinSize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

pub fn isTty() bool {
    if (comptime builtin.os.tag != .linux) return true;
    var wsz: LinuxWinSize = undefined;
    const rc = linux.syscall3(.ioctl, 2, linux.T.IOCGWINSZ, @intFromPtr(&wsz));
    return rc <= 0 or rc > @as(usize, @bitCast(@as(isize, -4095)));
}

pub fn formatBytes(bytes: u64, buf: []u8) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var count: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (count >= 1024.0 and unit_idx < units.len - 1) : (unit_idx += 1) {
        count /= 1024.0;
    }

    return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ count, units[unit_idx] }) catch "0 B";
}

pub fn renderProgressBar(current: usize, total: ?u64, elapsed_ms: i64, silent: bool) void {
    if (silent or !isTty()) return;
    const width: usize = 20;

    const elapsed_sec = @max(@as(f64, @floatFromInt(elapsed_ms)) / 1000.0, 0.001);
    const bytes_per_sec = @as(f64, @floatFromInt(current)) / elapsed_sec;

    var cur_buf: [32]u8 = undefined;
    const cur_str = formatBytes(current, &cur_buf);

    var speed_buf: [32]u8 = undefined;
    const speed_str = formatBytes(@intFromFloat(bytes_per_sec), &speed_buf);

    if (total) |t| {
        if (t == 0) return;
        const percent = (current * 100) / t;
        const filled = (current * width) / t;

        var eta_buf: [32]u8 = undefined;
        const eta_str = if (bytes_per_sec > 0 and current < t) blk: {
            const remaining_bytes = t - current;
            const eta_sec: u64 = @intFromFloat(@as(f64, @floatFromInt(remaining_bytes)) / bytes_per_sec);
            const hours = eta_sec / 3600;
            const mins = (eta_sec % 3600) / 60;
            const secs = eta_sec % 60;

            if (hours > 0) {
                break :blk std.fmt.bufPrint(&eta_buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hours, mins, secs }) catch "--:--";
            } else {
                break :blk std.fmt.bufPrint(&eta_buf, "{d:0>2}:{d:0>2}", .{ mins, secs }) catch "--:--";
            }
        } else "00:00";

        var tot_buf: [32]u8 = undefined;
        const tot_str = formatBytes(t, &tot_buf);

        std.debug.print("\r\x1b[K[", .{});
        var i: usize = 0;
        while (i < width) : (i += 1) {
            if (i < filled) {
                std.debug.print("■", .{});
            } else if (i == filled) {
                std.debug.print("▶", .{});
            } else {
                std.debug.print("▫", .{});
            }
        }
        std.debug.print("] {d:>3}% | {s} / {s} | {s}/s | ETA {s}", .{
            percent,
            cur_str,
            tot_str,
            speed_str,
            eta_str,
        });
    } else {
        std.debug.print("\r\x1b[KDescarregados: {s} | {s}/s...", .{ cur_str, speed_str });
    }
}

pub fn finishProgressBar(silent: bool) void {
    if (silent or !isTty()) return;
    std.debug.print("\r\x1b[K", .{});
}
