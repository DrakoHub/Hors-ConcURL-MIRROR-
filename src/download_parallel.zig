const std = @import("std");
const cli = @import("cli.zig");
const ui = @import("ui.zig");

const HEADER_BUFFER_SIZE: usize = 16384;
const READ_BUFFER_SIZE: usize = 128 * 1024;
const MAX_CHUNK_RETRIES: usize = 3;

pub const ChunkTask = struct {
    init: std.process.Init,
    uri: std.Uri,
    out_file: std.Io.File,
    start_byte: u64,
    end_byte: u64,
    allocator: std.mem.Allocator,
    atomic_total_read: *std.atomic.Value(u64),
    failed: *std.atomic.Value(bool),
    active_workers: *std.atomic.Value(usize),
    silent: bool,
};

fn downloadChunkWorker(task: ChunkTask) void {
    defer _ = task.active_workers.fetchSub(1, .release);

    var retry_count: usize = 0;
    while (retry_count < MAX_CHUNK_RETRIES) : (retry_count += 1) {
        if (task.failed.load(.acquire)) return;

        downloadChunkWorkerInternal(task) catch |err| {
            if (task.failed.load(.acquire)) return;

            if (retry_count + 1 < MAX_CHUNK_RETRIES) {
                // Exponential Backoff: 500ms, 1000ms, 2000ms...
                const backoff_ms = @as(u64, 500) * (@as(u64, 1) << @intCast(retry_count));
                std.Io.sleep(task.init.io, .fromMilliseconds(@intCast(backoff_ms)), .awake) catch return;
                continue;
            } else {
                if (!task.silent) {
                    std.debug.print("\n[ERRO CHUNK {d}-{d}] Falhou após {d} tentativas: {}\n", .{ task.start_byte, task.end_byte, MAX_CHUNK_RETRIES, err });
                }
                task.failed.store(true, .release);
                return;
            }
        };

        return; // Sucesso na transferência do Chunk
    }
}

fn downloadChunkWorkerInternal(task: ChunkTask) !void {
    var client = std.http.Client{
        .allocator = task.allocator,
        .io = task.init.io,
    };
    defer client.deinit();

    var range_hdr_buf: [64]u8 = undefined;
    const range_val = try std.fmt.bufPrint(&range_hdr_buf, "bytes={d}-{d}", .{ task.start_byte, task.end_byte });

    const extra_headers = [_]std.http.Header{
        .{ .name = "User-Agent", .value = "curl/8.0.0" },
        .{ .name = "Accept-Encoding", .value = "identity" },
        .{ .name = "Range", .value = range_val },
    };

    var req = try client.request(.GET, task.uri, .{
        .extra_headers = &extra_headers,
    });
    defer req.deinit();
    try req.sendBodiless();

    var headers_buf: [HEADER_BUFFER_SIZE]u8 = undefined;
    var response = try req.receiveHead(&headers_buf);

    const status_code = @intFromEnum(response.head.status);
    if (status_code != 206 and status_code != 200) {
        return error.InvalidServerStatus;
    }

    var transfer_buf: [READ_BUFFER_SIZE]u8 = undefined;
    var read_buf: [READ_BUFFER_SIZE]u8 = undefined;
    var body_reader = response.reader(&transfer_buf);

    var current_offset = task.start_byte;

    while (current_offset <= task.end_byte) {
        if (task.failed.load(.acquire)) return error.Aborted;

        const bytes_read = try body_reader.readSliceShort(&read_buf);
        if (bytes_read == 0) break;

        const remaining = task.end_byte + 1 - current_offset;
        const to_write: usize = @intCast(@min(@as(u64, bytes_read), remaining));

        try task.out_file.writePositionalAll(task.init.io, read_buf[0..to_write], current_offset);
        current_offset += to_write;

        _ = task.atomic_total_read.fetchAdd(to_write, .monotonic);
    }
}

pub fn execute(
    init: std.process.Init,
    config: cli.Config,
    allocator: std.mem.Allocator,
    uri: std.Uri,
    out_file: std.Io.File,
    jobs: usize,
    total_bytes: u64,
) !void {
    if (!config.silent) {
        std.debug.print("Modo de Download: Paralelo ({d} threads)\n", .{jobs});
    }

    const chunk_size = total_bytes / jobs;
    try out_file.setLength(init.io, total_bytes);

    var atomic_progress = std.atomic.Value(u64).init(0);
    var failed_flag = std.atomic.Value(bool).init(false);
    var active_workers = std.atomic.Value(usize).init(jobs);

    var threads = try allocator.alloc(std.Thread, jobs);
    defer allocator.free(threads);

    const start_time = std.Io.Clock.awake.now(init.io);

    for (0..jobs) |i| {
        const start_b = i * chunk_size;
        const end_b = if (i == jobs - 1) total_bytes - 1 else (start_b + chunk_size - 1);

        threads[i] = try std.Thread.spawn(.{}, downloadChunkWorker, .{ChunkTask{
            .init = init,
            .uri = uri,
            .out_file = out_file,
            .start_byte = start_b,
            .end_byte = end_b,
            .allocator = allocator,
            .atomic_total_read = &atomic_progress,
            .failed = &failed_flag,
            .active_workers = &active_workers,
            .silent = config.silent,
        }});
    }

    while (true) {
        const current_read = atomic_progress.load(.monotonic);
        const elapsed_ms = start_time.untilNow(init.io, .awake).toMilliseconds();

        ui.renderProgressBar(current_read, total_bytes, elapsed_ms, config.silent);
        const workers_remaining = active_workers.load(.acquire);
        if (current_read >= total_bytes or failed_flag.load(.acquire) or workers_remaining == 0) break;

        try std.Io.sleep(init.io, .fromMilliseconds(50), .awake);
    }

    for (threads) |t| {
        t.join();
    }

    if (failed_flag.load(.acquire)) {
        if (!config.silent) {
            std.debug.print("\nErro: Ocorreu uma falha permanente em uma das threads do download paralelo.\n", .{});
        }
        return error.ParallelDownloadFailed;
    }

    ui.finishProgressBar(config.silent);
    if (!config.silent) {
        var total_buf: [32]u8 = undefined;
        const formatted_total = ui.formatBytes(total_bytes, &total_buf);
        std.debug.print("Concluído: {s} ({d} bytes).\n", .{ formatted_total, total_bytes });
    }
}
