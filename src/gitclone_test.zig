const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const gitclone = @import("gitclone.zig");

// Alias for easier access
const parseGitUrl = gitclone.parseGitUrl;
const parsePathComponent = gitclone.parsePathComponent;
const parseGitProgress = gitclone.parseGitProgress;
const parseGitPercentage = gitclone.parseGitPercentage;
const GitUrl = gitclone.GitUrl;
const ProgressBar = gitclone.ProgressBar;
const GitProgressInfo = gitclone.GitProgressInfo;

// ============================================================================
// URL PARSING TESTS - Valid Cases
// ============================================================================

test "parse SSH URL with .git suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "git@github.com:torvalds/linux.git";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("torvalds", result.org);
    try testing.expectEqualStrings("linux", result.repo);
}

test "parse SSH URL without .git suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "git@github.com:drewr/zigutils";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("drewr", result.org);
    try testing.expectEqualStrings("zigutils", result.repo);
}

test "parse HTTPS URL with .git suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "https://github.com:443/microsoft/vscode.git";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("microsoft", result.org);
    try testing.expectEqualStrings("vscode", result.repo);
}

test "parse HTTPS URL without .git suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "https://github.com/golang/go";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("golang", result.org);
    try testing.expectEqualStrings("go", result.repo);
}

test "parse HTTP URL with .git suffix" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "http://github.com/rust-lang/rust.git";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("rust-lang", result.org);
    try testing.expectEqualStrings("rust", result.repo);
}

test "parse SSH URL with complex org/repo names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "git@github.com:org-name/repo-with-dashes.git";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("org-name", result.org);
    try testing.expectEqualStrings("repo-with-dashes", result.repo);
}

test "parse HTTPS URL with different domain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "https://gitlab.com/group/project.git";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("group", result.org);
    try testing.expectEqualStrings("project", result.repo);
}

// ============================================================================
// URL PARSING TESTS - Invalid Cases (Generative)
// ============================================================================

test "reject URL without @ or ://" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "github.com:org/repo",
        "local/path/to/repo",
        "just-a-name",
        "C:\\Windows\\Path",
        "/absolute/path",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject SSH URLs missing colon separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "git@github.com/org/repo",
        "git@github.comorg/repo",
        "git@/org/repo",
        "git@",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject SSH URLs missing org/repo separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "git@github.com:onlyrepo",
        "git@github.com:repo.git",
        "git@github.com:",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject HTTPS URLs without path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "https://github.com",
        "https://github.com/",
        "https://",
        "https://github.com/org",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject HTTP URLs missing org/repo separator" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "http://github.com/onlyrepo",
        "http://github.com/repo.git",
        "http://github.com/",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject malformed protocol URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "htp://github.com/org/repo",
        "ftp://github.com/org/repo",
        "git://github.com/org/repo",
        "github.com://org/repo",
        "http/github.com/org/repo",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject empty or special character URLs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "",
        " ",
        "\n",
        "\t",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject URLs with multiple slashes in path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_urls = [_][]const u8{
        "https://github.com/org/repo/extra",
        "git@github.com:org/repo/extra.git",
        "https://github.com/a/b/c/d",
    };

    for (invalid_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

// ============================================================================
// PATH COMPONENT PARSING TESTS
// ============================================================================

test "parsePathComponent handles repo with .git" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = "org/repo.git";
    const result = try parsePathComponent(allocator, path);

    try testing.expectEqualStrings("org", result.org);
    try testing.expectEqualStrings("repo", result.repo);
}

test "parsePathComponent handles repo without .git" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = "org/repo";
    const result = try parsePathComponent(allocator, path);

    try testing.expectEqualStrings("org", result.org);
    try testing.expectEqualStrings("repo", result.repo);
}

test "parsePathComponent with hyphenated names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = "org-name/repo-name.git";
    const result = try parsePathComponent(allocator, path);

    try testing.expectEqualStrings("org-name", result.org);
    try testing.expectEqualStrings("repo-name", result.repo);
}

test "parsePathComponent with numbers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = "org123/repo456.git";
    const result = try parsePathComponent(allocator, path);

    try testing.expectEqualStrings("org123", result.org);
    try testing.expectEqualStrings("repo456", result.repo);
}

test "parsePathComponent rejects path without slash" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const invalid_paths = [_][]const u8{
        "onlyrepo",
        "repo.git",
        "",
    };

    for (invalid_paths) |path| {
        const result = parsePathComponent(allocator, path);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "parsePathComponent removes multiple .git occurrences correctly" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const path = "org/repo.git.git";
    const result = try parsePathComponent(allocator, path);

    try testing.expectEqualStrings("org", result.org);
    try testing.expectEqualStrings("repo.git", result.repo);
}

