const std = @import("std");
const mem = std.mem;

/// Pure: extract a package name from a Nix store path like
/// "/nix/store/<hash>-<package-name>". Returns null if the path
/// is not a Nix store path or can't be parsed.
fn extractPackage(path: []const u8) ?[]const u8 {
    const prefix = "/nix/store/";
    const rest = if (mem.startsWith(u8, path, prefix)) path[prefix.len..] else return null;
    const dash = mem.indexOfScalar(u8, rest, '-') orelse return null;
    return stripVersion(rest[dash + 1 ..]);
}

/// Pure: strip version suffixes from a package name.
/// Stops at "-<digit>" or "-dev".
fn stripVersion(name: []const u8) []const u8 {
    for (name, 0..) |c, i| {
        if (c == '-' and i + 1 < name.len) {
            const next = name[i + 1];
            if (next >= '0' and next <= '9') return name[0..i];
            if (mem.startsWith(u8, name[i + 1 ..], "dev")) return name[0..i];
        }
    }
    return name;
}

pub fn main(init: std.process.Init) !void {
    const build_inputs = init.environ_map.get("buildInputs") orelse return;

    var iter = mem.splitScalar(u8, build_inputs, ' ');
    var packages: [5][]const u8 = undefined;
    var count: usize = 0;

    while (iter.next()) |path| {
        if (path.len == 0) continue;
        if (extractPackage(path)) |pkg| {
            packages[count] = pkg;
            count += 1;
            if (count >= 5) break;
        }
    }

    if (count > 0) {
        var buf: [1024]u8 = undefined;
        var pos: usize = 0;
        for (packages[0..count], 0..) |pkg, i| {
            if (i > 0) { buf[pos] = ':'; pos += 1; }
            @memcpy(buf[pos..][0..pkg.len], pkg);
            pos += pkg.len;
        }
        buf[pos] = '\n';
        pos += 1;
        try std.Io.File.stdout().writeStreamingAll(init.io, buf[0..pos]);
    }
}
