const std = @import("std");
const Io = std.Io;
const net = Io.net;

const N_CLIENTS = 8;
const K_REQS = 25;
const EXPECTED = N_CLIENTS * K_REQS;
const SAMPLES = 50;

var g_failures: usize = 0;

fn check(cond: bool, comptime fmt: []const u8, args: anytype) void {
    if (cond) return;
    std.debug.print("  FAIL: " ++ fmt ++ "\n", args);
    g_failures += 1;
}

const Response = struct { status: u16 };

fn doGet(io: Io, port: u16, path: []const u8, out: []u8) !Response {
    var addr = try net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    defer {
        var c = stream;
        c.close(io);
    }
    var wbuf: [256]u8 = undefined;
    var rbuf: [65536]u8 = undefined;
    var connection_writer = stream.writer(io, &wbuf);
    var connection_reader = stream.reader(io, &rbuf);
    const wr = &connection_writer.interface;
    try wr.print("GET {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{path});
    try wr.flush();

    var buf: [65536]u8 = undefined;
    var got: usize = 0;
    var header_end: ?usize = null;
    while (header_end == null) {
        if (got >= buf.len) return error.ResponseTooLarge;
        var data: [1][]u8 = .{buf[got..]};
        const n = try connection_reader.stream.read(io, &data);
        if (n == 0) return error.UnexpectedEof;
        got += n;
        if (std.mem.indexOfPos(u8, buf[0..got], 0, "\r\n\r\n")) |idx| header_end = idx;
    }
    const he = header_end.?;
    const header_block = buf[0..he];

    var status: u16 = 0;
    var content_length: usize = 0;
    var it = std.mem.splitScalar(u8, header_block, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, "\r");
        if (status == 0 and std.mem.startsWith(u8, line, "HTTP/1.1 ")) {
            const after = line["HTTP/1.1 ".len..];
            const sp = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
            status = try std.fmt.parseInt(u16, after[0..sp], 10);
        } else if (std.mem.indexOf(u8, line, "content-length:")) |ci| {
            const v = std.mem.trim(u8, line[ci + "content-length:".len ..], " \t");
            content_length = try std.fmt.parseInt(usize, v, 10);
        }
    }

    const total = he + 4 + content_length;
    while (got < total) {
        if (got >= buf.len) return error.ResponseTooLarge;
        var data: [1][]u8 = .{buf[got..]};
        const n = try connection_reader.stream.read(io, &data);
        if (n == 0) return error.UnexpectedEof;
        got += n;
    }
    if (out.len < total) return error.OutBufTooSmall;
    @memcpy(out[0..total], buf[0..total]);
    return .{ .status = status };
}

/// Parse the counter integer from the `/counter` response.
/// Contains: `<span class="n">N</span>`
fn parseCounter(resp: []const u8) ?usize {
    const marker = "<span class=\"n\">";
    const idx = std.mem.indexOf(u8, resp, marker) orelse return null;
    const rest = resp[idx + marker.len ..];
    var val: usize = 0;
    var i: usize = 0;
    while (i < rest.len and rest[i] >= '0' and rest[i] <= '9') : (i += 1) {
        val = val * 10 + (rest[i] - '0');
    }
    if (i == 0) return null;
    return val;
}

fn fetchCounter(io: Io, port: u16, out: []u8) !usize {
    const r = try doGet(io, port, "/counter", out);
    if (r.status != 200) return error.BadStatus;
    return parseCounter(out) orelse error.BadCounterBody;
}

fn connectOnce(io: Io, port: u16) !void {
    var addr = try net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    var c = stream;
    c.close(io);
}

