const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Io = std.Io;
const zsh = @import("zsh-hist.zig");

const Options = zsh.Options;

// ============================================================================
// History parsing
// ============================================================================

test "splitEntries: plain entries" {
    const raw = "ls\ngit status\necho hi\n";
    const entries = try zsh.splitEntries(testing.allocator, raw);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 3), entries.len);
    try testing.expectEqualStrings("ls\n", entries[0]);
    try testing.expectEqualStrings("git status\n", entries[1]);
    try testing.expectEqualStrings("echo hi\n", entries[2]);
}

test "splitEntries: no trailing newline" {
    const raw = "ls\ngit status";
    const entries = try zsh.splitEntries(testing.allocator, raw);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("git status", entries[1]);
}

test "splitEntries: empty file" {
    const entries = try zsh.splitEntries(testing.allocator, "");
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "splitEntries: multi-line entries" {
    const raw = "echo one \\\ntwo\nls\n";
    const entries = try zsh.splitEntries(testing.allocator, raw);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("echo one \\\ntwo\n", entries[0]);
    try testing.expectEqualStrings("ls\n", entries[1]);
}

test "splitEntries: continuation at EOF is kept" {
    const raw = "echo one \\\ntwo";
    const entries = try zsh.splitEntries(testing.allocator, raw);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("echo one \\\ntwo", entries[0]);
}

test "splitEntries: splits on newline only" {
    const raw = "a\r\nb\r\n";
    const entries = try zsh.splitEntries(testing.allocator, raw);
    defer testing.allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("a\r\n", entries[0]);
    try testing.expectEqualStrings("b\r\n", entries[1]);
}

test "commandText: plain, extended and multi-line" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try testing.expectEqualStrings("ls -l", try zsh.commandText(testing.allocator, &buf, "ls -l\n"));
    try testing.expectEqualStrings("git status", try zsh.commandText(testing.allocator, &buf, ": 1700000000:0;git status\n"));
    try testing.expectEqualStrings("echo one \ntwo", try zsh.commandText(testing.allocator, &buf, "echo one \\\ntwo\n"));
    try testing.expectEqualStrings("plain", try zsh.commandText(testing.allocator, &buf, "plain"));
    try testing.expectEqualStrings("", try zsh.commandText(testing.allocator, &buf, ""));
}

test "commandText: extended prefix needs digits" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqualStrings(": 1:x;cmd", try zsh.commandText(testing.allocator, &buf, ": 1:x;cmd\n"));
    try testing.expectEqualStrings(": ;cmd", try zsh.commandText(testing.allocator, &buf, ": ;cmd\n"));
}

test "commandText: unmetafies non-ASCII and NUL" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    // "é" is C3 A9 in UTF-8; zsh stores it metafied as 83 E3 83 89.
    const e_acute = try zsh.commandText(testing.allocator, &buf, "\x83\xe3\x83\x89\n");
    try testing.expectEqualSlices(u8, "\xc3\xa9", e_acute);

    // A metafied NUL is 83 20.
    const nul = try zsh.commandText(testing.allocator, &buf, "a\x83\x20b\n");
    try testing.expectEqualSlices(u8, "a\x00b", nul);
}

test "commandText: a lone metafied byte at end is dropped" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try testing.expectEqualStrings("a", try zsh.commandText(testing.allocator, &buf, "a\x83"));
}

// ============================================================================
// Command line
// ============================================================================

test "parseArgs: defaults to a dry run" {
    const opts = try zsh.parseArgs(&.{ "zsh-hist", "foo" });
    try testing.expect(!opts.delete);
    try testing.expect(!opts.fixed_strings);
    try testing.expect(!opts.ignore_case);
    try testing.expect(!opts.line_regexp);
    try testing.expect(!opts.no_backup);
    try testing.expectEqualStrings("foo", opts.pattern.?);
}

test "parseArgs: short and long flags" {
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "-d", "foo" })).delete);
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "--delete", "foo" })).delete);
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "-F", "foo" })).fixed_strings);
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "--fixed-strings", "foo" })).fixed_strings);
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "-i", "foo" })).ignore_case);
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "-x", "foo" })).line_regexp);
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "--no-backup", "foo" })).no_backup);
    try testing.expect((try zsh.parseArgs(&.{ "zsh-hist", "-h" })).help);
}

test "parseArgs: combined short flags" {
    const opts = try zsh.parseArgs(&.{ "zsh-hist", "-dix", "foo" });
    try testing.expect(opts.delete);
    try testing.expect(opts.ignore_case);
    try testing.expect(opts.line_regexp);
}

