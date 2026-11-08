const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const regex = @import("regex");

const Regex = regex.Regex;
const Node = regex.Node;
const CharSet = regex.CharSet;
const Options = regex.Options;

// ============================================================================
// Helpers
// ============================================================================

fn matches(pattern: []const u8, text: []const u8, options: Options) !bool {
    var re = try Regex.compile(testing.allocator, pattern, options);
    defer re.deinit(testing.allocator);
    return re.isMatch(text);
}

fn expectMatch(pattern: []const u8, text: []const u8) !void {
    try testing.expect(try matches(pattern, text, .{}));
}

fn expectNoMatch(pattern: []const u8, text: []const u8) !void {
    try testing.expect(!try matches(pattern, text, .{}));
}

fn testSeed() u64 {
    if (testing.random_seed != 0) return testing.random_seed;
    return 0x9e3779b97f4a7c15;
}

// ============================================================================
// Example-based tests
// ============================================================================

test "literal matches anywhere" {
    try expectMatch("abc", "xxabcxx");
    try expectMatch("abc", "abc");
    try expectNoMatch("abc", "abx");
    try expectNoMatch("abc", "");
}

test "dot matches any byte except newline" {
    try expectMatch("a.c", "abc");
    try expectMatch("a.c", "a-c");
    try expectNoMatch("a.c", "a\nc");
}

test "string anchors" {
    try expectMatch("^abc$", "abc");
    try expectMatch("^abc", "abcxxx");
    try expectNoMatch("^abc", "xabc");
    try expectMatch("abc$", "xxxabc");
    try expectNoMatch("abc$", "abcx");
    try expectMatch("\\Aabc\\Z", "abc");
}

test "bracket classes, negation and ranges" {
    try expectMatch("[abc]+", "cab");
    try expectMatch("[abc]+", "cad");
    try expectNoMatch("[abc]+", "xyz");
    try expectMatch("[^abc]+", "xyz");
    try expectNoMatch("[^abc]+", "abc");
    try expectMatch("[a-z0-9]+", "abc123");
    try expectNoMatch("[a-z]+", "ABC");
    try expectMatch("[-a]+", "-a-");
    try expectMatch("[a-]+", "a--");
    try expectMatch("[\\]a]+", "]a");
}

test "perl classes" {
    try expectMatch("\\d+", "x123y");
    try expectNoMatch("\\d+", "xyz");
    try expectMatch("\\w+", "a_1");
    try expectNoMatch("\\w+", " - ");
    try expectMatch("\\s+", "a \tb");
    try expectNoMatch("\\s+", "ab");
    try expectMatch("\\D+", "abc");
    try expectNoMatch("\\D+", "123");
    try expectMatch("\\W+", " - ");
    try expectMatch("\\S+", "abc");
    try expectNoMatch("\\S+", "   ");
}

test "word boundaries" {
    try expectMatch("\\bfoo\\b", "a foo b");
    try expectNoMatch("\\bfoo\\b", "afoob");
    try expectMatch("\\Bfoo\\B", "afoob");
    try expectNoMatch("\\Bfoo\\B", "a foo b");
}

test "alternation and groups" {
    try expectMatch("cat|dog", "hotdog");
    try expectMatch("(ab|cd)+", "abcdab");
    try expectNoMatch("(ab|cd)+", "xyz");
    try expectNoMatch("(ab|cd)+", "axe");
    try expectMatch("(?:ab)+", "abab");
    try expectMatch("(a(b(c)))", "abc");
}

