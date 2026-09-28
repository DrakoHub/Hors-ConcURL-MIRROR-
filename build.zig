const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = std.Target.Query.parse(.{
            .arch_os_abi = "x86_64-linux-musl",
        }) catch unreachable,
    });

    const optimize = std.builtin.OptimizeMode.ReleaseSmall;

    const use_lto = b.option(bool, "lto", "Ativar LTO") orelse false;

    const exe = b.addExecutable(.{
        .name = "concurl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .pic = true,
        }),
    });

    exe.pie = true;
    exe.lto = if (use_lto) .full else .none;
    exe.root_module.unwind_tables = .none;

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Executar o minicurl");
    run_step.dependOn(&run_cmd.step);
}