test "parseArgs: file forms" {
    try testing.expectEqualStrings("h", (try zsh.parseArgs(&.{ "zsh-hist", "-f", "h", "foo" })).file.?);
    try testing.expectEqualStrings("h", (try zsh.parseArgs(&.{ "zsh-hist", "-fh", "foo" })).file.?);
    try testing.expectEqualStrings("h", (try zsh.parseArgs(&.{ "zsh-hist", "--file", "h", "foo" })).file.?);
    try testing.expectEqualStrings("h", (try zsh.parseArgs(&.{ "zsh-hist", "--file=h", "foo" })).file.?);
    try testing.expectEqualStrings("h", (try zsh.parseArgs(&.{ "zsh-hist", "-dfh", "foo" })).file.?);
}

test "parseArgs: -- ends option parsing" {
    const opts = try zsh.parseArgs(&.{ "zsh-hist", "--", "-d" });
    try testing.expectEqualStrings("-d", opts.pattern.?);
    try testing.expect(!opts.delete);
}

test "parseArgs: errors" {
    try testing.expectError(error.MissingPattern, zsh.parseArgs(&.{"zsh-hist"}));
    try testing.expectError(error.MissingFileArgument, zsh.parseArgs(&.{ "zsh-hist", "-f" }));
    try testing.expectError(error.MissingFileArgument, zsh.parseArgs(&.{ "zsh-hist", "--file" }));
    try testing.expectError(error.UnknownOption, zsh.parseArgs(&.{ "zsh-hist", "-q", "foo" }));
    try testing.expectError(error.UnknownOption, zsh.parseArgs(&.{ "zsh-hist", "--nope", "foo" }));
    try testing.expectError(error.TooManyArguments, zsh.parseArgs(&.{ "zsh-hist", "a", "b" }));
}

test "extractHistfileMarker" {
    try testing.expectEqualStrings("/home/a/.history", zsh.extractHistfileMarker("noise\n@@HISTFILE@@/home/a/.history\n").?);
    try testing.expectEqualStrings("/home/a/.history", zsh.extractHistfileMarker("@@HISTFILE@@/home/a/.history\r\n").?);
    try testing.expect(zsh.extractHistfileMarker("@@HISTFILE@@\n") == null);
    try testing.expect(zsh.extractHistfileMarker("nothing here\n") == null);
}

test "fmtBackupSuffix" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("20231114-221320", zsh.fmtBackupSuffix(1_700_000_000, &buf));
    try testing.expectEqualStrings("19700101-000000", zsh.fmtBackupSuffix(0, &buf));
}

// ============================================================================
// Generative history tests
// ============================================================================

const command_alphabet = [_]u8{
    'a', 'b', 'c', ' ', '\n', '\\', '0', 0x00, 0x7f, 0x83, 0xa9, 0xff,
};

fn randomCommand(gpa: std.mem.Allocator, rng: std.Random) ![]u8 {
    const len = rng.uintLessThan(usize, 12);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (0..len) |_| {
        try out.append(gpa, command_alphabet[rng.uintLessThan(usize, command_alphabet.len)]);
    }
    // A trailing backslash would merge this entry with the next one, and a
    // leading extended prefix would be stripped on read.
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\\') {
        out.items[out.items.len - 1] = 'x';
    }
    if (out.items.len > 0 and out.items[0] == ':') out.items[0] = 'x';
    return out.toOwnedSlice(gpa);
}

fn serializeEntry(gpa: std.mem.Allocator, out: *std.ArrayList(u8), command: []const u8, extended: bool, ts: u32, dur: u32) !void {
    if (extended) try out.print(gpa, ": {d}:{d};", .{ ts, dur });
    for (command) |b| {
        if (b == '\n') {
            try out.appendSlice(gpa, "\\\n");
        } else if (b == 0 or b >= 0x80) {
            try out.append(gpa, 0x83);
            try out.append(gpa, b ^ 0x20);
        } else {
            try out.append(gpa, b);
        }
    }
    try out.append(gpa, '\n');
}