test "quantifiers" {
    try expectMatch("ab*c", "ac");
    try expectMatch("ab*c", "abbbc");
    try expectMatch("ab+c", "abc");
    try expectNoMatch("ab+c", "ac");
    try expectMatch("ab?c", "ac");
    try expectMatch("ab?c", "abc");
    try expectNoMatch("ab?c", "abbc");
    try expectMatch("^a{2}$", "aa");
    try expectNoMatch("^a{2}$", "a");
    try expectMatch("^a{2,}$", "aaaa");
    try expectMatch("^a{,2}$", "");
    try expectMatch("^a{,2}$", "aa");
    try expectNoMatch("^a{,2}$", "aaa");
    try expectMatch("^a{2,3}$", "aaa");
    try expectNoMatch("^a{2,3}$", "aaaa");
}

test "lazy quantifiers are accepted" {
    try expectMatch("a+?b", "aaab");
    try expectMatch("^a{1,3}?$", "aa");
}

test "case insensitive folding" {
    try testing.expect(try matches("abc", "ABC", .{ .case_insensitive = true }));
    try testing.expect(try matches("[a-z]+", "ABC", .{ .case_insensitive = true }));
    try testing.expect(!try matches("abc", "ABC", .{}));
}

test "literal option quotes regex metacharacters" {
    const literal = "a.b*c(d)[e]{f}^$|?\\";
    try testing.expect(try matches(literal, "xx" ++ literal ++ "yy", .{ .literal = true }));
    try testing.expect(try matches(literal, literal, .{ .whole = true, .literal = true }));
    try testing.expect(!try matches(literal, "aXb*c(d)[e]{f}^$|?\\", .{ .literal = true }));
}

test "whole option anchors both ends" {
    try testing.expect(try matches("abc", "abc", .{ .whole = true }));
    try testing.expect(!try matches("abc", "xabc", .{ .whole = true }));
    try testing.expect(!try matches("abc", "abcx", .{ .whole = true }));
    try testing.expect(!try matches("abc", "xabcx", .{ .whole = true }));
}

test "empty pattern matches everything" {
    try expectMatch("", "");
    try expectMatch("", "anything at all");
    try testing.expect(try matches("", "", .{ .whole = true }));
    try testing.expect(!try matches("", "x", .{ .whole = true }));
}

test "escape produces a literal pattern" {
    const samples = [_][]const u8{
        "",
        "plain",
        "a.b*c(d)[e]{f}^$|?\\",
        "line\nbreak",
        "\xff\x83",
    };
    for (samples) |s| {
        const pattern = try regex.escape(testing.allocator, s);
        defer testing.allocator.free(pattern);
        try testing.expect(try matches(pattern, s, .{ .whole = true }));
    }
}

test "error values and messages" {
    const cases = [_]struct { pattern: []const u8, expected: regex.Error, text: []const u8 }{
        .{ .pattern = "(", .expected = error.UnmatchedParen, .text = "unmatched ')'" },
        .{ .pattern = "a)", .expected = error.UnmatchedParen, .text = "unmatched ')'" },
        .{ .pattern = "[a", .expected = error.UnmatchedBracket, .text = "unmatched '['" },
        .{ .pattern = "\\", .expected = error.TrailingBackslash, .text = "trailing backslash" },
        .{ .pattern = "*a", .expected = error.NothingToRepeat, .text = "nothing to repeat" },
        .{ .pattern = "a{3,2}", .expected = error.InvalidRepeat, .text = "invalid repetition count" },
        .{ .pattern = "a{1001}", .expected = error.InvalidRepeat, .text = "invalid repetition count" },
        .{ .pattern = "[z-a]", .expected = error.BadRange, .text = "invalid character range" },
        .{ .pattern = "\\q", .expected = error.UnsupportedEscape, .text = "unsupported escape sequence" },
        .{ .pattern = "(?i)a", .expected = error.UnsupportedGroup, .text = "unsupported group syntax" },
    };
    for (cases) |case| {
        try testing.expectError(case.expected, Regex.compile(testing.allocator, case.pattern, .{}));
        try testing.expectEqualStrings(case.text, regex.formatError(case.expected));
    }
}