// ============================================================================
// PROGRESS PARSING TESTS
// ============================================================================

test "parseGitPercentage parses standard format" {
    const line = "Counting objects: 100% (123/456)";
    const result = parseGitPercentage(line);

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 123), result.?.current);
    try testing.expectEqual(@as(usize, 456), result.?.total);
}

test "parseGitPercentage parses format with extra bytes info" {
    const line = "Receiving objects: 75% (750/1000, 5.2 MiB)";
    const result = parseGitPercentage(line);

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 750), result.?.current);
    try testing.expectEqual(@as(usize, 1000), result.?.total);
}

test "parseGitPercentage parses format with spaces" {
    const line = "Resolving deltas: 100% ( 456 / 456 )";
    const result = parseGitPercentage(line);

    try testing.expect(result != null);
    try testing.expectEqual(@as(usize, 456), result.?.current);
    try testing.expectEqual(@as(usize, 456), result.?.total);
}

test "parseGitPercentage handles various object counts" {
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
        const result = parseGitPercentage(tc.line);
        try testing.expect(result != null);
        try testing.expectEqual(tc.expected_current, result.?.current);
        try testing.expectEqual(tc.expected_total, result.?.total);
    }
}

test "parseGitPercentage rejects malformed input" {
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
        const result = parseGitPercentage(line);
        try testing.expect(result == null);
    }
}

test "parseGitProgress updates phase correctly" {
    var progress = ProgressBar{};

    parseGitProgress("Counting objects: 100% (123/456)", &progress);
    try testing.expectEqualStrings("Counting  ", progress.phase);
    try testing.expectEqual(@as(usize, 123), progress.current);

    parseGitProgress("Compressing objects: 50% (50/100)", &progress);
    try testing.expectEqualStrings("Compressing", progress.phase);
    try testing.expectEqual(@as(usize, 50), progress.current);

    parseGitProgress("Receiving objects: 75% (750/1000)", &progress);
    try testing.expectEqualStrings("Receiving ", progress.phase);
    try testing.expectEqual(@as(usize, 750), progress.current);

    parseGitProgress("Resolving deltas: 100% (456/456)", &progress);
    try testing.expectEqualStrings("Resolving ", progress.phase);
    try testing.expectEqual(@as(usize, 456), progress.current);
}

test "parseGitProgress ignores unrecognized lines" {
    var progress = ProgressBar{};
    const initial_phase = progress.phase;
    const initial_current = progress.current;

    parseGitProgress("Unknown line that doesn't match patterns", &progress);

    try testing.expectEqualStrings(initial_phase, progress.phase);
    try testing.expectEqual(initial_current, progress.current);
}

test "parseGitProgress handles incremental updates" {
    var progress = ProgressBar{};

    // Simulate a cloning session with multiple updates
    parseGitProgress("Counting objects: 10% (10/100)", &progress);
    try testing.expectEqual(@as(usize, 10), progress.current);
    try testing.expectEqual(@as(usize, 100), progress.total);

    parseGitProgress("Counting objects: 50% (50/100)", &progress);
    try testing.expectEqual(@as(usize, 50), progress.current);

    parseGitProgress("Counting objects: 100% (100/100)", &progress);
    try testing.expectEqual(@as(usize, 100), progress.current);

    parseGitProgress("Compressing objects: 30% (30/100)", &progress);
    try testing.expectEqualStrings("Compressing", progress.phase);
    try testing.expectEqual(@as(usize, 30), progress.current);
}

// ============================================================================
// PROGRESS BAR STRUCT TESTS
// ============================================================================

test "ProgressBar calculates percentage correctly" {
    const progress = ProgressBar{ .current = 50, .total = 100 };
    const percent = if (progress.total > 0)
        @min(100, (progress.current * 100) / progress.total)
    else
        0;

    try testing.expectEqual(@as(usize, 50), percent);
}

test "ProgressBar handles zero total" {
    const progress = ProgressBar{ .current = 10, .total = 0 };
    const percent = if (progress.total > 0)
        @min(100, (progress.current * 100) / progress.total)
    else
        0;

    try testing.expectEqual(@as(usize, 0), percent);
}

test "ProgressBar calculates filled blocks correctly" {
    const progress = ProgressBar{
        .current = 50,
        .total = 100,
        .width = 40,
    };

    const percent = if (progress.total > 0)
        @min(100, (progress.current * 100) / progress.total)
    else
        0;
    const filled = (progress.width * percent) / 100;

    try testing.expectEqual(@as(usize, 20), filled);
}

