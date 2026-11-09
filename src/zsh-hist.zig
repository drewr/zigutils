//! Delete entries matching a pattern from zsh history.
//!
//! Dry run by default: prints the entries that would be removed. Pass
//! `--delete` to rewrite the history file (a backup is made first).
//!
//! Handles plain and EXTENDED_HISTORY (`: <ts>:<dur>;cmd`) entries,
//! multi-line commands (lines continued with a trailing backslash), and zsh's
//! "metafied" encoding of non-ASCII bytes.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Io = std.Io;
const regex = @import("regex");

const META: u8 = 0x83;

// ===========================================================================
// History parsing — pure
// ===========================================================================

/// Split a history file into entries. Each entry is a slice of `raw` and may
/// span several lines: a line whose final byte (before the newline) is a
/// backslash continues the entry.
pub fn splitEntries(gpa: Allocator, raw: []const u8) Allocator.Error![]const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    errdefer entries.deinit(gpa);

    var start: usize = 0;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\n') continue;
        const line = raw[start..i];
        if (!mem.endsWith(u8, line, "\\")) {
            try entries.append(gpa, raw[start .. i + 1]);
            start = i + 1;
        }
    }
    if (start < raw.len) try entries.append(gpa, raw[start..]);
    return entries.toOwnedSlice(gpa);
}

/// Returns the length of an EXTENDED_HISTORY prefix (`: <ts>:<dur>;`), or
/// null when the entry does not start with one.
pub fn extendedPrefixLen(entry: []const u8) ?usize {
    if (entry.len < 3 or entry[0] != ':' or entry[1] != ' ') return null;
    var i: usize = 2;

    var digits: usize = 0;
    while (i < entry.len and entry[i] >= '0' and entry[i] <= '9') : (i += 1) digits += 1;
    if (digits == 0 or i >= entry.len or entry[i] != ':') return null;
    i += 1;

    digits = 0;
    while (i < entry.len and entry[i] >= '0' and entry[i] <= '9') : (i += 1) digits += 1;
    if (digits == 0 or i >= entry.len or entry[i] != ';') return null;
    return i + 1;
}

/// Turn one raw history entry into the command text: drop the trailing
/// newline, strip an extended-history prefix, turn `\`+newline into a real
/// newline, and unmetafy non-ASCII bytes. The result is stored in `buf`.
pub fn commandText(gpa: Allocator, buf: *std.ArrayList(u8), entry: []const u8) Allocator.Error![]const u8 {
    buf.clearRetainingCapacity();

    var s = entry;
    if (s.len > 0 and s[s.len - 1] == '\n') s = s[0 .. s.len - 1];
    if (extendedPrefixLen(s)) |prefix_len| s = s[prefix_len..];

    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        if (b == '\\' and i + 1 < s.len and s[i + 1] == '\n') {
            try buf.append(gpa, '\n');
            i += 2;
            continue;
        }
        if (b == META) {
            // A metafied byte is META followed by the original byte xor 0x20.
            // A lone META at the end of the entry is dropped, as Python's
            // version does.
            if (i + 1 < s.len) {
                try buf.append(gpa, s[i + 1] ^ 0x20);
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }
        try buf.append(gpa, b);
        i += 1;
    }
    return buf.items;
}

/// Write command text for display, indenting continuation lines by four
/// spaces.
pub fn formatEntry(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
    for (text, 0..) |b, i| {
        try w.writeByte(b);
        if (b == '\n' and i + 1 < text.len) try w.writeAll("    ");
    }
}

// ===========================================================================
// Command line — pure
// ===========================================================================

pub const Options = struct {
    delete: bool = false,
    fixed_strings: bool = false,
    ignore_case: bool = false,
    line_regexp: bool = false,
    file: ?[]const u8 = null,
    no_backup: bool = false,
    help: bool = false,
    pattern: ?[]const u8 = null,
};

pub const ArgsError = error{
    MissingPattern,
    MissingFileArgument,
    UnknownOption,
    TooManyArguments,
};

pub fn formatArgsError(err: ArgsError) []const u8 {
    return switch (err) {
        error.MissingPattern => "missing PATTERN",
        error.MissingFileArgument => "option -f/--file requires an argument",
        error.UnknownOption => "unknown option",
        error.TooManyArguments => "too many arguments",
    };
}