test "pattern too large" {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(testing.allocator);
    var i: usize = 0;
    while (i < 60_000) : (i += 1) try pattern.appendSlice(testing.allocator, "a*");
    try testing.expectError(error.PatternTooLarge, Regex.compile(testing.allocator, pattern.items, .{}));
}

// ============================================================================
// Generative tests
// ============================================================================

const alphabet = [_]u8{ 'a', 'b', '-', '.', '\n' };

const Gen = struct {
    rng: std.Random,
    arena: std.mem.Allocator,
    allow_assertions: bool,

    fn newNode(self: *Gen, value: Node) !*Node {
        const n = try self.arena.create(Node);
        n.* = value;
        return n;
    }

    fn leaf(self: *Gen) !*Node {
        var choices: usize = 3;
        if (self.allow_assertions) choices = 4;
        switch (self.rng.uintLessThan(usize, choices)) {
            0 => return self.newNode(.{ .byte = alphabet[self.rng.uintLessThan(usize, alphabet.len)] }),
            1 => return self.newNode(.any),
            2 => {
                var set = CharSet.empty;
                for (alphabet) |b| {
                    if (self.rng.boolean()) set.set(b);
                }
                if (set.eql(CharSet.empty)) set.set(alphabet[0]);
                return self.newNode(.{ .set = set });
            },
            else => {
                const a: regex.Assert = switch (self.rng.uintLessThan(u8, 4)) {
                    0 => .bol,
                    1 => .eol,
                    2 => .word,
                    else => .not_word,
                };
                return self.newNode(.{ .assertion = a });
            },
        }
    }

    fn term(self: *Gen, depth: usize) !*Node {
        if (depth == 0) return self.leaf();
        if (self.rng.uintLessThan(u8, 3) == 0) {
            const min = self.rng.uintLessThan(u32, 4);
            const max: ?u32 = switch (self.rng.uintLessThan(u8, 3)) {
                0 => null,
                1 => min,
                else => min + self.rng.uintLessThan(u32, 3),
            };
            return self.newNode(.{ .repeat = .{
                .node = try self.term(depth - 1),
                .min = min,
                .max = max,
            } });
        }
        return self.leaf();
    }

    fn node(self: *Gen, depth: usize) !*Node {
        if (depth == 0) return self.leaf();
        switch (self.rng.uintLessThan(u8, 4)) {
            0 => return self.term(depth),
            1 => return self.leaf(),
            else => {
                const n: usize = 2 + self.rng.uintLessThan(usize, 2);
                const children = try self.arena.alloc(*Node, n);
                for (children) |*child| child.* = try self.term(depth - 1);
                const tag = self.rng.boolean();
                return self.newNode(if (tag) .{ .cat = children } else .{ .alt = children });
            },
        }
    }
};

fn randomText(allocator: std.mem.Allocator, rng: std.Random, max_len: usize) ![]u8 {
    const len = rng.uintLessThan(usize, max_len + 1);
    const text = try allocator.alloc(u8, len);
    for (text) |*b| {
        if (rng.uintLessThan(u8, 8) == 0) {
            b.* = rng.int(u8);
        } else {
            b.* = alphabet[rng.uintLessThan(usize, alphabet.len)];
        }
    }
    return text;
}

fn printNode(w: *std.ArrayList(u8), gpa: std.mem.Allocator, node: *const Node) !void {
    try printPrec(w, gpa, node, 0);
}

const Prec = struct {
    const alt = 1;
    const cat = 2;
    const repeat = 3;
    const atom = 4;
};

