const std = @import("std");
const mem = std.mem;
const fs = std.fs;
const process = std.process;
const Io = std.Io;
const net = Io.net;
const posix = std.posix;

var g_stop = std.atomic.Value(bool).init(false);

const Allocator = std.mem.Allocator;

fn onSigint(_: posix.SIG) callconv(.c) void {
    g_stop.store(true, .seq_cst);
}

const DEFAULT_CONTENT =
    \\<!doctype html>
    \\<html lang="en">
    \\<head><meta charset="utf-8"><title>tmphttp</title>
    \\<script src="/htmx.min.js"></script>
    \\<style>body{font-family:system-ui,sans-serif;margin:4rem auto;max-width:36rem;padding:0 1rem;color:#222}
    \\h1{font-size:1.8rem}code{background:#f4f4f5;padding:.15rem .4rem;border-radius:4px}
    \\.stats{background:#f8f8fa;border:1px solid #e4e4e7;border-radius:8px;padding:1rem;margin:1rem 0;line-height:1.9}
     \\.row{display:block}
     \\.n,.ip,.t,.dir{font-weight:600;font-variant-numeric:tabular-nums}
     \\.dir{font-family:monospace;word-break:break-all}</style>
    \\</head>
    \\<body>
    \\<h1>tmphttp</h1>
    \\<div id="stats" class="stats"
    \\     hx-get="/counter" hx-trigger="load, every 1s" hx-swap="innerHTML">
     \\  <span class="row">Requests: <span class="n">0</span></span>
     \\  <span class="row">Your IP: <span class="ip">&hellip;</span></span>
     \\  <span class="row">Server time (UTC): <span class="t">&hellip;</span></span>
     \\  <span class="row">Port: <span class="port">&hellip;</span></span>
    \\</div>
    \\<p><small>Auto-refreshes every second.</small></p>
    \\</body></html>
;

/// Vendored htmx (v1.9.12, MIT) so tmphttp is fully self-contained.
const htmx_js: []const u8 = @embedFile("htmx.min.js");

const Log = struct {
    const Cap = 300;
    const MaxLine = 256;

    mutex: Io.Mutex = .init,
    buf: []LogLine,
    head: usize = 0,
    len: usize = 0,

    const LogLine = struct {
        len: usize = 0,
        bytes: [MaxLine]u8 = undefined,
    };

    fn init(allocator: Allocator) !Log {
        return .{ .buf = try allocator.alloc(LogLine, Cap) };
    }

    fn deinit(self: *Log, allocator: Allocator) void {
        allocator.free(self.buf);
    }

    fn append(self: *Log, io: Io, line: []const u8) void {
        self.mutex.lock(io) catch return;
        defer self.mutex.unlock(io);
        const n = @min(line.len, MaxLine);
        const slot = &self.buf[self.head];
        slot.len = n;
        @memcpy(slot.bytes[0..n], line[0..n]);
        self.head = (self.head + 1) % Cap;
        if (self.len < Cap) self.len += 1;
    }

    fn appendFmt(self: *Log, io: Io, comptime fmt: []const u8, args: anytype) void {
        var buf: [MaxLine]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.append(io, line);
    }

    fn get(self: *Log, index: usize) []const u8 {
        const start = (self.head + Cap - self.len) % Cap;
        const slot = &self.buf[(start + index) % Cap];
        return slot.bytes[0..slot.len];
    }
};

const Config = struct {
    host: []const u8,
    port: u16,
    content: []const u8,
    /// When set, serve this existing directory from disk instead of the default
    /// in-memory index.html page.
    dir: ?[]const u8 = null,
};

const State = struct {
    io: Io,
    gpa: Allocator,
    cfg: Config,
    /// The directory being served from disk, when `-d/--dir` is used.
    serve_dir: ?Io.Dir = null,
    /// Absolute path of the served directory (only when `serve_dir` is set).
    serve_path: ?[]const u8 = null,
    log: Log,
    requests: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    tmux: bool,
    environ: *std.process.Environ.Map,
    start: std.Io.Timestamp,
    rows: u16 = 24,
    cols: u16 = 80,
};

/// Format the current UTC wall-clock time as "YYYY-MM-DDTHH:MM:SSZ".
fn formatUtc(state: *const State, out: []u8) []const u8 {
    const wall = std.Io.Timestamp.now(state.io, .real);
    const epoch_secs: u64 = @intCast(@divTrunc(wall.nanoseconds, std.time.ns_per_s));
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const ymd = epoch.getEpochDay().calculateYearDay();
    const mon_day = ymd.calculateMonthDay();
    const tod = epoch.getDaySeconds();
    return std.fmt.bufPrint(out,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
        .{
            ymd.year,
            mon_day.month.numeric(),
            mon_day.day_index + 1,
            tod.getHoursIntoDay(),
            tod.getMinutesIntoHour(),
            tod.getSecondsIntoMinute(),
        },
    ) catch "????-??-??T??:??:??Z";
}

/// Format a UTC timestamp (YYYY-MM-DDTHH:MM:SSZ) followed by the elapsed time
/// since server start (MM:SS), as "[<utc> <mm:ss>]".
fn fmtElapsed(state: *const State, out: []u8) []const u8 {
    const awake = std.Io.Timestamp.now(state.io, .awake);
    const elapsed_s: i96 = @divTrunc(awake.nanoseconds - state.start.nanoseconds, std.time.ns_per_s);

    var wall_buf: [32]u8 = undefined;
    const wall = formatUtc(state, &wall_buf);

    var dur: [8]u8 = undefined;
    const duration = fmtElapsedTime(elapsed_s, &dur);

    return std.fmt.bufPrint(out, "[{s} {s}]", .{ wall, duration }) catch "[??-??-??T??:??:??Z ??]";
}

/// Format elapsed seconds as zero-padded MM:SS (e.g. "05", "63" for > 1 min).
fn fmtElapsedTime(seconds: i96, out: []u8) []const u8 {
    const t = @max(seconds, 0);
    const mm: u64 = @intCast(@divTrunc(t, 60));
    const ss: u64 = @intCast(@rem(t, 60));
    return std.fmt.bufPrint(out, "{d:0>2}:{d:0>2}", .{ mm, ss }) catch "00:00";
}

/// Format the source (peer) IP of a connection into `out`.
fn formatIp(addr: net.IpAddress, out: []u8) []const u8 {
    return switch (addr) {
        .ip4 => |a| std.fmt.bufPrint(out, "{d}.{d}.{d}.{d}", .{ a.bytes[0], a.bytes[1], a.bytes[2], a.bytes[3] }) catch "?",
        .ip6 => |a| {
            var i: usize = 0;
            var n: usize = 0;
            while (i < 16) : (i += 2) {
                if (i != 0) {
                    if (n >= out.len) return "?";
                    out[n] = ':';
                    n += 1;
                }
                if (n + 4 > out.len) return "?";
                _ = std.fmt.bufPrint(out[n .. n + 4], "{x:0>2}{x:0>2}", .{ a.bytes[i], a.bytes[i + 1] }) catch return "?";
                n += 4;
            }
            return out[0..n];
        },
    };
}

/// Build the HTML fragment returned by `/counter`: the request count, the
/// source IP, the current UTC server time, and the port.
fn counterFragment(state: *const State, src_ip: []const u8, out: []u8) []const u8 {
    const count = state.requests.load(.monotonic);
    var t_buf: [32]u8 = undefined;
    const t = formatUtc(state, &t_buf);
    var n: usize = 0;
    n += (std.fmt.bufPrint(out[n..], "<span class=\"row\">Requests: <span class=\"n\">{d}</span></span>", .{count}) catch return "error").len;
    n += (std.fmt.bufPrint(out[n..], "<span class=\"row\">Your IP: <span class=\"ip\">{s}</span></span>", .{src_ip}) catch return "error").len;
    n += (std.fmt.bufPrint(out[n..], "<span class=\"row\">Server time (UTC): <span class=\"t\">{s}</span></span>", .{t}) catch return "error").len;
    if (state.serve_path) |p| {
        n += (std.fmt.bufPrint(out[n..], "<span class=\"row\">Serving dir: <span class=\"dir\">{s}</span></span>", .{p}) catch return "error").len;
    }
    n += (std.fmt.bufPrint(out[n..], "<span class=\"row\">Port: <span class=\"port\">{d}</span></span>", .{state.cfg.port}) catch return "error").len;
    return out[0..n];
}

/// Map a file extension to a Content-Type header value. Defaults to a binary
/// fallback since extensionless paths (e.g. `/README`) may hold arbitrary data.
fn contentType(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (mem.eql(u8, ext, ".html") or mem.eql(u8, ext, ".htm")) return "text/html; charset=utf-8";
    if (mem.eql(u8, ext, ".js")) return "application/javascript";
    if (mem.eql(u8, ext, ".css")) return "text/css; charset=utf-8";
    if (mem.eql(u8, ext, ".json")) return "application/json";
    if (mem.eql(u8, ext, ".svg")) return "image/svg+xml";
    if (mem.eql(u8, ext, ".png")) return "image/png";
    if (mem.eql(u8, ext, ".jpg") or mem.eql(u8, ext, ".jpeg")) return "image/jpeg";
    if (mem.eql(u8, ext, ".gif")) return "image/gif";
    if (mem.eql(u8, ext, ".webp")) return "image/webp";
    if (mem.eql(u8, ext, ".ico")) return "image/x-icon";
    if (mem.eql(u8, ext, ".txt")) return "text/plain; charset=utf-8";
    if (mem.eql(u8, ext, ".md")) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

/// Maps a request target to the in-memory document name ("index.html").
/// Returns `null` for path traversal.
fn sanitizePath(target: []const u8) ?[]const u8 {
    var t = target;
    while (mem.startsWith(u8, t, "/")) t = t[1..];
    if (t.len == 0) return "index.html";
    if (mem.indexOf(u8, t, "..") != null) return null;
    return t;
}

fn logRequest(state: *State, method: std.http.Method, target: []const u8, status: u16, bytes: ?u64, src_ip: []const u8) void {
    var ts_buf: [64]u8 = undefined;
    const ts = fmtElapsed(state, &ts_buf);
    const m = @tagName(method);
    if (bytes) |b| {
        state.log.appendFmt(state.io, "{s} {s} {s} {s} -> {d} ({d}B)", .{ ts, src_ip, m, target, status, b });
    } else {
        state.log.appendFmt(state.io, "{s} {s} {s} {s} -> {d}", .{ ts, src_ip, m, target, status });
    }
    state.dirty.store(true, .seq_cst);
}

fn handleConnection(state: *State, stream: net.Stream) void {
    const io = state.io;
    defer {
        var copy = stream;
        copy.close(io);
    }

    var ip_buf: [64]u8 = undefined;
    const src_ip = formatIp(stream.socket.address, &ip_buf);

    var send_buffer: [16384]u8 = undefined;
    var recv_buffer: [16384]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return,
        };
        const method = request.head.method;
        const target = request.head.target;

        const sub = sanitizePath(target);
        if (sub == null) {
            request.respond("forbidden", .{
                .status = .forbidden,
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
            }) catch {};
            logRequest(state, method, target, 403, null, src_ip);
            continue;
        }

        // Dynamic routes: HTMX library and the live counter. These are served
        // in-memory (not from the temp dir) and do NOT increment the counter.
        if (mem.eql(u8, sub.?, "htmx.min.js")) {
            request.respond(htmx_js, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "application/javascript" }},
            }) catch {};
            continue;
        }
        if (mem.eql(u8, sub.?, "counter")) {
            var frag_buf: [512]u8 = undefined;
            const frag = counterFragment(state, src_ip, &frag_buf);
            request.respond(frag, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
            }) catch {};
            continue;
        }

        // Static content: either served from the configured directory on disk,
        // or (by default) the in-memory index.html body supplied at startup.
        if (state.serve_dir) |dir| {
            const file_contents = dir.readFileAlloc(io, sub.?, state.gpa, .limited(100 * 1024 * 1024)) catch |err| {
                const not_found = switch (err) {
                    error.FileNotFound, error.AccessDenied => true,
                    else => false,
                };
                const body: []const u8 = if (not_found) "not found" else "server error";
                const status: std.http.Status = if (not_found) .not_found else .internal_server_error;
                request.respond(body, .{
                    .status = status,
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
                }) catch {};
                logRequest(state, method, target, if (not_found) 404 else 500, null, src_ip);
                continue;
            };
            defer state.gpa.free(file_contents);

            request.respond(file_contents, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = contentType(sub.?) }},
            }) catch {};

            _ = state.requests.fetchAdd(1, .monotonic);
            logRequest(state, method, target, 200, file_contents.len, src_ip);
        } else {
            if (!mem.eql(u8, sub.?, "index.html")) {
                request.respond("not found", .{
                    .status = .not_found,
                    .extra_headers = &.{.{ .name = "Content-Type", .value = "text/plain" }},
                }) catch {};
                logRequest(state, method, target, 404, null, src_ip);
                continue;
            }

            request.respond(state.cfg.content, .{
                .extra_headers = &.{.{ .name = "Content-Type", .value = "text/html; charset=utf-8" }},
            }) catch {};

            _ = state.requests.fetchAdd(1, .monotonic);
            logRequest(state, method, target, 200, state.cfg.content.len, src_ip);
        }
    }
}

