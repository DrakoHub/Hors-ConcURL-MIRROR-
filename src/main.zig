const std = @import("std");
const cli = @import("cli.zig");
const downloader = @import("downloader.zig");
const signals = @import("signals.zig");

pub fn main(init: std.process.Init) !void {
    try signals.initSignalHandlers();

    const config = cli.parseArgs(&init);
    if (config.show_help) {
        cli.printHelp();
        std.process.exit(0);
    }    
    const raw_url = config.url orelse {
        cli.printHelp();
        std.process.exit(1);
    };

    if (raw_url.len > cli.MAX_URL_LEN) {
        if (!config.silent) std.debug.print("Erro: URL excede o limite máximo ({d} bytes).\n", .{cli.MAX_URL_LEN});
        std.process.exit(1);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try downloader.runDownload(init, config, allocator, raw_url);
    std.process.exit(0);
}
