const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const gitclone = @import("gitclone.zig");

const parseGitUrl = gitclone.parseGitUrl;
const parsePercentage = gitclone.parsePercentage;
const parseProgressLine = gitclone.parseProgressLine;
const stateToDisplay = gitclone.stateToDisplay;
const ProgressState = gitclone.ProgressState;
const destinationExists = gitclone.destinationExists;

// ============================================================================
// URL PARSING TESTS - Valid Cases
// ============================================================================

test "parse SSH URL with .git suffix" {
    const url = "git@github.com:torvalds/linux.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("torvalds", result.org);
    try testing.expectEqualStrings("linux", result.repo);
}

test "parse SSH URL without .git suffix" {
    const url = "git@github.com:drewr/zigutils";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("drewr", result.org);
    try testing.expectEqualStrings("zigutils", result.repo);
}

test "parse HTTPS URL with .git suffix" {
    const url = "https://github.com:443/microsoft/vscode.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("microsoft", result.org);
    try testing.expectEqualStrings("vscode", result.repo);
}

test "parse HTTPS URL without .git suffix" {
    const url = "https://github.com/golang/go";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("golang", result.org);
    try testing.expectEqualStrings("go", result.repo);
}

test "parse HTTP URL with .git suffix" {
    const url = "http://github.com/rust-lang/rust.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("rust-lang", result.org);
    try testing.expectEqualStrings("rust", result.repo);
}

test "parse SSH URL with complex org/repo names" {
    const url = "git@github.com:org-name/repo-with-dashes.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("org-name", result.org);
    try testing.expectEqualStrings("repo-with-dashes", result.repo);
}

test "parse HTTPS URL with different domain" {
    const url = "https://gitlab.com/group/project.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("group", result.org);
    try testing.expectEqualStrings("project", result.repo);
}

test "parse SSH from custom host" {
    const url = "git@git.sr.ht:user/project.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("user", result.org);
    try testing.expectEqualStrings("project", result.repo);
}

// ============================================================================
// URL PARSING TESTS - Invalid Cases
// ============================================================================

test "reject URL without @ or ://" {
    const invalid_urls = [_][]const u8{
        "github.com:org/repo",
        "local/path/to/repo",
        "just-a-name",
        "C:\\Windows\\Path",
        "/absolute/path",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.NotAGitUrl, parseGitUrl(url));
    }
}

test "reject SSH URLs missing colon separator" {
    const invalid_urls = [_][]const u8{
        "git@github.com/org/repo",
        "git@github.comorg/repo",
        "git@/org/repo",
        "git@",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.MissingColon, parseGitUrl(url));
    }
}

test "reject SSH URLs missing org/repo separator" {
    const invalid_urls = [_][]const u8{
        "git@github.com:onlyrepo",
        "git@github.com:repo.git",
        "git@github.com:",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.MissingPath, parseGitUrl(url));
    }
}

test "reject HTTPS URLs without path" {
    const invalid_urls = [_][]const u8{
        "https://github.com",
        "https://github.com/",
        "https://",
        "https://github.com/org",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.MissingPath, parseGitUrl(url));
    }
}

test "reject HTTP URLs missing org/repo separator" {
    const invalid_urls = [_][]const u8{
        "http://github.com/onlyrepo",
        "http://github.com/repo.git",
        "http://github.com/",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.MissingPath, parseGitUrl(url));
    }
}

test "reject malformed protocol URLs" {
    const invalid_urls = [_][]const u8{
        "htp://github.com/org/repo",
        "ftp://github.com/org/repo",
        "git://github.com/org/repo",
        "github.com://org/repo",
        "http/github.com/org/repo",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.NotAGitUrl, parseGitUrl(url));
    }
}

test "reject empty or special character URLs" {
    const invalid_urls = [_][]const u8{
        "",
        " ",
        "\n",
        "\t",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.NotAGitUrl, parseGitUrl(url));
    }
}

test "reject URLs with multiple slashes in path" {
    const invalid_urls = [_][]const u8{
        "https://github.com/org/repo/extra",
        "git@github.com:org/repo/extra.git",
        "https://github.com/a/b/c/d",
    };
    for (invalid_urls) |url| {
        try testing.expectError(error.ExtraSlashes, parseGitUrl(url));
    }
}

test "reject SSH with empty user" {
    try testing.expectError(error.MissingUser, parseGitUrl("@github.com:org/repo.git"));
}

