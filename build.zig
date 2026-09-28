const std = @import("std");

pub fn build(b: *std.Build) void {
    // -target x86_64-linux-musl (definido como padrão)
    const target = b.standardTargetOptions(.{
        .default_target = std.Target.Query.parse(.{
            .arch_os_abi = "x86_64-linux-musl",
        }) catch unreachable,
    });

    // -O ReleaseSafe (definido como preferencial/padrão)
    const optimize = b.standardOptimizeOption(.{
        .preferred_optimize_mode = .ReleaseSafe,
    });

    // Instancia o executável
    const exe = b.addExecutable(.{
        .name = "concurl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true, // --strip
            .pic = true, // Ativa Position Independent Code no módulo
        }),
    });

    // -fPIE: Ativa Position Independent Executable no binário final
    exe.pie = true;

    // Copia o binário final para zig-out/bin/minicurl
    b.installArtifact(exe);

    // Adiciona o comando 'zig build run -- <URL>'
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Executar o minicurl");
    run_step.dependOn(&run_cmd.step);
}
