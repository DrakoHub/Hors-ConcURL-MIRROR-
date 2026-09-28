const std = @import("std");
const builtin = @import("builtin");

pub fn applyLandlockSandbox() void {
    if (comptime builtin.os.tag != .linux) return;

    const linux = std.os.linux;
    const SYS = linux.SYS;

    _ = linux.prctl(38, 1, 0, 0, 0);

    const LandlockRulesetAttr = extern struct {
        handled_access_fs: u64,
    };

    const attr = LandlockRulesetAttr{
        .handled_access_fs = (1 << 0) | (1 << 1),
    };

    const sys_landlock_create_ruleset: SYS = @enumFromInt(444);
    const sys_landlock_restrict_self: SYS = @enumFromInt(446);
    const sys_close: SYS = @enumFromInt(3);

    const ruleset_fd = linux.syscall3(
        sys_landlock_create_ruleset,
        @intFromPtr(&attr),
        @sizeOf(LandlockRulesetAttr),
        0,
    );

    if (@as(isize, @bitCast(ruleset_fd)) >= 0) {
        _ = linux.syscall2(sys_landlock_restrict_self, ruleset_fd, 0);
        _ = linux.syscall1(sys_close, ruleset_fd);
    }
}