fn serveLoop(state: *State, tcp_server: *net.Server) Io.Cancelable!void {
    const io = state.io;
    var group: Io.Group = .init;
    defer group.cancel(io);
    while (true) {
        const stream = tcp_server.accept(io) catch |err| switch (err) {
            error.Canceled => |e| return e,
            else => return {},
        };
        group.concurrent(io, handleConnection, .{ state, stream }) catch {
            var copy = stream;
            copy.close(io);
        };
    }
}

fn tmuxSetTitle(state: *State) void {
    if (!state.tmux) return;
    var buf: [256]u8 = undefined;
    const title = std.fmt.bufPrint(&buf, "\x1b]2;http://{s}:{d}\x07", .{ state.cfg.host, state.cfg.port }) catch return;
    std.Io.File.stdout().writeStreamingAll(state.io, title) catch {};
}

fn winSize(state: *State) void {
    var wsz: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const io = state.io;
    if (io.operate(.{ .device_io_control = .{
        .file = std.Io.File.stdout(),
        .code = posix.T.IOCGWINSZ,
        .arg = &wsz,
    } }) catch null) |res| {
        if (res.device_io_control >= 0 and wsz.row > 0 and wsz.col > 0) {
            state.rows = wsz.row;
            state.cols = wsz.col;
            return;
        }
    }
    const environ = state.environ;
    if (environ.get("LINES")) |l| {
        state.rows = std.fmt.parseInt(u16, l, 10) catch state.rows;
    }
    if (environ.get("COLUMNS")) |c| {
        state.cols = std.fmt.parseInt(u16, c, 10) catch state.cols;
    }
}

