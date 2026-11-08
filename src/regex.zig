//! A small, allocation-light regular-expression library for zigutils.
//!
//! The parser builds a small arena-backed AST. Compilation turns it into a
//! Thompson NFA program, and matching simulates that program. Matching is
//! therefore linear in the size of the input for a fixed pattern, with no
//! backtracking blow-up. Only a yes/no answer is produced; there are no
//! capture groups.
//!
//! Supported syntax: literals, `.` (any byte except newline), `^`, `$`, `\A`,
//! `\Z`, alternation, `(...)` and `(?:...)` groups, `* + ? {m} {m,} {,n}
//! {m,n}` (with an optional, ignored lazy `?`), bracket classes with ranges
//! and negation, and the escapes `\d \D \w \W \s \S \b \B \n \t \r \f \v`
//! plus `\` before any punctuation. Patterns match bytes, so UTF-8 literals
//! work as their byte sequences.

const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub const Options = struct {
    case_insensitive: bool = false,
    literal: bool = false,
    whole: bool = false,
};

pub const Error = error{
    UnmatchedParen,
    UnmatchedBracket,
    TrailingBackslash,
    NothingToRepeat,
    InvalidRepeat,
    BadRange,
    UnsupportedEscape,
    UnsupportedGroup,
    PatternTooLarge,
} || Allocator.Error;

pub fn formatError(err: Error) []const u8 {
    return switch (err) {
        error.UnmatchedParen => "unmatched ')'",
        error.UnmatchedBracket => "unmatched '['",
        error.TrailingBackslash => "trailing backslash",
        error.NothingToRepeat => "nothing to repeat",
        error.InvalidRepeat => "invalid repetition count",
        error.BadRange => "invalid character range",
        error.UnsupportedEscape => "unsupported escape sequence",
        error.UnsupportedGroup => "unsupported group syntax",
        error.PatternTooLarge => "pattern is too large",
        error.OutOfMemory => "out of memory",
    };
}

pub const CharSet = std.StaticBitSet(256);

pub const Assert = enum {
    bol,
    eol,
    word,
    not_word,
};

/// The parser's AST. Groups are folded away, so `(a)` and `a` produce the same
/// node. This is exported for tests and tools; most callers should use
/// `Regex`.
pub const Node = union(enum) {
    empty,
    /// A single byte literal.
    byte: u8,
    /// Any byte except `\n`.
    any,
    /// An explicit set of bytes.
    set: CharSet,
    cat: []*Node,
    alt: []*Node,
    repeat: struct {
        node: *Node,
        min: u32,
        max: ?u32,
    },
    assertion: Assert,
};

const ParseError = Error;

