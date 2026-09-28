const std = @import("std");
const cli = @import("cli.zig");
const sandbox = @import("sandbox.zig");
const signals = @import("signals.zig");

const url_utils = @import("url_utils.zig");
const hash_utils = @import("hash_utils.zig");
const download_parallel = @import("download_parallel.zig");
const download_sequential = @import("download_sequential.zig");

const HEADER_BUFFER_SIZE: usize = 16384;
const MAX_REDIRECTS: u8 = 5;

pub const extractFilenameFromUri = url_utils.extractFilenameFromUri;

pub fn runDownload(
    init: std.process.Init,
    config: cli.Config,
    allocator: std.mem.Allocator,
    raw_url: []const u8,
) !void {
    var out_file: ?std.Io.File = null;
    var final_file_path: ?[]const u8 = null;
    var downloaded_successfully = false;

    defer {
        signals.unregisterCleanupPath();
        if (out_file) |*file| {
            file.close(init.io);
        }
        if (!downloaded_successfully) {
            if (final_file_path) |path| {
                std.Io.Dir.cwd().deleteFile(init.io, path) catch {};
                if (!config.silent) {
                    std.debug.print("\n[CLEANUP] Download interrompido ou falhou. Arquivo '{s}' removido.\n", .{path});
                }
            }
        }
    }

    var current_url = raw_url;
    var redirect_count: u8 = 0;

    while (redirect_count <= MAX_REDIRECTS) : (redirect_count += 1) {
        const uri = std.Uri.parse(current_url) catch |err| {
            if (!config.silent) std.debug.print("\nErro de sintaxe na URI '{s}': {}\n", .{ current_url, err });
            return err;
        };

        if (!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) {
            if (!config.silent) std.debug.print("\nErro: Apenas esquemas HTTP e HTTPS são permitidos.\n", .{});
            std.process.exit(1);
        }

        if (config.output_path) |path| {
            final_file_path = path;
        } else if (config.use_remote_name) {
            final_file_path = try url_utils.extractFilenameFromUri(allocator, uri);
        }

        var existing_file_size: u64 = 0;
        if (config.to_resume and final_file_path != null) {
            if (std.Io.Dir.cwd().openFile(init.io, final_file_path.?, .{ .mode = .read_only }) catch null) |existing_file| {
                defer existing_file.close(init.io);
                if (existing_file.stat(init.io) catch null) |stat| {
                    existing_file_size = stat.size;
                }
            }
        }

        var client = std.http.Client{
            .allocator = allocator,
            .io = init.io,
        };
        defer client.deinit();

        var range_hdr_buf: [64]u8 = undefined;
        var extra_headers_buf: [3]std.http.Header = undefined;
        var extra_headers_count: usize = 0;

        extra_headers_buf[extra_headers_count] = .{ .name = "User-Agent", .value = "curl/8.0.0" };
        extra_headers_count += 1;

        extra_headers_buf[extra_headers_count] = .{ .name = "Accept-Encoding", .value = "identity" };
        extra_headers_count += 1;

        if (existing_file_size > 0) {
            const range_val = try std.fmt.bufPrint(&range_hdr_buf, "bytes={d}-", .{existing_file_size});
            extra_headers_buf[extra_headers_count] = .{ .name = "Range", .value = range_val };
            extra_headers_count += 1;
            if (!config.silent) std.debug.print("Retomando a partir do byte {d}...\n", .{existing_file_size});
        }

        var req = client.request(.GET, uri, .{
            .extra_headers = extra_headers_buf[0..extra_headers_count],
        }) catch |err| {
            if (!config.silent) std.debug.print("\nErro de conexão HTTP/TLS: {}\n", .{err});
            return err;
        };
        defer req.deinit();
        try req.sendBodiless();

        var headers_buf: [HEADER_BUFFER_SIZE]u8 = undefined;
        var response = try req.receiveHead(&headers_buf);
        const status_code = @intFromEnum(response.head.status);

        if (status_code >= 300 and status_code < 400) {
            if (config.follow_redirects) {
                if (response.head.location) |location| {
                    if (!config.silent) std.debug.print("Redirecionando para: {s}\n", .{location});
                    current_url = try allocator.dupeZ(u8, location);
                    continue;
                }
            }
            if (!config.silent) std.debug.print("\nErro HTTP {d}. Use -L para seguir redirecionamentos.\n", .{status_code});
            std.process.exit(1);
        }

        if (status_code >= 400) {
            if (!config.silent) std.debug.print("\nErro HTTP {d}: {s}\n", .{ status_code, response.head.status.phrase() orelse "Desconhecido" });
            std.process.exit(1);
        }

        const is_partial_content = (status_code == 206);

        if (final_file_path) |path| {
            if (is_partial_content) {
                out_file = std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = false }) catch |err| {
                    if (!config.silent) std.debug.print("Erro ao abrir arquivo para retoma '{s}': {}\n", .{ path, err });
                    return err;
                };
            } else {
                out_file = std.Io.Dir.cwd().createFile(init.io, path, .{ .truncate = true }) catch |err| {
                    if (!config.silent) std.debug.print("Erro ao criar arquivo '{s}': {}\n", .{ path, err });
                    return err;
                };
                existing_file_size = 0;
            }
            signals.registerCleanupPath(path);
        }

        sandbox.applyLandlockSandbox();

        var total_expected_size: ?u64 = null;
        if (response.head.content_length) |len| {
            if (is_partial_content) {
                total_expected_size = std.math.add(u64, len, existing_file_size) catch {
                    if (!config.silent) std.debug.print("\n[ERRO DE SEGURANÇA] Overflow no Content-Length.\n", .{});
                    return error.FileTooLarge;
                };
            } else {
                total_expected_size = len;
            }
            if (total_expected_size.? > config.max_filesize_bytes) {
                if (!config.silent) std.debug.print("\n[ERRO DE SEGURANÇA] Arquivo excede o limite máximo configurado.\n", .{});
                return error.FileTooLarge;
            }
        }

        const accepts_ranges = is_partial_content or url_utils.checkAcceptsRanges(&response.head);

        const can_parallelize = (config.jobs > 1) and
            (out_file != null) and
            (total_expected_size != null) and
            (total_expected_size.? > 0) and
            (existing_file_size == 0) and
            accepts_ranges;

        var parallel_failed = false;

        if (can_parallelize) {
            download_parallel.execute(
                init,
                config,
                allocator,
                uri,
                out_file.?,
                config.jobs,
                total_expected_size.?,
            ) catch |err| {
                parallel_failed = true;
                if (!config.silent) {
                    std.debug.print("\n[FALLBACK INTELIGENTE] Download paralelo falhou ({}). Revertendo para single-thread...\n", .{err});
                }
            };
        }

        // EXECUÇÃO SEQUENCIAL (Ou Fallback após falha do modo paralelo)
        if (!can_parallelize or parallel_failed) {
            if (parallel_failed and out_file != null) {
                // Trunca o arquivo para recomeçar o download em modo seguro
                try out_file.?.setLength(init.io, 0);
            }

            try download_sequential.execute(
                init,
                config,
                &response,
                out_file,
                if (parallel_failed) 0 else existing_file_size,
                total_expected_size,
                accepts_ranges,
            );
        }

        // --- VERIFICAÇÃO DE HASH SHA-256 ---
        if (config.expected_sha256) |expected_hash| {
            if (out_file) |file| {
                if (!config.silent) std.debug.print("Verificando Hash SHA-256...\n", .{});
                const hash_matches = try hash_utils.verifyFileSha256(init, file, expected_hash);
                if (!hash_matches) {
                    if (!config.silent) std.debug.print("\n[ERRO DE INTEGRIDADE] O hash SHA-256 calculado não corresponde ao esperado!\n", .{});
                    return error.HashMismatch;
                }
                if (!config.silent) std.debug.print("Integridade verificada com sucesso (SHA-256 ok).\n", .{});
            }
        }

        downloaded_successfully = true;
        signals.unregisterCleanupPath();
        return;
    }

    if (!config.silent) std.debug.print("Erro: Número máximo de redirecionamentos ({d}) excedido.\n", .{MAX_REDIRECTS});
    std.process.exit(1);
}
