const std = @import("std");
const cli = @import("cli.zig");
const ui = @import("ui.zig");

const READ_BUFFER_SIZE: usize = 128 * 1024;
const READ_TIMEOUT_MS: i64 = 30_000;

pub fn execute(
    init: std.process.Init,
    config: cli.Config,
    response: anytype,
    out_file: ?std.Io.File,
    existing_file_size: u64,
    total_expected_size: ?u64,
    accepts_ranges: bool,
) !void {
    if (!config.silent) {
        if (config.jobs > 1) {
            if (out_file == null) {
                std.debug.print("Modo de Download: Single-thread (Fallback: saída para stdout)\n", .{});
            } else if (existing_file_size > 0) {
                std.debug.print("Modo de Download: Single-thread (Fallback: retomando arquivo)\n", .{});
            } else if (total_expected_size == null or total_expected_size.? == 0) {
                std.debug.print("Modo de Download: Single-thread (Fallback: Content-Length ausente)\n", .{});
            } else if (!accepts_ranges) {
                std.debug.print("Modo de Download: Single-thread (Fallback: servidor não suporta Ranges)\n", .{});
            } else {
                std.debug.print("Modo de Download: Single-thread (Fallback)\n", .{});
            }
        } else {
            std.debug.print("Modo de Download: Single-thread\n", .{});
        }
    }

    var transfer_buf: [READ_BUFFER_SIZE]u8 = undefined;
    var read_buf: [READ_BUFFER_SIZE]u8 = undefined;
    var total_bytes_read: usize = existing_file_size;

    var file_position: u64 = existing_file_size;
    var body_reader = response.reader(&transfer_buf);

    var stdout_buffer: [READ_BUFFER_SIZE]u8 = undefined;
    var stdout_file = std.Io.File.stdout();
    var stdout_writer = stdout_file.writer(init.io, &stdout_buffer);

    const start_time = std.Io.Clock.awake.now(init.io);
    var last_read_time = start_time;

    while (true) {
        const chunk_start_time = std.Io.Clock.awake.now(init.io);

        const idle_ms = last_read_time.durationTo(chunk_start_time).toMilliseconds();
        if (idle_ms > READ_TIMEOUT_MS) {
            if (!config.silent) {
                std.debug.print("\n[ERRO DE REDE] Timeout: Servidor parou de enviar dados por mais de {d}s.\n", .{@divFloor(READ_TIMEOUT_MS, 1000)});
            }
            return error.ReadTimeout;
        }

        const bytes_read = body_reader.readSliceShort(&read_buf) catch |err| {
            if (!config.silent) {
                std.debug.print("\nErro durante a transferência de dados: {}\n", .{err});
            }
            return err;
        };

        if (bytes_read == 0) break;
        last_read_time = std.Io.Clock.awake.now(init.io);

        total_bytes_read += bytes_read;

        if (total_bytes_read > config.max_filesize_bytes) {
            if (!config.silent) {
                std.debug.print("\n[ERRO DE SEGURANÇA] O streaming excedeu o limite máximo configurado.\n", .{});
            }
            return error.FileTooLarge;
        }

        if (out_file) |*file| {
            try file.writePositionalAll(init.io, read_buf[0..bytes_read], file_position);
            file_position += bytes_read;

            const elapsed_ms = start_time.untilNow(init.io, .awake).toMilliseconds();
            ui.renderProgressBar(total_bytes_read, total_expected_size orelse 0, elapsed_ms, config.silent);
        } else {
            try stdout_writer.interface.writeAll(read_buf[0..bytes_read]);
            try stdout_writer.interface.flush();
        }

        // --- CONTROLO DE VELOCIDADE (RATE LIMITING) ---
        if (config.limit_rate_bytes_per_sec > 0) {
            const expected_ms: i64 = @intCast((@as(u64, bytes_read) * 1000) / config.limit_rate_bytes_per_sec);
            const chunk_elapsed_ms = chunk_start_time.untilNow(init.io, .awake).toMilliseconds();

            if (expected_ms > chunk_elapsed_ms) {
                const sleep_ms: u64 = @intCast(expected_ms - chunk_elapsed_ms);
                try std.Io.sleep(init.io, .fromMilliseconds(@intCast(sleep_ms)), .awake);
            }
        }
    }

    if (out_file != null) {
        ui.finishProgressBar(config.silent);
        if (!config.silent) {
            var total_buf: [32]u8 = undefined;
            const formatted_total = ui.formatBytes(total_bytes_read, &total_buf);
            std.debug.print("Concluído: {s} ({d} bytes).\n", .{ formatted_total, total_bytes_read });
        }
    }
}