const Parser = struct {
    arena: Allocator,
    pattern: []const u8,
    pos: usize = 0,

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.pattern.len) return null;
        return self.pattern[self.pos];
    }

    fn peekAt(self: *Parser, offset: usize) ?u8 {
        const i = self.pos + offset;
        if (i >= self.pattern.len) return null;
        return self.pattern[i];
    }

    fn advance(self: *Parser) void {
        self.pos += 1;
    }

    fn newNode(self: *Parser, node: Node) ParseError!*Node {
        const n = try self.arena.create(Node);
        n.* = node;
        return n;
    }

    fn parseAlt(self: *Parser) ParseError!*Node {
        var branches: std.ArrayList(*Node) = .empty;
        try branches.append(self.arena, try self.parseCat());
        while (self.peek() == @as(u8, '|')) {
            self.advance();
            try branches.append(self.arena, try self.parseCat());
        }
        if (branches.items.len == 1) return branches.items[0];
        return self.newNode(.{ .alt = try branches.toOwnedSlice(self.arena) });
    }

    fn parseCat(self: *Parser) ParseError!*Node {
        var seq: std.ArrayList(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try seq.append(self.arena, try self.parseRepeat());
        }
        if (seq.items.len == 0) return self.newNode(.empty);
        if (seq.items.len == 1) return seq.items[0];
        return self.newNode(.{ .cat = try seq.toOwnedSlice(self.arena) });
    }

    fn parseRepeat(self: *Parser) ParseError!*Node {
        var node = try self.parseAtom();
        const min_max = try self.parseQuantifier() orelse return node;
        // A trailing `?` makes the quantifier lazy. Laziness is irrelevant when
        // the only question is whether the text matches at all.
        if (self.peek() == @as(u8, '?')) self.advance();
        node = try self.newNode(.{ .repeat = .{
            .node = node,
            .min = min_max.min,
            .max = min_max.max,
        } });
        return node;
    }

    const Quantifier = struct { min: u32, max: ?u32 };

    /// Consume a quantifier at the current position, or return null and leave
    /// the position unchanged.
    fn parseQuantifier(self: *Parser) ParseError!?Quantifier {
        const c = self.peek() orelse return null;
        switch (c) {
            '*' => {
                self.advance();
                return .{ .min = 0, .max = null };
            },
            '+' => {
                self.advance();
                return .{ .min = 1, .max = null };
            },
            '?' => {
                self.advance();
                return .{ .min = 0, .max = 1 };
            },
            '{' => {
                const save = self.pos;
                const q = try self.parseBraces();
                if (q == null) self.pos = save;
                return q;
            },
            else => return null,
        }
    }

    /// Parse `{m}`, `{m,}`, `{,n}` or `{m,n}`. Returns null when the braces do
    /// not form a quantifier at all, so the caller can treat `{` as a literal.
    fn parseBraces(self: *Parser) ParseError!?Quantifier {
        std.debug.assert(self.peek() == @as(u8, '{'));
        self.advance();
        if (self.peek() == @as(u8, '}')) return null;

        var min: u32 = 0;
        if (self.peek() != @as(u8, ',')) {
            min = self.parseNumber() orelse return null;
        }

        var max: ?u32 = min;
        if (self.peek() == @as(u8, ',')) {
            self.advance();
            if (self.peek() == @as(u8, '}')) {
                max = null;
            } else {
                max = self.parseNumber() orelse return null;
            }
        }
        if (self.peek() != @as(u8, '}')) return null;
        self.advance();

        if (min > max_repeat or (max orelse 0) > max_repeat) return error.InvalidRepeat;
        if (max) |m| {
            if (m < min) return error.InvalidRepeat;
        }
        return .{ .min = min, .max = max };
    }

    fn parseNumber(self: *Parser) ?u32 {
        var n: u64 = 0;
        var digits: usize = 0;
        while (self.peek()) |c| {
            if (c < '0' or c > '9') break;
            n = n * 10 + (c - '0');
            if (n > 1_000_000) n = 1_000_001;
            digits += 1;
            self.advance();
        }
        if (digits == 0) return null;
        return @intCast(@min(n, 1_000_001));
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        const c = self.peek() orelse return error.UnmatchedParen;
        switch (c) {
            '(' => return self.parseGroup(),
            '[' => return self.parseClass(),
            '.' => {
                self.advance();
                return self.newNode(.any);
            },
            '^' => {
                self.advance();
                return self.newNode(.{ .assertion = .bol });
            },
            '$' => {
                self.advance();
                return self.newNode(.{ .assertion = .eol });
            },
            '\\' => {
                self.advance();
                return self.parseEscape(false);
            },
            '*', '+', '?' => return error.NothingToRepeat,
            '{' => {
                // A brace that is not a valid quantifier is a literal.
                const save = self.pos;
                const q = try self.parseBraces();
                self.pos = save;
                if (q != null) return error.NothingToRepeat;
                self.advance();
                return self.newNode(.{ .byte = '{' });
            },
            ')' => return error.UnmatchedParen,
            else => {
                self.advance();
                return self.newNode(.{ .byte = c });
            },
        }
    }

    fn parseGroup(self: *Parser) ParseError!*Node {
        std.debug.assert(self.peek() == @as(u8, '('));
        self.advance();
        if (self.peek() == @as(u8, '?')) {
            self.advance();
            if (self.peek() != @as(u8, ':')) return error.UnsupportedGroup;
            self.advance();
        }
        const inner = try self.parseAlt();
        if (self.peek() != @as(u8, ')')) return error.UnmatchedParen;
        self.advance();
        return inner;
    }

    fn parseEscape(self: *Parser, in_class: bool) ParseError!*Node {
        const c = self.peek() orelse return error.TrailingBackslash;
        self.advance();

        // Escapes that are always a single byte.
        const byte: ?u8 = switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            else => null,
        };
        if (byte) |b| return self.newNode(.{ .byte = b });

        if (!in_class) {
            const assertion: ?Assert = switch (c) {
                'b' => .word,
                'B' => .not_word,
                'A' => .bol,
                'Z' => .eol,
                else => null,
            };
            if (assertion) |a| return self.newNode(.{ .assertion = a });
        } else if (c == 'b') {
            // Backspace inside a bracket expression.
            return self.newNode(.{ .byte = 0x08 });
        }

        if (className(c)) |set| return self.newNode(.{ .set = set });

        if (isPunctuation(c)) return self.newNode(.{ .byte = c });

        return error.UnsupportedEscape;
    }

    fn parseClass(self: *Parser) ParseError!*Node {
        std.debug.assert(self.peek() == @as(u8, '['));
        self.advance();

        var negated = false;
        if (self.peek() == @as(u8, '^')) {
            negated = true;
            self.advance();
        }

        var set = CharSet.empty;
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.UnmatchedBracket;
            if (c == ']' and !first) {
                self.advance();
                break;
            }
            const was_first = first;
            first = false;

            if (c == '\\') {
                self.advance();
                const item = try self.parseClassEscape();
                switch (item) {
                    .byte => |b| {
                        if (try self.tryClassRange(b)) |range| {
                            addRange(&set, range);
                        } else {
                            set.set(b);
                        }
                    },
                    .set => |s| unionSet(&set, s),
                }
                continue;
            }

            self.advance();
            // A leading `-` is a literal, not the start of a range.
            if (!(was_first and c == '-')) {
                if (try self.tryClassRange(c)) |range| {
                    addRange(&set, range);
                    continue;
                }
            }
            set.set(c);
        }

        if (negated) set.toggleAll();
        return self.newNode(.{ .set = set });
    }

    const ByteOrSet = union(enum) { byte: u8, set: CharSet };

    fn parseClassEscape(self: *Parser) ParseError!ByteOrSet {
        const c = self.peek() orelse return error.TrailingBackslash;
        self.advance();

        const byte: ?u8 = switch (c) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            'f' => 0x0c,
            'v' => 0x0b,
            'b' => 0x08,
            else => null,
        };
        if (byte) |b| return .{ .byte = b };
        if (className(c)) |set| return .{ .set = set };
        if (isPunctuation(c)) return .{ .byte = c };
        return error.UnsupportedEscape;
    }

    const Range = struct { lo: u8, hi: u8 };

    /// If the current position starts a class range (`-x`, where `x` is a
    /// single byte), consume it and return the range.
    fn tryClassRange(self: *Parser, lo: u8) ParseError!?Range {
        if (self.peek() != @as(u8, '-')) return null;
        const next = self.peekAt(1) orelse return null;
        if (next == ']') return null;

        if (next == '\\') {
            // Only single-byte escapes can be a range endpoint.
            const save = self.pos;
            self.advance(); // '-'
            self.advance(); // '\'
            const item = try self.parseClassEscape();
            switch (item) {
                .byte => |hi| {
                    if (hi < lo) return error.BadRange;
                    return .{ .lo = lo, .hi = hi };
                },
                .set => {
                    self.pos = save;
                    return null;
                },
            }
        }

        self.advance(); // '-'
        self.advance(); // endpoint
        if (next < lo) return error.BadRange;
        return .{ .lo = lo, .hi = next };
    }
};

