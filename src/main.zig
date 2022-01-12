const std = @import("std");

const curl = @cImport({
    @cInclude("curl/curl.h");
});

pub fn main() anyerror!void {
    var host: ?[*:0]u8 = null;

    const url = "http://example.com/path/index.html";
    const h = curl.curl_url();
    std.log.debug("curl handle: {any}", .{h});

    var uc = curl.curl_url_set(h, curl.CURLUPART_URL, url, 0);
    std.log.debug("uc: {any}", .{uc});

    uc = curl.curl_url_get(h, curl.CURLUPART_HOST, &host, 1);
    std.log.debug("host ({any}): {s}", .{ uc, host });
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