fn printPrec(w: *std.ArrayList(u8), gpa: std.mem.Allocator, node: *const Node, parent: u8) !void {
    const my_prec: u8 = switch (node.*) {
        .alt => Prec.alt,
        .cat => Prec.cat,
        .repeat => Prec.repeat,
        else => Prec.atom,
    };
    const wrap = my_prec < parent;
    if (wrap) try w.append(gpa, '(');
    switch (node.*) {
        .empty => try w.appendSlice(gpa, "(?:)"),
        .byte => |b| try printByte(w, gpa, b),
        .any => try w.append(gpa, '.'),
        .set => |set| try printSet(w, gpa, set),
        .assertion => |a| try w.appendSlice(gpa, switch (a) {
            .bol => "^",
            .eol => "$",
            .word => "\\b",
            .not_word => "\\B",
        }),
        .cat => |children| {
            for (children) |child| try printPrec(w, gpa, child, Prec.cat);
        },
        .alt => |children| {
            for (children, 0..) |child, i| {
                if (i != 0) try w.append(gpa, '|');
                try printPrec(w, gpa, child, Prec.alt);
            }
        },
        .repeat => |r| {
            try printPrec(w, gpa, r.node, Prec.atom);
            if (r.max) |max| {
                if (max == r.min) {
                    try w.print(gpa, "{{{d}}}", .{r.min});
                } else {
                    try w.print(gpa, "{{{d},{d}}}", .{ r.min, max });
                }
            } else if (r.min == 0) {
                try w.append(gpa, '*');
            } else if (r.min == 1) {
                try w.append(gpa, '+');
            } else {
                try w.print(gpa, "{{{d},}}", .{r.min});
            }
        },
    }
    if (wrap) try w.append(gpa, ')');
}

fn printByte(w: *std.ArrayList(u8), gpa: std.mem.Allocator, b: u8) !void {
    switch (b) {
        '\n' => try w.appendSlice(gpa, "\\n"),
        '\t' => try w.appendSlice(gpa, "\\t"),
        '\r' => try w.appendSlice(gpa, "\\r"),
        else => {
            if (mem.indexOfScalar(u8, "\\^$.|?*+()[]{}", b) != null) try w.append(gpa, '\\');
            try w.append(gpa, b);
        },
    }
}

fn printSet(w: *std.ArrayList(u8), gpa: std.mem.Allocator, set: CharSet) !void {
    try w.append(gpa, '[');
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if (!set.isSet(i)) continue;
        const b: u8 = @intCast(i);
        switch (b) {
            '\n' => try w.appendSlice(gpa, "\\n"),
            '\t' => try w.appendSlice(gpa, "\\t"),
            '\r' => try w.appendSlice(gpa, "\\r"),
            '\\', ']', '^', '-' => {
                try w.append(gpa, '\\');
                try w.append(gpa, b);
            },
            else => try w.append(gpa, b),
        }
    }
    try w.append(gpa, ']');
}

fn nodeEql(a: *const Node, b: *const Node) bool {
    if (std.meta.activeTag(a.*) != std.meta.activeTag(b.*)) return false;
    return switch (a.*) {
        .empty => true,
        .byte => |x| x == b.byte,
        .any => true,
        .set => |x| x.eql(b.set),
        .assertion => |x| x == b.assertion,
        .cat => |x| childrenEql(x, b.cat),
        .alt => |x| childrenEql(x, b.alt),
        .repeat => |x| x.min == b.repeat.min and x.max == b.repeat.max and nodeEql(x.node, b.repeat.node),
    };
}

fn childrenEql(a: []*Node, b: []*Node) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!nodeEql(x, y)) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Reference matcher: denotational semantics over the AST
// ---------------------------------------------------------------------------

fn refEnds(node: *const Node, text: []const u8, start: usize) u64 {
    const len = text.len;
    return switch (node.*) {
        .empty => bit(start),
        .byte => |b| if (start < len and text[start] == b) bit(start + 1) else 0,
        .any => if (start < len and text[start] != '\n') bit(start + 1) else 0,
        .set => |set| if (start < len and set.isSet(text[start])) bit(start + 1) else 0,
        .assertion => |a| if (refHolds(a, start, text)) bit(start) else 0,
        .cat => |children| {
            var current = bit(start);
            for (children) |child| current = refStep(child, text, current);
            return current;
        },
        .alt => |children| {
            var result: u64 = 0;
            for (children) |child| result |= refEnds(child, text, start);
            return result;
        },
        .repeat => |r| refRepeat(r.node, text, start, r.min, r.max),
    };
}