/// Parse a full argv slice (including the program name).
pub fn parseArgs(args: []const []const u8) ArgsError!Options {
    var opts: Options = .{};
    var positional_only = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (positional_only or arg.len < 2 or arg[0] != '-') {
            if (opts.pattern != null) return error.TooManyArguments;
            opts.pattern = arg;
            continue;
        }
        if (mem.eql(u8, arg, "--")) {
            positional_only = true;
            continue;
        }

        if (mem.startsWith(u8, arg, "--")) {
            if (mem.eql(u8, arg, "--delete")) {
                opts.delete = true;
            } else if (mem.eql(u8, arg, "--fixed-strings")) {
                opts.fixed_strings = true;
            } else if (mem.eql(u8, arg, "--ignore-case")) {
                opts.ignore_case = true;
            } else if (mem.eql(u8, arg, "--line-regexp")) {
                opts.line_regexp = true;
            } else if (mem.eql(u8, arg, "--no-backup")) {
                opts.no_backup = true;
            } else if (mem.eql(u8, arg, "--help")) {
                opts.help = true;
            } else if (mem.startsWith(u8, arg, "--file=")) {
                opts.file = arg["--file=".len..];
            } else if (mem.eql(u8, arg, "--file")) {
                i += 1;
                if (i >= args.len) return error.MissingFileArgument;
                opts.file = args[i];
            } else {
                return error.UnknownOption;
            }
            continue;
        }

        // Short options, possibly combined (`-di`) and possibly with an
        // attached file argument (`-fFILE`).
        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            switch (arg[j]) {
                'd' => opts.delete = true,
                'F' => opts.fixed_strings = true,
                'i' => opts.ignore_case = true,
                'x' => opts.line_regexp = true,
                'h' => opts.help = true,
                'f' => {
                    if (j + 1 < arg.len) {
                        opts.file = arg[j + 1 ..];
                        j = arg.len;
                    } else {
                        i += 1;
                        if (i >= args.len) return error.MissingFileArgument;
                        opts.file = args[i];
                    }
                    break;
                },
                else => return error.UnknownOption,
            }
        }
    }

    if (!opts.help and opts.pattern == null) return error.MissingPattern;
    return opts;
}

/// Pick the history path out of the output of the zsh probe.
pub fn extractHistfileMarker(output: []const u8) ?[]const u8 {
    const marker = "@@HISTFILE@@";
    var lines = mem.splitScalar(u8, output, '\n');
    while (lines.next()) |raw_line| {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (mem.startsWith(u8, line, marker) and line.len > marker.len) {
            return line[marker.len..];
        }
    }
    return null;
}

/// Format an epoch timestamp as `YYYYMMDD-HHMMSS` in UTC.
pub const BackupError = error{BackupIncomplete};

/// Write `contents` (the history bytes already read) to `backup_path`, with
/// the permissions of `path`. Fails if `backup_path` already exists, and
/// checks that the whole file landed before the caller rewrites the history.
///
/// This deliberately avoids `Dir.copyFile(.., .{ .replace = false })`: in Zig
/// 0.18.0-dev.610 its final `linkat(AT_EMPTY_PATH)` fails with ENOENT for
/// unprivileged processes on Linux, and that error is swallowed, so it reports
/// success without creating the file.
pub fn writeBackup(
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    backup_path: []const u8,
    contents: []const u8,
) !void {
    const source = try dir.statFile(io, path, .{});
    var file = try dir.createFile(io, backup_path, .{
        .exclusive = true,
        .permissions = source.permissions,
    });
    var file_open = true;
    defer if (file_open) file.close(io);
    errdefer dir.deleteFile(io, backup_path) catch {};

    try file.writeStreamingAll(io, contents);
    file.close(io);
    file_open = false;

    const written = try dir.statFile(io, backup_path, .{ .follow_symlinks = false });
    if (written.size != contents.len) return BackupError.BackupIncomplete;
}

pub fn fmtBackupSuffix(epoch_secs: u64, buf: []u8) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_secs };
    const ymd = epoch.getEpochDay().calculateYearDay();
    const mon_day = ymd.calculateMonthDay();
    const tod = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        ymd.year,
        mon_day.month.numeric(),
        mon_day.day_index + 1,
        tod.getHoursIntoDay(),
        tod.getMinutesIntoHour(),
        tod.getSecondsIntoMinute(),
    }) catch "00000000-000000";
}

// ===========================================================================
// IO boundary
// ===========================================================================

pub const HistoryLocked = error{HistoryLocked};

pub const Summary = struct {
    total: usize,
    matched: usize,
    /// Owned by the caller when non-null.
    backup_path: ?[]u8 = null,
};