fn addRange(set: *CharSet, range: anytype) void {
    var x = range.lo;
    while (true) : (x += 1) {
        set.set(x);
        if (x == range.hi) break;
    }
}

fn unionSet(dst: *CharSet, src: CharSet) void {
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if (src.isSet(i)) dst.set(i);
    }
}

pub const max_repeat: u32 = 1000;
pub const max_program: usize = 100_000;

fn className(c: u8) ?CharSet {
    var set = CharSet.empty;
    switch (c) {
        'd', 'D' => {
            var b: u8 = '0';
            while (b <= '9') : (b += 1) set.set(b);
            if (c == 'D') set.toggleAll();
        },
        'w', 'W' => {
            var b: u16 = 0;
            while (b < 256) : (b += 1) {
                const x: u8 = @intCast(b);
                if (std.ascii.isAlphanumeric(x) or x == '_') set.set(x);
            }
            if (c == 'W') set.toggleAll();
        },
        's', 'S' => {
            for (" \t\n\r\x0c\x0b") |b| set.set(b);
            if (c == 'S') set.toggleAll();
        },
        else => return null,
    }
    return set;
}

/// Parse `pattern` into an AST allocated from `arena`. Exported for tests and
/// tools; most callers should use `Regex.compile`.
pub fn parse(arena: Allocator, pattern: []const u8) Error!*Node {
    var p = Parser{ .arena = arena, .pattern = pattern };
    const node = try p.parseAlt();
    if (p.peek() != null) return error.UnmatchedParen;
    return node;
}