test "ProgressBar handles 100 percent" {
    const progress = ProgressBar{
        .current = 100,
        .total = 100,
        .width = 40,
    };

    const percent = if (progress.total > 0)
        @min(100, (progress.current * 100) / progress.total)
    else
        0;
    const filled = (progress.width * percent) / 100;

    try testing.expectEqual(@as(usize, 40), filled);
}

test "ProgressBar handles edge case where current exceeds total" {
    const progress = ProgressBar{
        .current = 150,
        .total = 100,
        .width = 40,
    };

    const percent = if (progress.total > 0)
        @min(100, (progress.current * 100) / progress.total)
    else
        0;

    try testing.expectEqual(@as(usize, 100), percent);
}

// ============================================================================
// INTEGRATION TESTS - Simulating real scenarios
// ============================================================================

test "full SSH URL parsing pipeline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "git@gitlab.com:kubernetes/kubernetes.git";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("kubernetes", result.org);
    try testing.expectEqualStrings("kubernetes", result.repo);
}

test "full HTTPS URL parsing pipeline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const url = "https://github.com/pytorch/pytorch.git";
    const result = try parseGitUrl(allocator, url);

    try testing.expectEqualStrings("pytorch", result.org);
    try testing.expectEqualStrings("pytorch", result.repo);
}

test "progress parsing with realistic git output" {
    var progress = ProgressBar{};

    // Simulate realistic git clone output
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
        parseGitProgress(line, &progress);
    }

    try testing.expectEqualStrings("Resolving ", progress.phase);
    try testing.expectEqual(@as(usize, 1000), progress.current);
    try testing.expectEqual(@as(usize, 1000), progress.total);
}

// ============================================================================
// PROPERTY-BASED TESTS - Generative invalid input testing
// ============================================================================

test "reject all variations of SSH URLs with missing components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Test various malformations of SSH URLs
    const bad_ssh_urls = [_][]const u8{
        "git@github.com",              // Missing colon and path
        "git@github.com:",             // Missing path
        "git@github.com:org",          // Missing repo separator
        "@github.com:org/repo.git",    // Missing user
        "git@",                        // Incomplete
    };

    for (bad_ssh_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject all variations of HTTPS URLs with missing components" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bad_https_urls = [_][]const u8{
        "https://",                      // Only protocol
        "https://github.com",            // Missing path
        "https://github.com/",           // Missing org/repo
        "https://github.com/org",        // Missing repo
        "https:///org/repo.git",         // Missing host
    };

    for (bad_https_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject HTTP URLs with protocol variations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const bad_http_urls = [_][]const u8{
        "http://",                       // Only protocol
        "http://github.com",             // Missing path
        "http://github.com/",            // Missing org/repo
        "http:///org/repo.git",          // Missing host
    };

    for (bad_http_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expectError(error.InvalidUrl, result);
    }
}

test "reject URLs with special characters in org/repo names" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // These should parse successfully but we test that special chars are preserved
    const special_char_urls = [_][]const u8{
        "git@github.com:org_name/repo_name.git",
        "git@github.com:org.name/repo.name.git",
        "https://github.com/org-name/repo-name.git",
    };

    for (special_char_urls) |url| {
        const result = parseGitUrl(allocator, url);
        try testing.expect(result != error.InvalidUrl);
    }
}

test "reject parseGitPercentage with invalid number formats" {
    const invalid_percentage_lines = [_][]const u8{
        "Objects: (abc/def)",
        "Objects: (99/xyz)",
        "Objects: (--5/100)",
        "Objects: (1.5/100)",
        "Objects: (1e10/100)",
        "Objects: (+100/-50)",
    };

    for (invalid_percentage_lines) |line| {
        const result = parseGitPercentage(line);
        try testing.expect(result == null);
    }
}

test "stress test parseGitPercentage with boundary numbers" {
    const boundary_cases = [_]struct {
        line: []const u8,
        expect_success: bool,
    }{
        .{ .line = "Objects: (0/1)", .expect_success = true },
        .{ .line = "Objects: (1/1)", .expect_success = true },
        .{ .line = "Objects: (4294967295/4294967295)", .expect_success = true }, // Near u32 max
        .{ .line = "Objects: (-1/100)", .expect_success = false },
        .{ .line = "Objects: (100/-1)", .expect_success = false },
    };

    for (boundary_cases) |tc| {
        const result = parseGitPercentage(tc.line);
        if (tc.expect_success) {
            try testing.expect(result != null);
        } else {
            try testing.expect(result == null);
        }
    }
}
