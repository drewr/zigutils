const std = @import("std");
const fs = std.fs;
const process = std.process;
const mem = std.mem;

const GitUrl = struct {
    org: []const u8,
    repo: []const u8,
};

const ProgressBar = struct {
    total: usize = 100,
    current: usize = 0,
    phase: []const u8 = "",
    width: usize = 40,

    fn draw(self: *const ProgressBar) void {
        const percent = if (self.total > 0)
            @min(100, (self.current * 100) / self.total)
        else
            0;

        const filled = (self.width * percent) / 100;

        // Move to beginning of line and clear it
        std.debug.print("\r\x1b[K", .{});

        // Print progress bar
        std.debug.print("{s} [", .{self.phase});

        var i: usize = 0;
        while (i < filled) : (i += 1) {
            std.debug.print("█", .{});
        }
        while (i < self.width) : (i += 1) {
            std.debug.print("░", .{});
        }

        std.debug.print("] {d}% ({d}/{d})", .{ percent, self.current, self.total });
    }

    fn finish(self: *const ProgressBar) void {
        self.draw();
        std.debug.print("\n", .{});
    }
};

fn parseGitProgress(line: []const u8, progress: *ProgressBar) void {
    // Git output patterns:
    // "Counting objects: 100% (123/123)"
    // "Compressing objects: 50% (50/100)"
    // "Receiving objects: 75% (750/1000)"
    // "Resolving deltas: 100% (456/456)"

    if (mem.indexOf(u8, line, "Counting objects:")) |_| {
        progress.phase = "Counting  ";
        if (parseGitPercentage(line)) |info| {
            progress.current = info.current;
            progress.total = info.total;
        }
    } else if (mem.indexOf(u8, line, "Compressing objects:")) |_| {
        progress.phase = "Compressing";
        if (parseGitPercentage(line)) |info| {
            progress.current = info.current;
            progress.total = info.total;
        }
    } else if (mem.indexOf(u8, line, "Receiving objects:")) |_| {
        progress.phase = "Receiving ";
        if (parseGitPercentage(line)) |info| {
            progress.current = info.current;
            progress.total = info.total;
        }
    } else if (mem.indexOf(u8, line, "Resolving deltas:")) |_| {
        progress.phase = "Resolving ";
        if (parseGitPercentage(line)) |info| {
            progress.current = info.current;
            progress.total = info.total;
        }
    }
}

const GitProgressInfo = struct {
    current: usize,
    total: usize,
};

fn parseGitPercentage(line: []const u8) ?GitProgressInfo {
    // Look for pattern like "(123/456)" or "(123/456, 789 bytes)"
    const open_paren = mem.indexOf(u8, line, "(") orelse return null;
    const close_paren = mem.indexOf(u8, line[open_paren..], ")") orelse return null;
    const progress_str = line[open_paren + 1 .. open_paren + close_paren];

    const slash = mem.indexOf(u8, progress_str, "/") orelse return null;

    // Parse current
    const current_str = mem.trim(u8, progress_str[0..slash], " ");
    const current = std.fmt.parseInt(usize, current_str, 10) catch return null;

    // Parse total (might have comma and extra info)
    var total_str = mem.trim(u8, progress_str[slash + 1 ..], " ");
    if (mem.indexOf(u8, total_str, ",")) |comma| {
        total_str = total_str[0..comma];
    }
    const total = std.fmt.parseInt(usize, total_str, 10) catch return null;

    return GitProgressInfo{ .current = current, .total = total };
}

const UrlParseError = struct {
    reason: []const u8,
    url: []const u8,
    detected_format: ?[]const u8 = null,
    found_at: ?[]const u8 = null,
    expected: ?[]const u8 = null,
};

fn reportParseError(err: UrlParseError) void {
    std.debug.print("\n", .{});
    std.debug.print("❌ Failed to parse git URL: {s}\n", .{err.url});
    std.debug.print("   └─ {s}\n", .{err.reason});

    if (err.detected_format) |fmt| {
        std.debug.print("   └─ Detected format: {s}\n", .{fmt});
    }

    if (err.found_at) |found| {
        std.debug.print("   └─ Found: {s}\n", .{found});
    }

    if (err.expected) |exp| {
        std.debug.print("   └─ Expected: {s}\n", .{exp});
    }

    std.debug.print("\n", .{});
    std.debug.print("Valid URL formats:\n", .{});
    std.debug.print("  SSH:   git@github.com:org/repo.git\n", .{});
    std.debug.print("  HTTPS: https://github.com/org/repo.git\n", .{});
    std.debug.print("  HTTP:  http://github.com/org/repo.git\n", .{});
    std.debug.print("\n", .{});
}

