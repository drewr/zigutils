const std = @import("std");

const curl = @cImport({
    @cInclude("curl/curl.h");
});

pub fn main() anyerror!void {
    var alloc_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const alloc = fba.allocator();

    const h = curl.curl_url();

    var arg_iter = std.process.args();
    while (try arg_iter.next(alloc)) |url| {
        var host: ?[*:0]u8 = null;
        var path: ?[*:0]u8 = null;

        var uc = curl.curl_url_set(h, curl.CURLUPART_URL, url, 0);
        if (uc == 0) {
            _ = curl.curl_url_get(h, curl.CURLUPART_HOST, &host, 1);
            _ = curl.curl_url_get(h, curl.CURLUPART_PATH, &path, 1);
            const arr = split_path(std.mem.span(path.?));
            std.log.info("{s} / {s}", .{ arr[0], arr[1] });
        }
        alloc.free(url);
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}

fn split_path(path: []const u8) [2][]const u8 {
    var it = std.mem.split(u8, path, "/");
    _ = it.next().?; // emptiness before the slash
    const user = it.next().?;
    const repo = it.next().?;
    // sourcehut uses tildes like unix homedirs, gotta strip that
    return .{ if (user[0] == '~') user[1..] else user, repo };
}