fn bit(pos: usize) u64 {
    return @as(u64, 1) << @intCast(pos & 63);
}

fn refStep(node: *const Node, text: []const u8, set: u64) u64 {
    var result: u64 = 0;
    var i: usize = 0;
    while (i <= text.len) : (i += 1) {
        if (set & bit(i) != 0) result |= refEnds(node, text, i);
    }
    return result;
}

fn refRepeat(node: *const Node, text: []const u8, start: usize, min: u32, max: ?u32) u64 {
    var current = bit(start);
    var count: u32 = 0;
    while (count < min) : (count += 1) {
        current = refStep(node, text, current);
        if (current == 0) return 0;
    }
    if (max) |m| {
        var result = current;
        var c = min;
        while (c < m) : (c += 1) {
            current = refStep(node, text, current);
            if (current == 0) break;
            result |= current;
        }
        return result;
    }
    var result = current;
    var frontier = current;
    while (frontier != 0) {
        const next = refStep(node, text, frontier) & ~result;
        if (next == 0) break;
        result |= next;
        frontier = next;
    }
    return result;
}

fn refHolds(a: regex.Assert, pos: usize, text: []const u8) bool {
    const len = text.len;
    return switch (a) {
        .bol => pos == 0,
        .eol => pos == len,
        .word, .not_word => blk: {
            const prev = pos > 0 and isWord(text[pos - 1]);
            const next = pos < len and isWord(text[pos]);
            break :blk if (a == .word) prev != next else prev == next;
        },
    };
}