test "reject SSH with empty host" {
    try testing.expectError(error.MissingHostname, parseGitUrl("git@:org/repo.git"));
}

test "reject empty org" {
    try testing.expectError(error.EmptyOrg, parseGitUrl("git@github.com:/repo.git"));
}

test "reject repo named only .git" {
    try testing.expectError(error.EmptyRepo, parseGitUrl("git@github.com:org/.git"));
}

// ============================================================================
// PROGRESS PARSING TESTS
// ============================================================================

test "parsePercentage parses standard format" {
    const line = "Counting objects: 100% (123/456)";
    const result = parsePercentage(line);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 123), result.?.current);
    try testing.expectEqual(@as(usize, 456), result.?.total);
}

test "parsePercentage parses format with extra bytes info" {
    const line = "Receiving objects: 75% (750/1000, 5.2 MiB)";
    const result = parsePercentage(line);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 750), result.?.current);
    try testing.expectEqual(@as(usize, 1000), result.?.total);
}

test "parsePercentage parses format with spaces" {
    const line = "Resolving deltas: 100% ( 456 / 456 )";
    const result = parsePercentage(line);
    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 456), result.?.current);
    try testing.expectEqual(@as(usize, 456), result.?.total);
}

test "parsePercentage handles various object counts" {
    const test_cases = [_]struct {
        line: []const u8,
        expected_current: usize,
        expected_total: usize,
    }{
        .{ .line = "Counting: (1/1)", .expected_current = 1, .expected_total = 1 },
        .{ .line = "Compressing: (0/100)", .expected_current = 0, .expected_total = 100 },
        .{ .line = "Receiving: (9999/10000)", .expected_current = 9999, .expected_total = 10000 },
        .{ .line = "Resolving: (1000000/1000000)", .expected_current = 1000000, .expected_total = 1000000 },
    };
    for (test_cases) |tc| {
        const result = parsePercentage(tc.line);
        try testing.expect(result != null);
        try testing.expectEqual(tc.expected_current, result.?.current);
        try testing.expectEqual(tc.expected_total, result.?.total);
    }
}

test "parsePercentage rejects malformed input" {
    const invalid_lines = [_][]const u8{
        "No parentheses here",
        "Only (one number)",
        "()",
        "(abc/def)",
        "(100/)",
        "(/100)",
        "Missing close (100/200",
        "Missing open 100/200)",
        "",
    };
    for (invalid_lines) |line| {
        try testing.expect(parsePercentage(line) == null);
    }
}

// ============================================================================
// PROGRESS STATE TESTS (pure, no IO)
// ============================================================================

test "parseProgressLine updates phase correctly" {
    var state: ProgressState = .{ .total = 100, .current = 0, .phase = null };

    state = parseProgressLine(state, "Counting objects: 100% (123/456)");
    try testing.expectEqual(@as(?gitclone.Phase, .counting), state.phase);
    try testing.expectEqual(@as(usize, 123), state.current);

    state = parseProgressLine(state, "Compressing objects: 50% (50/100)");
    try testing.expectEqual(@as(?gitclone.Phase, .compressing), state.phase);
    try testing.expectEqual(@as(usize, 50), state.current);

    state = parseProgressLine(state, "Receiving objects: 75% (750/1000)");
    try testing.expectEqual(@as(?gitclone.Phase, .receiving), state.phase);
    try testing.expectEqual(@as(usize, 750), state.current);

    state = parseProgressLine(state, "Resolving deltas: 100% (456/456)");
    try testing.expectEqual(@as(?gitclone.Phase, .resolving), state.phase);
    try testing.expectEqual(@as(usize, 456), state.current);
}

test "parseProgressLine ignores unrecognized lines" {
    const initial: ProgressState = .{ .total = 100, .current = 42, .phase = .counting };
    const result = parseProgressLine(initial, "Unknown line that doesn't match patterns");
    try testing.expectEqual(initial.total, result.total);
    try testing.expectEqual(initial.current, result.current);
    try testing.expectEqual(initial.phase, result.phase);
}

test "parseProgressLine handles incremental updates" {
    var state: ProgressState = .{ .total = 100, .current = 0, .phase = null };

    state = parseProgressLine(state, "Counting objects: 10% (10/100)");
    try testing.expectEqual(@as(usize, 10), state.current);
    try testing.expectEqual(@as(usize, 100), state.total);

    state = parseProgressLine(state, "Counting objects: 50% (50/100)");
    try testing.expectEqual(@as(usize, 50), state.current);

    state = parseProgressLine(state, "Counting objects: 100% (100/100)");
    try testing.expectEqual(@as(usize, 100), state.current);

    state = parseProgressLine(state, "Compressing objects: 30% (30/100)");
    try testing.expectEqual(@as(?gitclone.Phase, .compressing), state.phase);
    try testing.expectEqual(@as(usize, 30), state.current);
}