test "generative: history serialization round-trip" {
    const seed = if (testing.random_seed != 0) testing.random_seed else 0x5eed_1234;
    errdefer std.debug.print("zsh-hist generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 500) : (i += 1) {
        var commands: std.ArrayList([]u8) = .empty;
        defer {
            for (commands.items) |c| testing.allocator.free(c);
            commands.deinit(testing.allocator);
        }
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(testing.allocator);

        const n = 1 + rng.uintLessThan(usize, 8);
        for (0..n) |_| {
            const command = try randomCommand(testing.allocator, rng);
            try commands.append(testing.allocator, command);
            try serializeEntry(testing.allocator, &raw, command, rng.boolean(), rng.int(u32), rng.int(u32));
        }

        const entries = try zsh.splitEntries(testing.allocator, raw.items);
        defer testing.allocator.free(entries);
        try testing.expectEqual(commands.items.len, entries.len);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        for (entries, commands.items) |entry, want| {
            const got = try zsh.commandText(testing.allocator, &buf, entry);
            try testing.expectEqualSlices(u8, want, got);
        }
    }
}

fn writeFile(dir: Io.Dir, path: []const u8, data: []const u8, permissions: Io.File.Permissions) !void {
    const io = testing.io;
    const file = try dir.createFile(io, path, .{ .permissions = permissions });
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

fn readFileAlloc(dir: Io.Dir, path: []const u8) ![]u8 {
    return dir.readFileAlloc(testing.io, path, testing.allocator, .unlimited);
}

fn exists(dir: Io.Dir, path: []const u8) !bool {
    dir.access(testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

test "generative: run --delete keeps exactly the un-matched entries" {
    const seed = if (testing.random_seed != 0) testing.random_seed else 0x5eed_5678;
    errdefer std.debug.print("zsh-hist generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    const io = testing.io;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var i: usize = 0;
    while (i < 20) : (i += 1) {
        var pattern_buf: [4]u8 = undefined;
        const plen = rng.uintLessThan(usize, pattern_buf.len + 1);
        for (pattern_buf[0..plen]) |*b| b.* = "ab01 "[rng.uintLessThan(usize, 5)];
        const pattern = pattern_buf[0..plen];

        var commands: std.ArrayList([]u8) = .empty;
        defer {
            for (commands.items) |c| testing.allocator.free(c);
            commands.deinit(testing.allocator);
        }
        var raw: std.ArrayList(u8) = .empty;
        defer raw.deinit(testing.allocator);

        const n = 1 + rng.uintLessThan(usize, 10);
        for (0..n) |_| {
            const command = try randomCommand(testing.allocator, rng);
            try commands.append(testing.allocator, command);
            try serializeEntry(testing.allocator, &raw, command, rng.boolean(), rng.int(u32), rng.int(u32));
        }

        try writeFile(tmp.dir, "history", raw.items, @fromBackingInt(@intCast(0o600)));

        var out: std.Io.Writer.Allocating = .init(testing.allocator);
        defer out.deinit();

        const opts = Options{
            .delete = true,
            .fixed_strings = true,
            .pattern = pattern,
            .no_backup = true,
        };
        const summary = try zsh.run(io, testing.allocator, tmp.dir, "history", opts, &out.writer, 1_700_000_000);
        defer if (summary.backup_path) |bp| testing.allocator.free(bp);

        var expected_matches: usize = 0;
        for (commands.items) |command| {
            if (mem.indexOf(u8, command, pattern) != null) expected_matches += 1;
        }

        const after = try readFileAlloc(tmp.dir, "history");
        defer testing.allocator.free(after);
        const after_entries = try zsh.splitEntries(testing.allocator, after);
        defer testing.allocator.free(after_entries);

        try testing.expectEqual(commands.items.len - expected_matches, after_entries.len);
        try testing.expectEqual(expected_matches, summary.matched);

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(testing.allocator);
        var kept_index: usize = 0;
        for (commands.items) |command| {
            if (mem.indexOf(u8, command, pattern) != null) continue;
            const text = try zsh.commandText(testing.allocator, &buf, after_entries[kept_index]);
            try testing.expectEqualSlices(u8, command, text);
            kept_index += 1;
        }
    }
}

// ============================================================================
// run() against a temporary directory
// ============================================================================

fn setupHistory(tmp: *testing.TmpDir, data: []const u8) !void {
    try writeFile(tmp.dir, "history", data, @fromBackingInt(@intCast(0o600)));
}

fn expectedBackup(gpa: std.mem.Allocator) ![]u8 {
    var buf: [32]u8 = undefined;
    const suffix = zsh.fmtBackupSuffix(1_700_000_000, &buf);
    return std.fmt.allocPrint(gpa, "history.bak.{s}", .{suffix});
}

test "run: dry run leaves the file byte-identical" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "git status\nls\ngit log\n";
    try setupHistory(&tmp, original);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const summary = try zsh.run(io, testing.allocator, tmp.dir, "history", .{ .pattern = "git" }, &out.writer, 1_700_000_000);
    try testing.expectEqual(@as(usize, 3), summary.total);
    try testing.expectEqual(@as(usize, 2), summary.matched);
    try testing.expect(summary.backup_path == null);

    const after = try readFileAlloc(tmp.dir, "history");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(original, after);

    try testing.expect(mem.indexOf(u8, out.written(), "[dry run] 2 of 3 entries") != null);
    try testing.expect(!try exists(tmp.dir, "history.LOCK"));
}

test "run: delete removes matches, writes a backup and keeps mode 0600" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "git status\nls\ngit log\necho hi\n";
    try setupHistory(&tmp, original);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const summary = try zsh.run(io, testing.allocator, tmp.dir, "history", .{
        .delete = true,
        .pattern = "git",
    }, &out.writer, 1_700_000_000);
    defer if (summary.backup_path) |bp| testing.allocator.free(bp);

    try testing.expectEqual(@as(usize, 2), summary.matched);

    const after = try readFileAlloc(tmp.dir, "history");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings("ls\necho hi\n", after);

    const backup_name = try expectedBackup(testing.allocator);
    defer testing.allocator.free(backup_name);
    try testing.expectEqualStrings(backup_name, summary.backup_path.?);

    const backup = try readFileAlloc(tmp.dir, backup_name);
    defer testing.allocator.free(backup);
    try testing.expectEqualStrings(original, backup);

    const stat = try tmp.dir.statFile(io, "history", .{});
    try testing.expectEqual(@as(std.posix.mode_t, 0o600), @backingInt(stat.permissions) & 0o7777);

    try testing.expect(!try exists(tmp.dir, "history.LOCK"));
    try testing.expect(mem.indexOf(u8, out.written(), "Deleted 2 of 4 entries") != null);
}

test "run: an existing lock returns HistoryLocked and leaves the file alone" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "git status\nls\n";
    try setupHistory(&tmp, original);
    const lock = try tmp.dir.createFile(io, "history.LOCK", .{});
    lock.close(io);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    try testing.expectError(error.HistoryLocked, zsh.run(io, testing.allocator, tmp.dir, "history", .{
        .delete = true,
        .pattern = "git",
    }, &out.writer, 1_700_000_000));

    const after = try readFileAlloc(tmp.dir, "history");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(original, after);
    try testing.expect(try exists(tmp.dir, "history.LOCK"));
}

test "run: no matches means no backup and no change" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "git status\nls\n";
    try setupHistory(&tmp, original);

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const summary = try zsh.run(io, testing.allocator, tmp.dir, "history", .{
        .delete = true,
        .pattern = "zzz",
    }, &out.writer, 1_700_000_000);
    try testing.expectEqual(@as(usize, 0), summary.matched);
    try testing.expect(summary.backup_path == null);

    const backup_name = try expectedBackup(testing.allocator);
    defer testing.allocator.free(backup_name);
    try testing.expect(!try exists(tmp.dir, backup_name));

    const after = try readFileAlloc(tmp.dir, "history");
    defer testing.allocator.free(after);
    try testing.expectEqualStrings(original, after);
    try testing.expect(mem.indexOf(u8, out.written(), "No entries in history match") != null);
}

test "run: a symlinked history file stays a symlink" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const original = "git status\nls\n";
    try writeFile(tmp.dir, "real_history", original, @fromBackingInt(@intCast(0o600)));
    try tmp.dir.symLink(io, "real_history", "link_history", .{});

    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();

    const summary = try zsh.run(io, testing.allocator, tmp.dir, "link_history", .{
        .delete = true,
        .pattern = "git",
        .no_backup = true,
    }, &out.writer, 1_700_000_000);
    try testing.expectEqual(@as(usize, 1), summary.matched);

    var link_buf: [64]u8 = undefined;
    const link_len = try tmp.dir.readLink(io, "link_history", &link_buf);
    try testing.expectEqualStrings("real_history", link_buf[0..link_len]);

    const target = try readFileAlloc(tmp.dir, "real_history");
    defer testing.allocator.free(target);
    try testing.expectEqualStrings("ls\n", target);

    const via_link = try readFileAlloc(tmp.dir, "link_history");
    defer testing.allocator.free(via_link);
    try testing.expectEqualStrings("ls\n", via_link);
}