fn isWord(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn refSearch(node: *const Node, text: []const u8, whole: bool) bool {
    if (whole) return refEnds(node, text, 0) & bit(text.len) != 0;
    var start: usize = 0;
    while (start <= text.len) : (start += 1) {
        if (refEnds(node, text, start) != 0) return true;
    }
    return false;
}

fn sample(node: *const Node, rng: std.Random, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
    switch (node.*) {
        .empty, .assertion => {},
        .byte => |b| try out.append(gpa, b),
        .any => try out.append(gpa, 'a'),
        .set => |set| {
            var i: usize = 0;
            while (i < 256) : (i += 1) {
                if (set.isSet(i)) {
                    try out.append(gpa, @intCast(i));
                    break;
                }
            }
        },
        .cat => |children| for (children) |child| try sample(child, rng, out, gpa),
        .alt => |children| try sample(children[rng.uintLessThan(usize, children.len)], rng, out, gpa),
        .repeat => |r| {
            const extra: u32 = if (r.max) |max| blk: {
                const span = max - r.min;
                break :blk if (span == 0) 0 else rng.uintLessThan(u32, @min(span, 3) + 1);
            } else rng.uintLessThan(u32, 3);
            const count = r.min + extra;
            var i: u32 = 0;
            while (i < count) : (i += 1) try sample(r.node, rng, out, gpa);
        },
    }
}

test "generative: reference equivalence" {
    const seed = testSeed();
    errdefer std.debug.print("regex generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var gen = Gen{ .rng = rng, .arena = arena, .allow_assertions = true };
        const ast = try gen.node(3);

        var pattern: std.ArrayList(u8) = .empty;
        try printNode(&pattern, arena, ast);

        const text = try randomText(arena, rng, 10);
        const got = try matches(pattern.items, text, .{});
        const want = refSearch(ast, text, false);
        if (got != want) {
            std.debug.print("pattern={s} text={any} got={} want={}\n", .{ pattern.items, text, got, want });
            return error.TestUnexpectedResult;
        }

        const got_whole = try matches(pattern.items, text, .{ .whole = true });
        const want_whole = refSearch(ast, text, true);
        if (got_whole != want_whole) {
            std.debug.print("whole pattern={s} text={any} got={} want={}\n", .{ pattern.items, text, got_whole, want_whole });
            return error.TestUnexpectedResult;
        }
    }
}

test "generative: parse round-trip" {
    const seed = testSeed();
    errdefer std.debug.print("regex generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var gen = Gen{ .rng = rng, .arena = arena, .allow_assertions = true };
        const ast = try gen.node(3);

        var pattern: std.ArrayList(u8) = .empty;
        try printNode(&pattern, arena, ast);

        const reparsed = try regex.parse(arena, pattern.items);
        if (!nodeEql(ast, reparsed)) {
            std.debug.print("pattern={s}\n", .{pattern.items});
            return error.TestUnexpectedResult;
        }
    }
}

test "generative: generated members match" {
    const seed = testSeed();
    errdefer std.debug.print("regex generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var gen = Gen{ .rng = rng, .arena = arena, .allow_assertions = false };
        const ast = try gen.node(3);

        var pattern: std.ArrayList(u8) = .empty;
        try printNode(&pattern, arena, ast);

        var member: std.ArrayList(u8) = .empty;
        try sample(ast, rng, &member, arena);

        const got = try matches(pattern.items, member.items, .{ .whole = true });
        if (!got) {
            std.debug.print("pattern={s} member={any}\n", .{ pattern.items, member.items });
            return error.TestUnexpectedResult;
        }
    }
}

test "generative: escape and literal" {
    const seed = testSeed();
    errdefer std.debug.print("regex generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var buf: [12]u8 = undefined;
        const len = rng.uintLessThan(usize, buf.len + 1);
        const s = buf[0..len];
        for (s) |*b| b.* = rng.int(u8);

        const escaped = try regex.escape(testing.allocator, s);
        defer testing.allocator.free(escaped);
        try testing.expect(try matches(escaped, s, .{ .whole = true }));
        try testing.expect(try matches(s, s, .{ .whole = true, .literal = true }));

        if (len > 0) {
            var changed = try testing.allocator.dupe(u8, s);
            defer testing.allocator.free(changed);
            const idx = rng.uintLessThan(usize, changed.len);
            var replacement = rng.int(u8);
            if (std.ascii.isAlphabetic(replacement)) replacement = '!';
            if (replacement == changed[idx]) replacement +%= 1;
            changed[idx] = replacement;
            try testing.expect(!try matches(escaped, changed, .{ .whole = true }));
            try testing.expect(!try matches(s, changed, .{ .whole = true, .literal = true }));
        }
    }
}

fn swapAsciiCase(text: []u8) void {
    for (text) |*b| {
        if (std.ascii.isLower(b.*)) {
            b.* = std.ascii.toUpper(b.*);
        } else if (std.ascii.isUpper(b.*)) {
            b.* = std.ascii.toLower(b.*);
        }
    }
}

test "generative: case folding" {
    const seed = testSeed();
    errdefer std.debug.print("regex generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var gen = Gen{ .rng = rng, .arena = arena, .allow_assertions = true };
        const ast = try gen.node(3);

        var pattern: std.ArrayList(u8) = .empty;
        try printNode(&pattern, arena, ast);

        const text = try randomText(arena, rng, 10);
        const swapped = try arena.dupe(u8, text);
        swapAsciiCase(swapped);

        var re = try Regex.compile(arena, pattern.items, .{ .case_insensitive = true });
        defer re.deinit(arena);
        try testing.expectEqual(re.isMatch(swapped), re.isMatch(text));
    }
}

test "generative: search is a substring match" {
    const seed = testSeed();
    errdefer std.debug.print("regex generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();
        var gen = Gen{ .rng = rng, .arena = arena, .allow_assertions = false };
        const ast = try gen.node(2);

        var pattern: std.ArrayList(u8) = .empty;
        try printNode(&pattern, arena, ast);

        const text = try randomText(arena, rng, 8);

        var search_re = try Regex.compile(arena, pattern.items, .{});
        defer search_re.deinit(arena);
        const search = search_re.isMatch(text);

        var whole_re = try Regex.compile(arena, pattern.items, .{ .whole = true });
        defer whole_re.deinit(arena);

        var any_substring = false;
        var start: usize = 0;
        while (start <= text.len and !any_substring) : (start += 1) {
            var end = start;
            while (end <= text.len) : (end += 1) {
                if (whole_re.isMatch(text[start..end])) {
                    any_substring = true;
                    break;
                }
            }
        }

        if (search != any_substring) {
            std.debug.print("pattern={s} text={any} search={} substring={}\n", .{ pattern.items, text, search, any_substring });
            return error.TestUnexpectedResult;
        }
    }
}

test "generative: arbitrary input does not crash" {
    const seed = testSeed();
    errdefer std.debug.print("regex generative seed: {d}\n", .{seed});
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        var pattern_buf: [24]u8 = undefined;
        const plen = rng.uintLessThan(usize, pattern_buf.len + 1);
        for (pattern_buf[0..plen]) |*b| b.* = rng.int(u8);

        const flags = rng.int(u8);
        const options = Options{
            .case_insensitive = flags & 1 != 0,
            .literal = flags & 2 != 0,
            .whole = flags & 4 != 0,
        };

        var text_buf: [24]u8 = undefined;
        const tlen = rng.uintLessThan(usize, text_buf.len + 1);
        for (text_buf[0..tlen]) |*b| b.* = rng.int(u8);

        var re = Regex.compile(testing.allocator, pattern_buf[0..plen], options) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => continue,
        };
        defer re.deinit(testing.allocator);
        _ = re.isMatch(text_buf[0..tlen]);
    }
}