fn waitReady(io: Io, port: u16, milliseconds: i96) !void {
    const deadline_ns = std.Io.Timestamp.now(io, .awake).nanoseconds + @as(i96, milliseconds) * std.time.ns_per_ms;
    while (true) {
        if (connectOnce(io, port)) |_| return else |_| {}
        const now_ns = std.Io.Timestamp.now(io, .awake).nanoseconds;
        if (now_ns >= deadline_ns) return error.ServerNotReady;
        io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
}

// A single client task: performs K_REQS GET / requests, counting 200 responses.
fn clientTask(io: Io, port: u16, slot: *u32) void {
    var ok: u32 = 0;
    var out: [65536]u8 = undefined;
    for (0..K_REQS) |_| {
        if (doGet(io, port, "/", &out)) |r| {
            if (r.status == 200) ok += 1;
        } else |_| {}
    }
    slot.* = ok;
}

const SampleResult = struct {
    monotonic_ok: bool = true,
    max_seen: usize = 0,
};

// Samples /counter repeatedly, recording whether the value ever decreases.
fn samplerTask(io: Io, port: u16, sres: *SampleResult) void {
    var out: [65536]u8 = undefined;
    var prev: ?usize = null;
    for (0..SAMPLES) |_| {
        if (doGet(io, port, "/counter", &out)) |r| {
            if (r.status == 200) {
                if (parseCounter(&out)) |val| {
                    if (val > sres.max_seen) sres.max_seen = val;
                    if (prev) |p| {
                        if (val < p) sres.monotonic_ok = false;
                    }
                    prev = val;
                }
            }
        } else |_| {}
        io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake) catch {};
    }
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: tmphttp_test <path-to-tmphttp-binary>\n", .{});
        return error.Usage;
    }
    const bin_path = args[1];

    // Pick an ephemeral port by binding to port 0 then releasing it.
    const port = blk: {
        const address = try net.IpAddress.parse("127.0.0.1", 0);
        var srv = try address.listen(io, .{ .reuse_address = true });
        defer srv.deinit(io);
        break :blk srv.socket.address.getPort();
    };
    std.debug.print("Using port {d}, binary {s}\n", .{ port, bin_path });

    // Spawn the tmphttp server as a subprocess.
    var port_buf: [8]u8 = undefined;
    const port_str = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    const argv = [_][]const u8{ bin_path, "--no-tui", "-p", port_str };
    var child = try std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer child.kill(io);

    // Readiness: wait for the listener to accept.
    try waitReady(io, port, 5000);

    // Basic routes return 200 before exercising concurrency.
    var out: [65536]u8 = undefined;
    {
        check((try doGet(io, port, "/", &out)).status == 200, "GET / -> 200", .{});
        check((try doGet(io, port, "/htmx.min.js", &out)).status == 200, "GET /htmx.min.js -> 200", .{});
    }
    // The basic `GET /` above increments the counter exactly once; record the
    // baseline so the final assertion accounts for it.
    const baseline = try fetchCounter(io, port, &out);

    // Concurrent load: N clients * K requests each, plus a sampler observing
    // that the counter never decreases while the load is in flight.
    var successes: [N_CLIENTS]u32 = undefined;
    for (&successes) |*s| s.* = 0;
    var group: Io.Group = .init;
    for (0..N_CLIENTS) |i| {
        try group.concurrent(io, clientTask, .{ io, port, &successes[i] });
    }
    var sres: SampleResult = .{};
    var sampler_fut = try io.concurrent(samplerTask, .{ io, port, &sres });

    try group.await(io);
    _ = sampler_fut.await(io);

    var total_successes: u32 = 0;
    for (&successes) |s| total_successes += s;
    check(total_successes == EXPECTED, "all requests delivered: {d} == {d}", .{ total_successes, EXPECTED });
    check(sres.monotonic_ok, "counter monotonic non-decreasing during load", .{});

    // Final counter equals the baseline (from the basic `GET /`) plus the
    // successful 200 responses from the concurrent load, and is at least the
    // maximum observed during sampling.
    const expected_final = baseline + @as(usize, total_successes);
    const final_count = try fetchCounter(io, port, &out);
    check(final_count == expected_final, "final counter exact: {d} == {d}", .{ final_count, expected_final });
    check(final_count >= sres.max_seen, "final counter reaches sampled max: {d} >= {d}", .{ final_count, sres.max_seen });

    // /counter self-polls must not increment the count.
    const c1 = try fetchCounter(io, port, &out);
    const c2 = try fetchCounter(io, port, &out);
    check(c1 == c2, "counter self-polls don't increment: {d} == {d}", .{ c1, c2 });

    if (g_failures == 0) {
        std.debug.print("tmphttp test PASS\n", .{});
    } else {
        std.debug.print("tmphttp test FAIL ({d} failures)\n", .{g_failures});
        return error.TestFailed;
    }
}
