const std = @import("std");
const mem = std.mem;

pub const GitUrl = struct {
    org: []const u8,
    repo: []const u8,
};

/// Pure: parse a git URL into its org and repo components.
/// Returns a ParseError with a human-readable reason on failure
/// (analogous to Haskell's Either String GitUrl).
pub fn parseGitUrl(url: []const u8) ParseError!GitUrl {
    if (mem.indexOfScalar(u8, url, '@')) |_| {
        return parseSsh(url);
    }
    if (mem.startsWith(u8, url, "https://") or mem.startsWith(u8, url, "http://")) {
        return parseHttp(url);
    }
    return error.NotAGitUrl;
}

pub const ParseError = error{
    NotAGitUrl,
    MissingUser,
    MissingHostname,
    MissingColon,
    MissingPath,
    EmptyOrg,
    EmptyRepo,
    ExtraSlashes,
};

fn parseSsh(url: []const u8) ParseError!GitUrl {
    const at_pos = mem.indexOfScalar(u8, url, '@').?;
    if (at_pos == 0) return error.MissingUser;
    const colon_pos = mem.lastIndexOfScalar(u8, url, ':') orelse return error.MissingColon;
    const host = url[at_pos + 1 .. colon_pos];
    if (host.len == 0) return error.MissingHostname;
    return parsePath(url[colon_pos + 1 ..]);
}

fn parseHttp(url: []const u8) ParseError!GitUrl {
    const scheme_end: usize = if (mem.startsWith(u8, url, "https://")) 8 else 7;
    const after_scheme = url[scheme_end..];
    const slash_pos = mem.indexOfScalar(u8, after_scheme, '/') orelse return error.MissingPath;
    const host = after_scheme[0..slash_pos];
    if (host.len == 0) return error.MissingHostname;
    return parsePath(after_scheme[slash_pos + 1 ..]);
}

fn parsePath(path: []const u8) ParseError!GitUrl {
    const slash_pos = mem.indexOfScalar(u8, path, '/') orelse return error.MissingPath;
    const org = path[0..slash_pos];
    if (org.len == 0) return error.EmptyOrg;
    var repo = path[slash_pos + 1 ..];
    if (repo.len == 0) return error.EmptyRepo;
    if (mem.indexOfScalar(u8, repo, '/') != null) return error.ExtraSlashes;
    if (mem.endsWith(u8, repo, ".git")) repo = repo[0 .. repo.len - 4];
    if (repo.len == 0) return error.EmptyRepo;
    return GitUrl{ .org = org, .repo = repo };
}

// ---------------------------------------------------------------------------
// Progress types — all pure
// ---------------------------------------------------------------------------

pub const Phase = enum {
    counting,
    compressing,
    receiving,
    resolving,

    pub fn label(self: Phase) []const u8 {
        return switch (self) {
            .counting => "Counting  ",
            .compressing => "Compressing",
            .receiving => "Receiving ",
            .resolving => "Resolving ",
        };
    }
};

pub const ProgressState = struct {
    total: usize,
    current: usize,
    phase: ?Phase,
};

pub const Display = struct {
    phase: []const u8,
    percent: usize,
    current: usize,
    total: usize,
    filled: usize,
    width: usize,
};

pub const ProgressInfo = struct {
    current: usize,
    total: usize,
};

/// Pure: parse a line of git stderr and produce a new ProgressState.
/// Returns the same state if the line doesn't match a git progress pattern.
pub fn parseProgressLine(state: ProgressState, line: []const u8) ProgressState {
    const phase = detectPhase(line) orelse return state;
    if (parsePercentage(line)) |info| {
        return .{ .total = info.total, .current = info.current, .phase = phase };
    }
    return .{ .total = state.total, .current = state.current, .phase = phase };
}