fn tuiLoop(state: *State) Io.Cancelable!void {
    const io = state.io;
    const header_lines: u16 = 5;

    while (true) {
        if (g_stop.load(.seq_cst)) break;
        if (state.dirty.load(.seq_cst)) {
            state.dirty.store(false, .seq_cst);
            winSize(state);
            render(state, state.rows, state.cols, header_lines);
        }
        io.sleep(.{ .nanoseconds = @as(i96, 50) * std.time.ns_per_ms }, .awake) catch break;
    }
}

fn render(state: *State, rows: u16, cols: u16, header_lines: u16) void {
    const io = state.io;
    const stdout = std.Io.File.stdout();
    var buf: [8192]u8 = undefined;

    stdout.writeStreamingAll(io, "\x1b[1;1H\x1b[J") catch {};

    var line: []const u8 = undefined;

    const header_on = rows >= 7;

    if (header_on) {
        line = std.fmt.bufPrint(&buf, " \x1b[1m\x1b[36mTEMPORARY HTTP SERVER\x1b[0m  {s}:{d}", .{ state.cfg.host, state.cfg.port }) catch return;
        stdout.writeStreamingAll(io, line) catch {};
        if (!state.tmux) {
            stdout.writeStreamingAll(io, "  \x1b[90m(not in tmux)\x1b[0m") catch {};
        }
        stdout.writeStreamingAll(io, "\n") catch {};

        line = std.fmt.bufPrint(&buf, " URL   \x1b[4mhttp://{s}:{d}/\x1b[0m\n", .{ state.cfg.host, state.cfg.port }) catch return;
        stdout.writeStreamingAll(io, line) catch {};
        if (state.serve_path) |p| {
            line = std.fmt.bufPrint(&buf, " DIR   {s}\n", .{p}) catch return;
            stdout.writeStreamingAll(io, line) catch {};
        } else {
            line = std.fmt.bufPrint(&buf, " DIR   (in-memory)\n", .{}) catch return;
            stdout.writeStreamingAll(io, line) catch {};
        }
        const reqs = state.requests.load(.monotonic);
        line = std.fmt.bufPrint(&buf, " REQS  {d}   Ctrl-C to quit\n", .{reqs}) catch return;
        stdout.writeStreamingAll(io, line) catch {};

        var i: usize = 0;
        while (i < cols) : (i += 1) stdout.writeStreamingAll(io, "-") catch {};
        stdout.writeStreamingAll(io, "\n") catch {};
    }

    state.log.mutex.lock(io) catch return;
    defer state.log.mutex.unlock(io);

    const total = state.log.len;
    const avail: usize = if (header_on) rows - header_lines else rows;
    const show_count = @min(total, avail);
    const start: usize = total - show_count;
    var idx: usize = 0;
    while (idx < avail) : (idx += 1) {
        if (idx < show_count) {
            const ln = state.log.get(start + idx);
            line = std.fmt.bufPrint(&buf, "{s}", .{ln}) catch continue;
            stdout.writeStreamingAll(io, line) catch {};
        }
        if (idx + 1 < avail) stdout.writeStreamingAll(io, "\n") catch {};
    }
}