test "linear-time pathological patterns" {
    {
        var re = try Regex.compile(testing.allocator, "(a?){30}a{30}", .{});
        defer re.deinit(testing.allocator);
        const text: [30]u8 = @splat('a');
        _ = re.isMatch(&text);
        try testing.expect(re.steps < 1_000_000);
    }
    {
        const text: [5000]u8 = @splat('a');
        const patterns = [_][]const u8{ "(a*)*b", "(a|a)*b" };
        for (patterns) |pattern| {
            var re = try Regex.compile(testing.allocator, pattern, .{});
            defer re.deinit(testing.allocator);
            _ = re.isMatch(&text);
            try testing.expect(re.steps < 5_000_000);
        }
    }
}

// ============================================================================
// Fuzz entry point
// ============================================================================

fn fuzzOne(_: void, smith: *testing.Smith) anyerror!void {
    var pattern_buf: [48]u8 = undefined;
    const plen: usize = smith.valueRangeAtMostWithHash(u32, 0, pattern_buf.len, 0x1111);
    smith.bytesWithHash(pattern_buf[0..plen], 0x2222);

    const flags = smith.valueWithHash(u8, 0x3333);
    const options = Options{
        .case_insensitive = flags & 1 != 0,
        .literal = flags & 2 != 0,
        .whole = flags & 4 != 0,
    };

    var text_buf: [64]u8 = undefined;
    const tlen: usize = smith.valueRangeAtMostWithHash(u32, 0, text_buf.len, 0x4444);
    smith.bytesWithHash(text_buf[0..tlen], 0x5555);

    var re = Regex.compile(testing.allocator, pattern_buf[0..plen], options) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return,
    };
    defer re.deinit(testing.allocator);
    _ = re.isMatch(text_buf[0..tlen]);
}

test "fuzz regex" {
    try testing.fuzz({}, fuzzOne, .{ .corpus = &.{
        "",
        "a",
        "(",
        "[",
        "\\",
        "a{2,3}",
        "(a|b)*",
        "[^a-z]+",
        "\\bfoo\\b",
    } });
}