/// Delete (or preview deleting) matching entries.
///
/// `dir` is the directory used to resolve `path`; `path` may also be
/// absolute. `out` receives everything the tool would print.
pub fn run(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    path: []const u8,
    opts: Options,
    out: *Io.Writer,
    now_secs: u64,
) !Summary {
    const pattern = opts.pattern orelse return error.MissingPattern;

    // Take zsh's own lock before reading, so a shell appending to the history
    // while we rewrite it cannot lose lines.
    var lock_path: ?[]u8 = null;
    defer if (lock_path) |lp| {
        dir.deleteFile(io, lp) catch {};
        gpa.free(lp);
    };
    if (opts.delete) {
        const lp = try std.fmt.allocPrint(gpa, "{s}.LOCK", .{path});
        var lock_file = dir.createFile(io, lp, .{ .exclusive = true, .truncate = false }) catch |err| {
            gpa.free(lp);
            return switch (err) {
                error.PathAlreadyExists => HistoryLocked.HistoryLocked,
                else => err,
            };
        };
        lock_path = lp;
        lock_file.close(io);
    }

    const raw = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(raw);

    const entries = try splitEntries(gpa, raw);
    defer gpa.free(entries);

    var re = try regex.Regex.compile(gpa, pattern, .{
        .case_insensitive = opts.ignore_case,
        .literal = opts.fixed_strings,
        .whole = opts.line_regexp,
    });
    defer re.deinit(gpa);

    var kept: std.ArrayList([]const u8) = .empty;
    defer kept.deinit(gpa);
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(gpa);

    var matched: usize = 0;
    for (entries) |entry| {
        const text = try commandText(gpa, &text_buf, entry);
        if (re.isMatch(text)) {
            matched += 1;
            try out.writeAll("  ");
            try formatEntry(out, text);
            try out.writeByte('\n');
        } else {
            try kept.append(gpa, entry);
        }
    }

    if (matched == 0) {
        try out.print("No entries in {s} match \"{s}\".\n", .{ path, pattern });
        return .{ .total = entries.len, .matched = 0 };
    }

    try out.writeByte('\n');

    if (!opts.delete) {
        try out.print("[dry run] {d} of {d} entries would be deleted from {s}.\n", .{
            matched, entries.len, path,
        });
        try out.writeAll("Re-run with --delete to remove them.\n");
        return .{ .total = entries.len, .matched = matched };
    }

    var backup_path: ?[]u8 = null;
    errdefer if (backup_path) |bp| gpa.free(bp);
    if (!opts.no_backup) {
        var suffix_buf: [32]u8 = undefined;
        const suffix = fmtBackupSuffix(now_secs, &suffix_buf);
        const bp = try std.fmt.allocPrint(gpa, "{s}.bak.{s}", .{ path, suffix });
        errdefer gpa.free(bp);
        try writeBackup(io, dir, path, bp, raw);
        backup_path = bp;
        try out.print("Backup written to {s}\n", .{bp});
    }

    // Follow symlinks so a symlinked HISTFILE stays a symlink, and preserve
    // the target's permissions.
    const real = try dir.realPathFileAlloc(io, path, gpa);
    defer gpa.free(real);
    const stat = try dir.statFile(io, real, .{});
    const parent_path = std.fs.path.dirname(real) orelse ".";
    const base = std.fs.path.basename(real);

    var parent = try Io.Dir.cwd().openDir(io, parent_path, .{});
    defer parent.close(io);

    const mode: std.posix.mode_t = @backingInt(stat.permissions) & 0o7777;
    var atomic = try parent.createFileAtomic(io, base, .{
        .permissions = @fromBackingInt(@intCast(mode)),
        .replace = true,
    });
    defer atomic.deinit(io);

    var write_buf: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &write_buf);
    for (kept.items) |entry| try writer.interface.writeAll(entry);
    try writer.interface.flush();
    try atomic.replace(io);

    try out.print("Deleted {d} of {d} entries from {s}.\n", .{ matched, entries.len, path });
    try out.writeAll("Note: open shells still hold the old history in memory and may write it back.\n");
    try out.writeAll("Run `fc -R` in each open shell (or restart them) to reload the cleaned file.\n");

    return .{ .total = entries.len, .matched = matched, .backup_path = backup_path };
}

