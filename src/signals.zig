const std = @import("std");
const linux = std.os.linux;

// Buffer estático para armazenar o caminho do arquivo sem alocar memória no signal handler
var cleanup_path_buf: [2048]u8 = undefined;
var cleanup_path_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

/// Registra o caminho do arquivo ativo para deleção caso o processo receba SIGINT/SIGTERM
pub fn registerCleanupPath(path: []const u8) void {
    if (path.len < cleanup_path_buf.len) {
        @memcpy(cleanup_path_buf[0..path.len], path);
        cleanup_path_buf[path.len] = 0; // Null-terminated para as chamadas de sistema
        cleanup_path_len.store(path.len, .release);
    }
}

/// Limpa o registro após o download ser concluído com sucesso
pub fn unregisterCleanupPath() void {
    cleanup_path_len.store(0, .release);
}

/// Configura os manipuladores para capturar SIGINT e SIGTERM
pub fn initSignalHandlers() !void {
    const sa = linux.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = linux.sigemptyset(),
        .flags = 0,
    };

    // Caso a chamada falhe (retorno diferente de 0), lançamos um erro manual do Zig.
    if (linux.sigaction(linux.SIG.INT, &sa, null) != 0) return error.SignalHandlerSetupFailed;
    if (linux.sigaction(linux.SIG.TERM, &sa, null) != 0) return error.SignalHandlerSetupFailed;
}

fn handleSignal(sig: linux.SIG) callconv(.c) void {
    _ = sig;
    const len = cleanup_path_len.load(.acquire);
    if (len > 0) {
        // Para garantir que o Signal Handler seja seguro (Async-Signal-Safe)
        const path_slice = cleanup_path_buf[0..len :0];

        // 1. Remove o arquivo usando a syscall direta (AT_FDCWD = -100 no Linux)
        _ = linux.unlinkat(-100, path_slice, 0);

        // 2. Escreve no stderr (FD 2) usando a syscall write direta para evitar pânico por IO complexo
        const msg = "\n\n[CLEANUP] Download cancelado pelo utilizador (Ctrl+C). Arquivo parcial removido.\n";
        _ = linux.write(2, msg, msg.len);
    }

    // Termina o processo imediatamente
    linux.exit_group(130);
}
