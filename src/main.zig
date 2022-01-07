const std = @import("std");

const curl = @cImport({
    @cInclude("curl/curl.h");
});

pub fn main() anyerror!void {
    const url = "http://example.com/path/index.html";
    const h = curl.curl_url();
    std.log.debug("{any}", .{h});

    const uc = curl.curl_url_set(h, curl.CURLUPART_URL, url, 0);
    std.log.debug("{any}", .{uc});
}

test "basic test" {
    try std.testing.expectEqual(10, 3 + 7);
}