fn parseGitUrl(allocator: mem.Allocator, url: []const u8) !GitUrl {
    // Check if it looks like a local path
    if (mem.indexOf(u8, url, "@") == null and
        mem.indexOf(u8, url, "://") == null)
    {
        reportParseError(.{
            .reason = "URL doesn't match any known git URL format",
            .url = url,
            .detected_format = "Local path or invalid format",
            .expected = "git@host:org/repo OR https://host/org/repo",
        });
        return error.InvalidUrl;
    }

    // Handle SSH URLs: git@github.com:org/repo.git
    if (mem.indexOf(u8, url, "@")) |at_pos| {
        const colon_pos = mem.lastIndexOf(u8, url, ":");

        if (colon_pos == null) {
            const host_part = url[at_pos + 1 ..];
            reportParseError(.{
                .reason = "SSH format missing colon separator",
                .url = url,
                .detected_format = "SSH (git@...)",
                .found_at = host_part,
                .expected = "git@host:org/repo",
            });
            return error.InvalidUrl;
        }

        const path = url[colon_pos.? + 1 ..];

        if (mem.indexOf(u8, path, "/") == null) {
            reportParseError(.{
                .reason = "Path missing org/repo separator",
                .url = url,
                .detected_format = "SSH (git@host:...)",
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            });
            return error.InvalidUrl;
        }

        return parsePathComponent(allocator, path) catch |err| {
            reportParseError(.{
                .reason = "Failed to parse org/repo from path",
                .url = url,
                .detected_format = "SSH",
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            });
            return err;
        };
    }

    // Handle HTTPS/HTTP URLs: https://github.com/org/repo.git
    if (mem.startsWith(u8, url, "http://") or mem.startsWith(u8, url, "https://")) {
        const protocol_end = mem.indexOf(u8, url, "://");
        const protocol = if (mem.startsWith(u8, url, "https://")) "https" else "http";

        if (protocol_end == null) {
            reportParseError(.{
                .reason = "Malformed protocol",
                .url = url,
                .detected_format = "HTTP/HTTPS",
                .expected = "http:// or https://",
            });
            return error.InvalidUrl;
        }

        const after_protocol = url[protocol_end.? + 3 ..];
        const slash_pos = mem.indexOf(u8, after_protocol, "/");

        if (slash_pos == null) {
            const host = after_protocol;
            reportParseError(.{
                .reason = "Missing path after hostname",
                .url = url,
                .detected_format = protocol,
                .found_at = host,
                .expected = "host/org/repo",
            });
            return error.InvalidUrl;
        }

        const path = after_protocol[slash_pos.? + 1 ..];

        if (mem.indexOf(u8, path, "/") == null) {
            reportParseError(.{
                .reason = "Path missing org/repo separator",
                .url = url,
                .detected_format = protocol,
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            });
            return error.InvalidUrl;
        }

        return parsePathComponent(allocator, path) catch |err| {
            reportParseError(.{
                .reason = "Failed to parse org/repo from path",
                .url = url,
                .detected_format = protocol,
                .found_at = path,
                .expected = "org/repo or org/repo.git",
            });
            return err;
        };
    }

    reportParseError(.{
        .reason = "URL doesn't start with recognized protocol",
        .url = url,
        .expected = "git@... OR http://... OR https://...",
    });
    return error.InvalidUrl;
}

fn parsePathComponent(allocator: mem.Allocator, path: []const u8) !GitUrl {
    // Path should be like "org/repo.git" or "org/repo"
    const slash_pos = mem.indexOf(u8, path, "/") orelse return error.InvalidUrl;
    const org = path[0..slash_pos];
    var repo = path[slash_pos + 1 ..];

    // Remove .git suffix if present
    if (mem.endsWith(u8, repo, ".git")) {
        repo = repo[0 .. repo.len - 4];
    }

    return GitUrl{
        .org = try allocator.dupe(u8, org),
        .repo = try allocator.dupe(u8, repo),
    };
}

fn getHome(allocator: mem.Allocator) ![]const u8 {
    return process.getEnvVarOwned(allocator, "HOME") catch |err| {
        std.debug.print("Error: Could not get HOME environment variable\n", .{});
        return err;
    };
}

fn runGitCloneWithProgress(allocator: mem.Allocator, url: []const u8, dest: []const u8) !void {
    var child = process.Child.init(&[_][]const u8{ "git", "clone", "--progress", url, dest }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe; // Git outputs progress to stderr

    try child.spawn();

    var progress = ProgressBar{};
    var buffer: [4096]u8 = undefined;

    // Read stderr (where git outputs progress)
    if (child.stderr) |stderr| {
        while (true) {
            const bytes_read = stderr.read(&buffer) catch break;
            if (bytes_read == 0) break;

            const output = buffer[0..bytes_read];

            // Split by lines and parse each one
            var iter = mem.splitSequence(u8, output, "\r");
            while (iter.next()) |line| {
                if (line.len == 0) continue;
                parseGitProgress(line, &progress);
                progress.draw();
            }
        }
    }

    // Read stdout (for any regular output)
    if (child.stdout) |stdout| {
        while (true) {
            const bytes_read = stdout.read(&buffer) catch break;
            if (bytes_read == 0) break;
            // Just consume it, don't display
        }
    }

    const term = try child.wait();
    progress.finish();

    switch (term) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("git clone exited with code {}\n", .{code});
                return error.GitCloneFailed;
            }
        },
        else => return error.GitCloneFailed,
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

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

    const url = git_url.?;
    const parsed = try parseGitUrl(allocator, url);
    defer allocator.free(parsed.org);
    defer allocator.free(parsed.repo);

    // Determine the root directory
    const base_path = if (root_dir) |r| try allocator.dupe(u8, r) else blk: {
        const home = try getHome(allocator);
        defer allocator.free(home);
        break :blk try fs.path.join(allocator, &[_][]const u8{ home, "src" });
    };
    defer allocator.free(base_path);

    // Build the full path: root/org/repo
    const org_path = try fs.path.join(allocator, &[_][]const u8{ base_path, parsed.org });
    defer allocator.free(org_path);

    const full_path = try fs.path.join(allocator, &[_][]const u8{ org_path, parsed.repo });
    defer allocator.free(full_path);

    // Create directories if they don't exist
    fs.cwd().makePath(org_path) catch |err| {
        std.debug.print("Error creating directory {s}: {}\n", .{ org_path, err });
        return err;
    };

    std.debug.print("Cloning {s} into {s}\n", .{ url, full_path });

    try runGitCloneWithProgress(allocator, url, full_path);

    std.debug.print("Successfully cloned to {s}\n", .{full_path});
}