fn detectPhase(line: []const u8) ?Phase {
    if (mem.startsWith(u8, line, "Counting objects:")) return .counting;
    if (mem.startsWith(u8, line, "Compressing objects:")) return .compressing;
    if (mem.startsWith(u8, line, "Receiving objects:")) return .receiving;
    if (mem.startsWith(u8, line, "Resolving deltas:")) return .resolving;
    return null;
}

/// Pure: compute the display attributes from a ProgressState.
pub fn stateToDisplay(state: ProgressState) Display {
    const percent = if (state.total > 0)
        @min(100, (state.current * 100) / state.total)
    else
        0;
    const width: usize = 40;
    const filled = (width * percent) / 100;
    return .{
        .phase = if (state.phase) |p| p.label() else "",
        .percent = percent,
        .current = state.current,
        .total = state.total,
        .filled = filled,
        .width = width,
    };
}

/// Pure: extract (current/total) from a git progress line like "(123/456)" or "(123/456, 5.2 MiB)".
pub fn parsePercentage(line: []const u8) ?ProgressInfo {
    const open_paren = mem.indexOfScalar(u8, line, '(') orelse return null;
    const rest = line[open_paren + 1 ..];
    const close_paren = mem.indexOfScalar(u8, rest, ')') orelse return null;
    const inner = rest[0..close_paren];
    const slash = mem.indexOfScalar(u8, inner, '/') orelse return null;
    const current = std.fmt.parseInt(usize, mem.trim(u8, inner[0..slash], " "), 10) catch return null;
    var total_str = mem.trim(u8, inner[slash + 1 ..], " ");
    if (mem.indexOfScalar(u8, total_str, ',')) |comma| total_str = total_str[0..comma];
    total_str = mem.trim(u8, total_str, " ");
    const total = std.fmt.parseInt(usize, total_str, 10) catch return null;
    return .{ .current = current, .total = total };
}

/// Pure: format a ParseError as a human-readable string.
pub fn formatParseError(err: ParseError) []const u8 {
    return switch (err) {
        error.NotAGitUrl => "URL doesn't start with git@..., http://, or https://",
        error.MissingUser => "SSH format missing user (expected git@host:org/repo)",
        error.MissingHostname => "Missing hostname",
        error.MissingColon => "SSH format missing colon separator",
        error.MissingPath => "Missing org/repo path",
        error.EmptyOrg => "Org is empty",
        error.EmptyRepo => "Repo name is empty",
        error.ExtraSlashes => "Repo path contains multiple slashes",
    };
}

// ---------------------------------------------------------------------------
// IO boundary — everything below does IO
// ---------------------------------------------------------------------------

pub fn reportParseError(err: ParseError) void {
    std.debug.print(
        \\
        \\Failed to parse git URL
        \\  {s}
        \\
        \\Valid URL formats:
        \\  SSH:   git@github.com:org/repo.git
        \\  HTTPS: https://github.com/org/repo.git
        \\  HTTP:  http://github.com/org/repo.git
        \\
    , .{formatParseError(err)});
}

pub fn drawProgress(io: std.Io, state: ProgressState) void {
    const d = stateToDisplay(state);
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "\r\x1b[K{s} [", .{d.phase}) catch unreachable;
    _ = std.Io.File.stdout().writeStreamingAll(io, line) catch return;
    var i: usize = 0;
    while (i < d.filled) : (i += 1) {
        _ = std.Io.File.stdout().writeStreamingAll(io, "█") catch return;
    }
    while (i < d.width) : (i += 1) {
        _ = std.Io.File.stdout().writeStreamingAll(io, "░") catch return;
    }
    const suffix = std.fmt.bufPrint(&buf, "] {d}% ({d}/{d})", .{ d.percent, d.current, d.total }) catch unreachable;
    _ = std.Io.File.stdout().writeStreamingAll(io, suffix) catch return;
}

pub fn finishProgress(io: std.Io, state: ProgressState) void {
    drawProgress(io, state);
    _ = std.Io.File.stdout().writeStreamingAll(io, "\n") catch return;
}

