const std = @import("std");
const Allocator = std.mem.Allocator;
const curl = @cImport({
    @cInclude("curl/curl.h");
});

const Repo = struct {
    user: []const u8 = undefined,
    name: []const u8 = undefined,
};

pub fn main() anyerror!void {
    var alloc_buf: [1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&alloc_buf);
    const alloc = fba.allocator();

    const h = curl.curl_url();

    var arg_iter = std.process.args();
    while (try arg_iter.next(alloc)) |url| {
        const repo = parseUrl(alloc, h, url);
        if (repo == null) {
            //not sure why this prints \252\252\252...
            //std.log.warn("can't parse: {s}", .{url});
            continue;
        } else {
            std.log.debug("{s} {s}", .{ repo.?.user, repo.?.name });
        }
    }
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}

fn makeRepo(path: []const u8) Repo {
    var it = std.mem.split(u8, path, "/");
    _ = it.next().?; // emptiness before the slash
    const user = it.next().?;
    const repo = it.next().?;
    // sourcehut uses tildes like unix homedirs, gotta strip that
    return Repo{ .user = if (user[0] == '~') user[1..] else user, .name = repo };
}

fn parseUrl(alloc: Allocator, h: ?*curl.struct_Curl_URL, url: [:0]const u8) ?*Repo {
    var host: ?[*:0]u8 = null;
    var path: ?[*:0]u8 = null;
    var repo: Repo = Repo{};

    var uc = curl.curl_url_set(h, curl.CURLUPART_URL, url, 0);
    defer alloc.free(url);

    if (uc == 0) {
        _ = curl.curl_url_get(h, curl.CURLUPART_HOST, &host, 1);
        _ = curl.curl_url_get(h, curl.CURLUPART_PATH, &path, 1);
        repo = makeRepo(
        // the span() converts the slice to a []const u8
        std.mem.span(path.?));
        return &repo;
    } else {
        return null;
    }
}