fn probeHistfile(io: Io, gpa: Allocator) !?[]u8 {
    var child = std.process.spawn(io, .{
        .argv = &.{ "zsh", "-ic", "print -r -- \"@@HISTFILE@@$HISTFILE\"" },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch return null;
    defer child.kill(io);

    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(gpa);

    if (child.stdout) |stdout| {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const vecs: [1][]u8 = .{buffer[0..]};
            const n = stdout.readStreaming(io, &vecs) catch break;
            if (n == 0) break;
            try output.appendSlice(gpa, buffer[0..n]);
        }
    }
    _ = child.wait(io) catch {};

    if (extractHistfileMarker(output.items)) |marker| return try gpa.dupe(u8, marker);
    return null;
}

/// `$HISTFILE`, else an interactive zsh's `$HISTFILE`, else `$HOME/.zsh_history`.
/// The returned path is owned by the caller.
pub fn findHistfile(io: Io, gpa: Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("HISTFILE")) |h| {
        if (h.len > 0) return gpa.dupe(u8, h);
    }
    if (try probeHistfile(io, gpa)) |h| return h;
    const home = environ.get("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(gpa, &.{ home, ".zsh_history" });
}

fn printUsage(out: *Io.Writer, program: []const u8) !void {
    try out.print(
        \\Usage: {s} [options] PATTERN
        \\
        \\Delete entries matching PATTERN from zsh history (dry run by default).
        \\
        \\Options:
        \\  -d, --delete          actually delete matching entries
        \\  -F, --fixed-strings   treat PATTERN as a literal string
        \\  -i, --ignore-case     case-insensitive match
        \\  -x, --line-regexp     PATTERN must match the whole command
        \\  -f, --file FILE       history file (default: $HISTFILE or ~/.zsh_history)
        \\      --no-backup       don't write a backup before deleting
        \\  -h, --help            show this help
        \\
    , .{program});
}

fn regexErrorText(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.UnmatchedParen,
        error.UnmatchedBracket,
        error.TrailingBackslash,
        error.NothingToRepeat,
        error.InvalidRepeat,
        error.BadRange,
        error.UnsupportedEscape,
        error.UnsupportedGroup,
        error.PatternTooLarge,
        => regex.formatError(@errorCast(err)),
        else => null,
    };
}

pub fn main(init: std.process.Init) !void {
    mainInner(init) catch std.process.exit(1);
}

fn mainInner(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buf: [4096]u8 = undefined;
    var file_writer = Io.File.stdout().writer(io, &stdout_buf);
    const out = &file_writer.interface;

    const opts = parseArgs(args) catch |err| {
        try out.print("{s}: {s}\n", .{ args[0], formatArgsError(err) });
        try out.flush();
        return error.InvalidArgs;
    };

    if (opts.help) {
        try printUsage(out, args[0]);
        try out.flush();
        return;
    }

    const discovered_path: ?[]u8 = if (opts.file == null) try findHistfile(io, gpa, init.environ_map) else null;
    defer if (discovered_path) |p| gpa.free(p);
    const path = opts.file orelse discovered_path.?;

    // Report an invalid pattern before touching the history file.
    {
        var probe = regex.Regex.compile(gpa, opts.pattern.?, .{
            .case_insensitive = opts.ignore_case,
            .literal = opts.fixed_strings,
            .whole = opts.line_regexp,
        }) catch |err| {
            if (regexErrorText(err)) |text| {
                try out.print("invalid pattern: {s}\n", .{text});
            } else {
                try out.print("zsh-hist: {s}\n", .{@errorName(err)});
            }
            try out.flush();
            return err;
        };
        probe.deinit(gpa);
    }

    const now_ns = Io.Timestamp.now(io, .real).nanoseconds;
    const now_secs: u64 = @intCast(@divTrunc(now_ns, std.time.ns_per_s));

    const summary = run(io, gpa, Io.Dir.cwd(), path, opts, out, now_secs) catch |err| {
        switch (err) {
            HistoryLocked.HistoryLocked => try out.print(
                "Another zsh-hist is already working on {s} (lock file {s}.LOCK exists).\n",
                .{ path, path },
            ),
            error.FileNotFound => try out.print("cannot read {s}: file not found\n", .{path}),
            error.AccessDenied => try out.print("cannot read {s}: permission denied\n", .{path}),
            else => try out.print("zsh-hist: {s}\n", .{@errorName(err)}),
        }
        try out.flush();
        return err;
    };
    defer if (summary.backup_path) |bp| gpa.free(bp);

    try out.flush();
}