fn installSigint() void {
    const act: posix.Sigaction = .{
        .handler = .{ .handler = onSigint },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &act, null);
}

fn usage() void {
    std.debug.print("tmphttp - serve a temp-dir (or in-memory page) over HTTP with a live TUI\n", .{});
    std.debug.print("\nUsage: tmphttp [options] [content]\n", .{});
    std.debug.print("\nOptions:\n", .{});
    std.debug.print("  -p, --port <port>      Port to listen on               (default 8888)\n", .{});
    std.debug.print("  -H, --host <host>      Interface/address to bind to    (default 127.0.0.1)\n", .{});
    std.debug.print("  -d, --dir <path>       Serve an existing directory from disk\n", .{});
    std.debug.print("  -c, --content <html>   Contents for index.html         (default: placeholder)\n", .{});
    std.debug.print("  -f, --file <path>      Read index.html contents from a file\n", .{});
    std.debug.print("  --no-tui               Run without the full-screen TUI\n", .{});
    std.debug.print("  --help                 Show this help\n", .{});
}

var g_ctx_entered = false;
fn ctxEnter(io: Io) void {
    if (g_ctx_entered) return;
    g_ctx_entered = true;
    std.Io.File.stdout().writeStreamingAll(io, "\x1b[?1049h\x1b[?25l") catch {};
}
fn ctxExit(io: Io) void {
    if (!g_ctx_entered) return;
    g_ctx_entered = false;
    std.Io.File.stdout().writeStreamingAll(io, "\x1b[?25h\x1b[?1049l") catch {};
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var cfg: Config = .{
        .host = "127.0.0.1",
        .port = 8888,
        .content = DEFAULT_CONTENT,
    };
    var no_tui = false;

    var i: usize = 1;
    var positional_content: ?[]const u8 = null;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--help") or mem.eql(u8, arg, "-h")) {
            usage();
            return;
        } else if (mem.eql(u8, arg, "-p") or mem.eql(u8, arg, "--port")) {
            i += 1;
            if (i >= args.len) return error.MissingPort;
            cfg.port = std.fmt.parseInt(u16, args[i], 10) catch return error.InvalidPort;
        } else if (mem.eql(u8, arg, "-H") or mem.eql(u8, arg, "--host")) {
            i += 1;
            if (i >= args.len) return error.MissingHost;
            cfg.host = args[i];
        } else if (mem.eql(u8, arg, "-d") or mem.eql(u8, arg, "--dir")) {
            i += 1;
            if (i >= args.len) return error.MissingDir;
            cfg.dir = args[i];
        } else if (mem.eql(u8, arg, "-c") or mem.eql(u8, arg, "--content")) {
            i += 1;
            if (i >= args.len) return error.MissingContent;
            cfg.content = args[i];
        } else if (mem.eql(u8, arg, "-f") or mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= args.len) return error.MissingFile;
            const file_bytes = std.Io.Dir.cwd().readFileAlloc(io, args[i], arena, .unlimited) catch return error.CannotReadFile;
            cfg.content = file_bytes;
        } else if (mem.eql(u8, arg, "--no-tui")) {
            no_tui = true;
        } else if (mem.startsWith(u8, arg, "-")) {
            return error.UnknownArg;
        } else {
            positional_content = arg;
        }
    }
    if (positional_content) |c| cfg.content = c;

    const tmux = init.environ_map.get("TMUX") != null;

    // When a directory is provided, serve it from disk. Otherwise the default
    // in-memory index.html page is served (no temp dir is created).
    var serve_dir: ?Io.Dir = null;
    var serve_path: ?[]const u8 = null;
    if (cfg.dir) |dir| {
        const d = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return error.CannotOpenDir;
        serve_dir = d;
        serve_path = try std.Io.Dir.cwd().realPathFileAlloc(io, dir, arena);
    }

    var state: State = .{
        .io = io,
        .gpa = gpa,
        .cfg = cfg,
        .serve_dir = serve_dir,
        .serve_path = serve_path,
        .log = try Log.init(gpa),
        .tmux = tmux,
        .environ = init.environ_map,
        .start = std.Io.Timestamp.now(io, .awake),
    };
    defer if (serve_dir) |*d| d.close(io);
    defer state.log.deinit(gpa);

    if (serve_path) |p| {
        state.log.appendFmt(io, "Serving {s} at http://{s}:{d}/", .{ p, cfg.host, cfg.port });
    } else {
        state.log.appendFmt(io, "Serving in-memory page at http://{s}:{d}/", .{ cfg.host, cfg.port });
    }
    state.log.appendFmt(io, "Press Ctrl-C to stop.", .{});

    // Bind the TCP listener.
    const address = try net.IpAddress.parse(cfg.host, cfg.port);
    var tcp_server = address.listen(io, .{}) catch |err| {
        std.debug.print("failed to bind {s}:{d}: {s} (is another process already using this port?)\n", .{ cfg.host, cfg.port, @errorName(err) });
        std.process.exit(1);
    };
    defer tcp_server.deinit(io);

    // If running in tmux, set the window title to host:port.
    tmuxSetTitle(&state);

    installSigint();

    if (no_tui) {
        var serve_future = try io.concurrent(serveLoop, .{ &state, &tcp_server });
        // Keep running until SIGINT.
        while (!g_stop.load(.seq_cst)) {
            io.sleep(.{ .nanoseconds = @as(i96, 200) * std.time.ns_per_ms }, .awake) catch {};
        }
        _ = serve_future.cancel(io) catch {};
        _ = serve_future.await(io) catch {};
        std.debug.print("Stopped.\n", .{});
        return;
    }

    ctxEnter(io);

    var serve_future = try io.concurrent(serveLoop, .{ &state, &tcp_server });
    var tui_future = try io.concurrent(tuiLoop, .{ &state });

    _ = tui_future.await(io) catch {};
    _ = serve_future.cancel(io) catch {};
    _ = serve_future.await(io) catch {};

    ctxExit(io);
    std.debug.print("Stopped.\n", .{});
}