// ============================================================================
// DISPLAY TESTS (pure)
// ============================================================================

test "stateToDisplay calculates percentage correctly" {
    const state: ProgressState = .{ .current = 50, .total = 100, .phase = null };
    const d = stateToDisplay(state);
    try testing.expectEqual(@as(usize, 50), d.percent);
}

test "stateToDisplay handles zero total" {
    const state: ProgressState = .{ .current = 10, .total = 0, .phase = null };
    const d = stateToDisplay(state);
    try testing.expectEqual(@as(usize, 0), d.percent);
}

test "stateToDisplay calculates filled blocks correctly" {
    const state: ProgressState = .{ .current = 50, .total = 100, .phase = null };
    const d = stateToDisplay(state);
    try testing.expectEqual(@as(usize, 20), d.filled);
}

test "stateToDisplay handles 100 percent" {
    const state: ProgressState = .{ .current = 100, .total = 100, .phase = null };
    const d = stateToDisplay(state);
    try testing.expectEqual(@as(usize, 40), d.filled);
    try testing.expectEqual(@as(usize, 100), d.percent);
}

test "stateToDisplay handles edge case where current exceeds total" {
    const state: ProgressState = .{ .current = 150, .total = 100, .phase = null };
    const d = stateToDisplay(state);
    try testing.expectEqual(@as(usize, 40), d.filled);
    try testing.expectEqual(@as(usize, 100), d.percent);
}

test "stateToDisplay includes phase labels" {
    const state: ProgressState = .{ .current = 50, .total = 100, .phase = .counting };
    const d = stateToDisplay(state);
    try testing.expectEqualStrings("Counting  ", d.phase);
}

// ============================================================================
// INTEGRATION TESTS
// ============================================================================

test "full SSH URL parsing pipeline" {
    const url = "git@gitlab.com:kubernetes/kubernetes.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("kubernetes", result.org);
    try testing.expectEqualStrings("kubernetes", result.repo);
}

test "full HTTPS URL parsing pipeline" {
    const url = "https://github.com/pytorch/pytorch.git";
    const result = try parseGitUrl(url);
    try testing.expectEqualStrings("pytorch", result.org);
    try testing.expectEqualStrings("pytorch", result.repo);
}

test "progress parsing with realistic git output" {
    var state: ProgressState = .{ .total = 100, .current = 0, .phase = null };

    const git_lines = [_][]const u8{
        "Cloning into 'repo'...",
        "Counting objects:  10% (100/1000)\r",
        "Counting objects:  50% (500/1000)\r",
        "Counting objects: 100% (1000/1000)\r",
        "Compressing objects:  20% (200/1000)\r",
        "Compressing objects: 100% (1000/1000)\r",
        "Receiving objects:  30% (300/1000, 2.5 MiB)\r",
        "Receiving objects:  70% (700/1000, 5.2 MiB)\r",
        "Receiving objects: 100% (1000/1000, 8.3 MiB)\r",
        "Resolving deltas:  50% (500/1000)\r",
        "Resolving deltas: 100% (1000/1000)\r",
    };

    for (git_lines) |line| {
        state = parseProgressLine(state, line);
    }

    try testing.expectEqual(@as(?gitclone.Phase, .resolving), state.phase);
    try testing.expectEqual(@as(usize, 1000), state.current);
    try testing.expectEqual(@as(usize, 1000), state.total);
}

test "destinationExists detects existing path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_abs);

    const existing = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_abs, "already-there" });
    defer testing.allocator.free(existing);

    try std.Io.Dir.createDirPath(tmp.dir, testing.io, "already-there");
    try testing.expectEqual(true, try destinationExists(testing.io, existing));
}

test "destinationExists detects missing path" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_abs = try std.Io.Dir.realPathFileAlloc(tmp.dir, testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_abs);

    const missing = try std.fs.path.join(testing.allocator, &[_][]const u8{ tmp_abs, "does-not-exist" });
    defer testing.allocator.free(missing);

    try testing.expectEqual(false, try destinationExists(testing.io, missing));
}

