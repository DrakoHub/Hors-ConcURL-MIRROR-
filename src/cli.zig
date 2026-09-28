const std = @import("std");

pub const MAX_URL_LEN: usize = 2048;

pub const Config = struct {
    url: ?[:0]const u8 = null,
    output_path: ?[:0]const u8 = null,
    use_remote_name: bool = false,
    follow_redirects: bool = false,
    to_resume: bool = false,
    jobs: usize = 0,
    max_filesize_bytes: u64 = 10 * 1024 * 1024 * 1024, // 10 GB
    expected_sha256: ?[]const u8 = null,
    limit_rate_bytes_per_sec: u64 = 0, // 0 = sem limite
    silent: bool = false,
    show_help: bool = false,
};

pub fn printHelp() void {
    const help_text =
        \\Hors concurl - Downloader HTTP/HTTPS concorrente em Zig
        \\
        \\Uso:
        \\  concurl [opções] <URL>
        \\
        \\Opções:
        \\  -h, --help               Exibe esta mensagem de ajuda e sai.
        \\  -s, --silent             Modo silencioso (oculta barra de progresso e mensagens).
        \\  -O                       Usa o nome do arquivo remoto extraído da URL.
        \\  -o <arquivo>             Especifica o nome/caminho do arquivo de saída.
        \\  -L                       Segue redirecionamentos HTTP (3xx).
        \\  -c, --continue           Retoma um download parcialmente concluído.
        \\  -j, --jobs <n>           Número de conexões/threads paralelas (padrão: auto-detectado).
        \\  --sha256 <hash>          Verifica a integridade do arquivo baixado via hash SHA-256.
        \\  --limit-rate <taxa>      Limita a velocidade de download (ex: 500k, 2M, 1000000).
        \\
    ;
    std.debug.print("{s}", .{help_text});
}

fn parseRate(rate_str: []const u8) !u64 {
    if (rate_str.len == 0) return error.InvalidRate;

    const last_char = std.ascii.toLower(rate_str[rate_str.len - 1]);
    var multiplier: u64 = 1;
    var num_slice = rate_str;

    if (last_char == 'k') {
        multiplier = 1024;
        num_slice = rate_str[0 .. rate_str.len - 1];
    } else if (last_char == 'm') {
        multiplier = 1024 * 1024;
        num_slice = rate_str[0 .. rate_str.len - 1];
    } else if (last_char == 'g') {
        multiplier = 1024 * 1024 * 1024;
        num_slice = rate_str[0 .. rate_str.len - 1];
    }

    const base_val = try std.fmt.parseInt(u64, num_slice, 10);
    return base_val * multiplier;
}

pub fn parseArgs(init: *const std.process.Init) Config {
    var config = Config{};
    var user_specified_jobs = false;
    var args = init.minimal.args.iterate();
    _ = args.next(); // Pula executável

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            config.show_help = true;
            return config;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "--silent")) {
            config.silent = true;
        } else if (std.mem.eql(u8, arg, "-L")) {
            config.follow_redirects = true;
        } else if (std.mem.eql(u8, arg, "-O")) {
            config.use_remote_name = true;
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--continue")) {
            config.to_resume = true;
        } else if (std.mem.eql(u8, arg, "-o")) {
            config.output_path = args.next() orelse {
                std.debug.print("Erro: Flag -o requer um caminho de arquivo.\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--jobs")) {
            const jobs_arg = args.next() orelse {
                std.debug.print("Erro: Flag -j requer o número de conexões.\n", .{});
                std.process.exit(1);
            };
            config.jobs = std.fmt.parseInt(usize, jobs_arg, 10) catch {
                std.debug.print("Erro: Número de conexões inválido '{s}'.\n", .{jobs_arg});
                std.process.exit(1);
            };
            user_specified_jobs = true;
        } else if (std.mem.eql(u8, arg, "--sha256")) {
            const hash_arg = args.next() orelse {
                std.debug.print("Erro: Flag --sha256 requer o hash hexadecimal de 64 caracteres.\n", .{});
                std.process.exit(1);
            };
            if (hash_arg.len != 64) {
                std.debug.print("Erro: Hash SHA-256 deve possuir exatamente 64 caracteres hexadecimais.\n", .{});
                std.process.exit(1);
            }
            config.expected_sha256 = hash_arg;
        } else if (std.mem.eql(u8, arg, "--limit-rate")) {
            const rate_arg = args.next() orelse {
                std.debug.print("Erro: Flag --limit-rate requer o limite de velocidade (ex: 1M, 500k).\n", .{});
                std.process.exit(1);
            };
            config.limit_rate_bytes_per_sec = parseRate(rate_arg) catch {
                std.debug.print("Erro: Formato de velocidade inválido '{s}'. Use valores como 500k ou 2M.\n", .{rate_arg});
                std.process.exit(1);
            };
        } else if (arg.len > 0 and arg[0] == '-') {
            std.debug.print("Erro: Opção desconhecida '{s}'. Use -h para ajuda.\n", .{arg});
            std.process.exit(1);
        } else {
            config.url = arg;
        }
    }

    if (!user_specified_jobs) {
        const cpu_count = std.Thread.getCpuCount() catch 1;
        config.jobs = @min(@max(cpu_count, 1), 8);
    }

    return config;
}
