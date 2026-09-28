const std = @import("std");

/// Extrai o nome do ficheiro a partir da URI, e fazendo uma limpeza
pub fn extractFilenameFromUri(allocator: std.mem.Allocator, uri: std.Uri) ![]const u8 {
    const raw_path = uri.path.percent_encoded;

    var raw_filename: []const u8 = "index.html";
    if (raw_path.len > 0) {
        if (std.mem.lastIndexOfScalar(u8, raw_path, '/')) |idx| {
            if (idx + 1 < raw_path.len) {
                raw_filename = raw_path[idx + 1 ..];
            }
        } else {
            raw_filename = raw_path;
        }
    }

    raw_filename = std.mem.trim(u8, raw_filename, ". ");

    // Se após o trim ficar vazio ou tentar subir diretório
    if (raw_filename.len == 0 or std.mem.eql(u8, raw_filename, "..")) {
        return try allocator.dupe(u8, "index.html");
    }

    // Buffer temporário para construir o nome sanitizado na stack
    var sanitized_buf: [256]u8 = undefined;
    var sanitized_len: usize = 0;

    for (raw_filename) |char| {
        if (sanitized_len >= sanitized_buf.len) break;

        // Filtra caracteres de controle, barras e caracteres proibidos
        switch (char) {
            '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0...31 => continue,
            else => {
                sanitized_buf[sanitized_len] = char;
                sanitized_len += 1;
            },
        }
    }

    //Cria o slice final a partir do que foi sanitizado
    var result_slice: []const u8 = sanitized_buf[0..sanitized_len];

    // Segunda validação caso a sanitização tenha deixado a string vazia ou perigosa novamente
    result_slice = std.mem.trim(u8, result_slice, ". ");
    if (result_slice.len == 0 or std.mem.eql(u8, result_slice, "..")) {
        return try allocator.dupe(u8, "index.html");
    }

    return try allocator.dupe(u8, result_slice);
}



/// Inspeciona os cabeçalhos HTTP recebidos para verificar se o servidor suporta "Accept-Ranges: bytes".
pub fn checkAcceptsRanges(response_head: anytype) bool {
    var header_it = response_head.iterateHeaders();
    while (header_it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "Accept-Ranges")) {
            if (std.ascii.eqlIgnoreCase(header.value, "bytes")) {
                return true;
            }
        }
    }
    return false;
}