pub fn destinationExists(io: std.Io, path: []const u8) !bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    return true;
}

fn runGitCloneWithProgress(io: std.Io, url: []const u8, dest: []const u8) !void {
    var child = try std.process.spawn(io, .{
        .argv = &.{ "git", "clone", "--progress", url, dest },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
    });
    defer child.kill(io);

    var state: ProgressState = .{ .total = 100, .current = 0, .phase = null };
    var buffer: [4096]u8 = undefined;

    if (child.stderr) |stderr| {
        while (true) {
            const vecs: [1][]u8 = .{buffer[0..]};
            const bytes_read = stderr.readStreaming(io, &vecs) catch break;
            const output = buffer[0..bytes_read];
            var iter = mem.splitSequence(u8, output, "\r");
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                state = parseProgressLine(state, line);
                drawProgress(io, state);
            }
        }
    }

    if (child.stdout) |stdout| {
        while (true) {
            const vecs: [1][]u8 = .{buffer[0..]};
            _ = stdout.readStreaming(io, &vecs) catch break;
        }
    }

    const term = try child.wait(io);
    finishProgress(io, state);

    switch (term) {
        .exited => |code| {
            if (code != 0) {
                std.debug.print("git clone exited with code {}\n", .{code});
                return error.GitCloneFailed;
            }
        },
        else => return error.GitCloneFailed,
    }
}

pub fn main(init: std.process.Init) !void {
    mainInner(init) catch std.process.exit(1);
}

fn mainInner(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var root_dir: ?[]const u8 = null;
    var git_url: ?[]const u8 = null;
    var i: usize = 1;

    while (i < args.len) : (i += 1) {
        if (mem.eql(u8, args[i], "--root")) {
            if (i + 1 >= args.len) {
                std.debug.print("Error: --root requires an argument\n", .{});
                return error.InvalidArgs;
            }
            i += 1;
            root_dir = args[i];
        } else if (git_url == null) {
            git_url = args[i];
        } else {
            std.debug.print("Error: Too many arguments\n", .{});
            return error.InvalidArgs;
        }
    }

    if (git_url == null) {
        std.debug.print("Usage: {s} [--root <path>] <git-url>\n", .{args[0]});
        return error.MissingUrl;
    }

    const parsed = parseGitUrl(git_url.?) catch |err| {
        reportParseError(err);
        return error.InvalidUrl;
    };

    const home = init.environ_map.get("HOME") orelse {
        std.debug.print("Error: Could not get HOME environment variable\n", .{});
        return error.EnvironmentVariableNotFound;
    };

    const arena = init.arena;
    const base_path = if (root_dir) |r|
        try arena.allocator().dupe(u8, r)
    else
        try std.fs.path.join(arena.allocator(), &[_][]const u8{ home, "src" });

    const org_path = try std.fs.path.join(arena.allocator(), &[_][]const u8{ base_path, parsed.org });
    const full_path = try std.fs.path.join(arena.allocator(), &[_][]const u8{ org_path, parsed.repo });

    const dest_exists = destinationExists(init.io, full_path) catch |err| {
        std.debug.print("Error checking destination {s}: {}\n", .{ full_path, err });
        return err;
    };

    if (dest_exists) {
        std.debug.print("Destination already exists: {s}\n", .{full_path});
        std.debug.print("Remove it or choose a different --root.\n", .{});
        return error.DestinationExists;
    }

    std.Io.Dir.cwd().createDirPath(init.io, org_path) catch |err| {
        std.debug.print("Error creating directory {s}: {}\n", .{ org_path, err });
        return err;
    };

    std.debug.print("Cloning {s} into {s}\n", .{ git_url.?, full_path });
    try runGitCloneWithProgress(init.io, git_url.?, full_path);
    std.debug.print("Successfully cloned to {s}\n", .{full_path});
}