/// Quote `bytes` so the result can be used as a pattern that matches exactly
/// those bytes.
pub fn escape(allocator: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (bytes) |b| {
        if (mem.indexOfScalar(u8, "\\^$.|?*+()[]{}", b) != null) {
            try out.append(allocator, '\\');
        }
        try out.append(allocator, b);
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Compiler: AST -> Thompson NFA program
// ---------------------------------------------------------------------------

const Inst = union(enum) {
    set: struct { chars: CharSet, out: u32 },
    split: struct { a: u32, b: u32 },
    jmp: u32,
    assertion: struct { kind: Assert, out: u32 },
    match,
};

const Fragment = struct {
    start: u32,
    outs: []u32,
};

const Compiler = struct {
    arena: Allocator,
    prog: *std.ArrayList(Inst),
    max: usize = max_program,

    fn emit(self: *Compiler, inst: Inst) !u32 {
        if (self.prog.items.len >= self.max) return error.PatternTooLarge;
        const pc: u32 = @intCast(self.prog.items.len);
        try self.prog.append(self.arena, inst);
        return pc;
    }

    fn patch(self: *Compiler, outs: []const u32, target: u32) void {
        for (outs) |pc| {
            switch (std.meta.activeTag(self.prog.items[pc])) {
                .jmp => self.prog.items[pc].jmp = target,
                .set => self.prog.items[pc].set.out = target,
                .assertion => self.prog.items[pc].assertion.out = target,
                .split => {
                    const s = &self.prog.items[pc].split;
                    if (s.a == unset) s.a = target else s.b = target;
                },
                else => {},
            }
        }
    }

    fn emptyFrag(self: *Compiler) !Fragment {
        const pc = try self.emit(.{ .jmp = unset });
        return .{ .start = pc, .outs = try self.arena.dupe(u32, &.{pc}) };
    }

    fn one(self: *Compiler) !Fragment {
        const pc = try self.emit(.match);
        return .{ .start = pc, .outs = &.{} };
    }

    fn joinOuts(self: *Compiler, a: []const u32, b: []const u32) ![]u32 {
        const out = try self.arena.alloc(u32, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
    }

    fn compile(self: *Compiler, node: *const Node) Error!Fragment {
        return switch (node.*) {
            .empty => self.emptyFrag(),
            .byte => |b| self.compileSet(byteSet(b)),
            .any => self.compileSet(anySet()),
            .set => |s| self.compileSet(s),
            .assertion => |a| blk: {
                const pc = try self.emit(.{ .assertion = .{ .kind = a, .out = unset } });
                break :blk .{ .start = pc, .outs = try self.arena.dupe(u32, &.{pc}) };
            },
            .cat => |children| self.compileCat(children),
            .alt => |children| self.compileAlt(children),
            .repeat => |r| self.compileRepeat(r.node, r.min, r.max),
        };
    }

    fn compileSet(self: *Compiler, set: CharSet) !Fragment {
        const pc = try self.emit(.{ .set = .{ .chars = set, .out = unset } });
        return .{ .start = pc, .outs = try self.arena.dupe(u32, &.{pc}) };
    }

    fn compileCat(self: *Compiler, children: []*Node) Error!Fragment {
        if (children.len == 0) return self.emptyFrag();
        var frag = try self.compile(children[0]);
        var i: usize = 1;
        while (i < children.len) : (i += 1) {
            const right = try self.compile(children[i]);
            self.patch(frag.outs, right.start);
            frag = .{ .start = frag.start, .outs = right.outs };
        }
        return frag;
    }

    fn compileAlt(self: *Compiler, children: []*Node) Error!Fragment {
        if (children.len == 0) return self.emptyFrag();
        if (children.len == 1) return self.compile(children[0]);

        var frag = try self.compile(children[0]);
        var i: usize = 1;
        while (i < children.len) : (i += 1) {
            const right = try self.compile(children[i]);
            const split_pc = try self.emit(.{ .split = .{ .a = unset, .b = unset } });
            self.prog.items[split_pc].split.a = frag.start;
            self.prog.items[split_pc].split.b = right.start;
            frag = .{
                .start = split_pc,
                .outs = try self.joinOuts(frag.outs, right.outs),
            };
        }
        return frag;
    }

    fn compileRepeat(self: *Compiler, node: *Node, min: u32, max: ?u32) Error!Fragment {
        // Required copies.
        var frag: ?Fragment = null;
        var i: u32 = 0;
        while (i < min) : (i += 1) {
            const copy = try self.compile(node);
            if (frag) |*f| {
                self.patch(f.outs, copy.start);
                f.outs = copy.outs;
            } else {
                frag = copy;
            }
        }

        if (max) |m| {
            if (m < min) return error.InvalidRepeat;
            // Optional copies.
            var optional_count = m - min;
            var tail: ?Fragment = null;
            while (optional_count > 0) : (optional_count -= 1) {
                const copy = try self.compile(node);
                const split_pc = try self.emit(.{ .split = .{ .a = copy.start, .b = unset } });
                const f = Fragment{
                    .start = split_pc,
                    .outs = try self.joinOuts(copy.outs, &.{split_pc}),
                };
                if (tail) |*t| {
                    self.patch(f.outs, t.start);
                    t.start = f.start;
                } else {
                    tail = f;
                }
            }
            if (tail) |t| {
                if (frag) |*f| {
                    self.patch(f.outs, t.start);
                    f.outs = t.outs;
                } else {
                    frag = t;
                }
            }
        } else {
            // Unbounded: one more copy wrapped in a star.
            const body = try self.compile(node);
            const split_pc = try self.emit(.{ .split = .{ .a = body.start, .b = unset } });
            self.patch(body.outs, split_pc);
            const star = Fragment{
                .start = split_pc,
                .outs = try self.arena.dupe(u32, &.{split_pc}),
            };
            if (frag) |*f| {
                self.patch(f.outs, star.start);
                f.outs = star.outs;
            } else {
                frag = star;
            }
        }

        return frag orelse try self.emptyFrag();
    }
};

const unset: u32 = std.math.maxInt(u32);

fn byteSet(b: u8) CharSet {
    var set = CharSet.empty;
    set.set(b);
    return set;
}

fn anySet() CharSet {
    var set = CharSet.full;
    set.unset('\n');
    return set;
}

fn foldCaseNode(node: *Node) void {
    switch (node.*) {
        .byte => |b| {
            if (std.ascii.isAlphabetic(b)) {
                var set = CharSet.empty;
                set.set(b);
                set.set(std.ascii.toLower(b));
                set.set(std.ascii.toUpper(b));
                node.* = .{ .set = set };
            }
        },
        .set => |set| {
            var folded = set;
            var b: usize = 0;
            while (b < 256) : (b += 1) {
                if (!set.isSet(b)) continue;
                const x: u8 = @intCast(b);
                if (std.ascii.isAlphabetic(x)) {
                    folded.set(std.ascii.toLower(x));
                    folded.set(std.ascii.toUpper(x));
                }
            }
            node.* = .{ .set = folded };
        },
        .cat => |children| for (children) |child| foldCaseNode(child),
        .alt => |children| for (children) |child| foldCaseNode(child),
        .repeat => |r| foldCaseNode(r.node),
        else => {},
    }
}

fn literalNode(arena: Allocator, bytes: []const u8) Error!*Node {
    if (bytes.len == 0) {
        const n = try arena.create(Node);
        n.* = .empty;
        return n;
    }
    const children = try arena.alloc(*Node, bytes.len);
    for (bytes, 0..) |b, i| {
        const n = try arena.create(Node);
        n.* = .{ .byte = b };
        children[i] = n;
    }
    const n = try arena.create(Node);
    n.* = .{ .cat = children };
    return n;
}

fn wrapWhole(arena: Allocator, node: *Node) Error!*Node {
    const children = try arena.alloc(*Node, 3);
    children[0] = try arena.create(Node);
    children[0].* = .{ .assertion = .bol };
    children[1] = node;
    children[2] = try arena.create(Node);
    children[2].* = .{ .assertion = .eol };
    const n = try arena.create(Node);
    n.* = .{ .cat = children };
    return n;
}

// ---------------------------------------------------------------------------
// Regex
// ---------------------------------------------------------------------------

pub const Regex = struct {
    gpa: Allocator,
    prog: []Inst,
    start: u32,
    clist: []u32,
    nlist: []u32,
    marks: []u32,
    stack: []u32,
    gen: u32 = 0,
    /// Number of instruction inspections performed by the last `isMatch`.
    /// Exposed so tests can assert bounded work; not part of the stable API.
    steps: u64 = 0,

    pub fn compile(gpa: Allocator, pattern: []const u8, options: Options) Error!Regex {
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var root = if (options.literal)
            try literalNode(arena, pattern)
        else
            try parse(arena, pattern);

        if (options.case_insensitive) foldCaseNode(root);
        if (options.whole) root = try wrapWhole(arena, root);

        var prog: std.ArrayList(Inst) = .empty;
        defer prog.deinit(arena);
        var compiler = Compiler{ .arena = arena, .prog = &prog };
        const frag = try compiler.compile(root);
        const match_pc = try compiler.emit(.match);
        compiler.patch(frag.outs, match_pc);

        const prog_final = try gpa.dupe(Inst, prog.items);
        errdefer gpa.free(prog_final);
        const n = prog_final.len;
        const clist = try gpa.alloc(u32, n);
        errdefer gpa.free(clist);
        const nlist = try gpa.alloc(u32, n);
        errdefer gpa.free(nlist);
        const marks = try gpa.alloc(u32, n);
        errdefer gpa.free(marks);
        @memset(marks, 0);
        const stack = try gpa.alloc(u32, n * 2 + 1);
        errdefer gpa.free(stack);

        return .{
            .gpa = gpa,
            .prog = prog_final,
            .start = frag.start,
            .clist = clist,
            .nlist = nlist,
            .marks = marks,
            .stack = stack,
        };
    }

    pub fn deinit(self: *Regex, gpa: Allocator) void {
        gpa.free(self.prog);
        gpa.free(self.clist);
        gpa.free(self.nlist);
        gpa.free(self.marks);
        gpa.free(self.stack);
        self.* = undefined;
    }

    fn holds(self: *const Regex, a: Assert, pos: usize, text: []const u8) bool {
        _ = self;
        const len = text.len;
        switch (a) {
            .bol => return pos == 0,
            .eol => return pos == len,
            .word, .not_word => {
                const prev_word = pos > 0 and isWordByte(text[pos - 1]);
                const next_word = pos < len and isWordByte(text[pos]);
                const boundary = prev_word != next_word;
                return if (a == .word) boundary else !boundary;
            },
        }
    }

    fn addThread(
        self: *Regex,
        list: []u32,
        list_len: *usize,
        gen: u32,
        start_pc: u32,
        pos: usize,
        text: []const u8,
    ) void {
        var sp: usize = 0;
        self.stack[sp] = start_pc;
        sp += 1;
        while (sp > 0) {
            sp -= 1;
            const pc = self.stack[sp];
            if (self.marks[pc] == gen) continue;
            self.marks[pc] = gen;
            self.steps += 1;
            switch (self.prog[pc]) {
                .jmp => |target| {
                    self.stack[sp] = target;
                    sp += 1;
                },
                .split => |s| {
                    self.stack[sp] = s.a;
                    sp += 1;
                    self.stack[sp] = s.b;
                    sp += 1;
                },
                .assertion => |a| {
                    if (self.holds(a.kind, pos, text)) {
                        self.stack[sp] = a.out;
                        sp += 1;
                    }
                },
                .set, .match => {
                    list[list_len.*] = pc;
                    list_len.* += 1;
                },
            }
        }
    }

    /// Search `text` for a match.
    pub fn isMatch(self: *Regex, text: []const u8) bool {
        self.steps = 0;
        self.gen +%= 1;
        var gen = self.gen;
        var clen: usize = 0;
        self.addThread(self.clist, &clen, gen, self.start, 0, text);

        var pos: usize = 0;
        while (true) {
            var i: usize = 0;
            while (i < clen) : (i += 1) {
                self.steps += 1;
                switch (self.prog[self.clist[i]]) {
                    .match => return true,
                    else => {},
                }
            }
            if (pos == text.len) return false;

            gen +%= 1;
            var nlen: usize = 0;
            const b = text[pos];
            i = 0;
            while (i < clen) : (i += 1) {
                self.steps += 1;
                const pc = self.clist[i];
                switch (self.prog[pc]) {
                    .set => |set| {
                        if (set.chars.isSet(b)) {
                            self.addThread(self.nlist, &nlen, gen, set.out, pos + 1, text);
                        }
                    },
                    else => {},
                }
            }

            const tmp = self.clist;
            self.clist = self.nlist;
            self.nlist = tmp;
            clen = nlen;
            self.gen = gen;
            pos += 1;

            // Search: a match may start at any position.
            self.addThread(self.clist, &clen, gen, self.start, pos, text);
        }
    }
};

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn isPunctuation(b: u8) bool {
    return b >= 0x21 and b <= 0x7e and !std.ascii.isAlphanumeric(b);
}