// ============================================================================
// PROPERTY-BASED TESTS
// ============================================================================

test "reject all variations of SSH URLs with missing components" {
    try testing.expectError(error.MissingUser, parseGitUrl("@github.com:org/repo.git"));
    try testing.expectError(error.MissingColon, parseGitUrl("git@github.com"));
    try testing.expectError(error.MissingPath, parseGitUrl("git@github.com:"));
    try testing.expectError(error.MissingPath, parseGitUrl("git@github.com:org"));
    try testing.expectError(error.MissingColon, parseGitUrl("git@"));
}

test "reject all variations of HTTPS URLs with missing components" {
    try testing.expectError(error.MissingHostname, parseGitUrl("https:///org/repo.git"));
    try testing.expectError(error.MissingPath, parseGitUrl("https://"));
    try testing.expectError(error.MissingPath, parseGitUrl("https://github.com"));
    try testing.expectError(error.MissingPath, parseGitUrl("https://github.com/"));
    try testing.expectError(error.MissingPath, parseGitUrl("https://github.com/org"));
}

test "reject HTTP URLs with protocol variations" {
    try testing.expectError(error.MissingHostname, parseGitUrl("http:///org/repo.git"));
    try testing.expectError(error.MissingPath, parseGitUrl("http://"));
    try testing.expectError(error.MissingPath, parseGitUrl("http://github.com"));
    try testing.expectError(error.MissingPath, parseGitUrl("http://github.com/"));
}

test "accept URLs with special characters in org/repo names" {
    const special_char_urls = [_][]const u8{
        "git@github.com:org_name/repo_name.git",
        "git@github.com:org.name/repo.name.git",
        "https://github.com/org-name/repo-name.git",
    };
    for (special_char_urls) |url| {
        const result = parseGitUrl(url);
        try testing.expect(result != error.NotAGitUrl);
    }
}

test "reject parsePercentage with invalid number formats" {
    const invalid_percentage_lines = [_][]const u8{
        "Objects: (abc/def)",
        "Objects: (99/xyz)",
        "Objects: (--5/100)",
        "Objects: (1.5/100)",
        "Objects: (1e10/100)",
        "Objects: (+100/-50)",
    };
    for (invalid_percentage_lines) |line| {
        try testing.expect(parsePercentage(line) == null);
    }
}

test "stress test parsePercentage with boundary numbers" {
    const boundary_cases = [_]struct {
        line: []const u8,
        expect_success: bool,
    }{
        .{ .line = "Objects: (0/1)", .expect_success = true },
        .{ .line = "Objects: (1/1)", .expect_success = true },
        .{ .line = "Objects: (4294967295/4294967295)", .expect_success = true },
        .{ .line = "Objects: (-1/100)", .expect_success = false },
        .{ .line = "Objects: (100/-1)", .expect_success = false },
    };
    for (boundary_cases) |tc| {
        const result = parsePercentage(tc.line);
        if (tc.expect_success) {
            try testing.expect(result != null);
        } else {
            try testing.expect(result == null);
        }
    }
}

// ============================================================================
// EXTRACT PACKAGE TESTS (from nix-zsh-env logic, tested here for completeness)
// ============================================================================

test "extractPackage parses /nix/store paths" {
    const extractPackage = struct {
        fn extract(path: []const u8) ?[]const u8 {
            const prefix = "/nix/store/";
            const rest = if (mem.startsWith(u8, path, prefix)) path[prefix.len..] else return null;
            const dash = mem.indexOfScalar(u8, rest, '-') orelse return null;
            return stripVersion(rest[dash + 1 ..]);
        }
        fn stripVersion(name: []const u8) []const u8 {
            for (name, 0..) |c, i| {
                if (c == '-' and i + 1 < name.len) {
                    const next = name[i + 1];
                    if (next >= '0' and next <= '9') return name[0..i];
                    if (mem.startsWith(u8, name[i + 1 ..], "dev")) return name[0..i];
                }
            }
            return name;
        }
    }.extract;

    try testing.expectEqualStrings("hello", extractPackage("/nix/store/abc123-hello-2.12.1").?);
    try testing.expectEqualStrings("python3", extractPackage("/nix/store/xyz789-python3-3.11").?);
    try testing.expectEqualStrings("openssl", extractPackage("/nix/store/hash-openssl-1.1.1-dev").?);
    try testing.expect(extractPackage("/usr/bin/foo") == null);
    try testing.expect(extractPackage("/nix/store/hash") == null);
}


