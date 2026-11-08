const std = @import("std");
const mem = std.mem;

const Env = std.process.Environ.Map;

/// Pure: extract a package name from a Nix store path like
/// "/nix/store/<hash>-<package-name>". Returns null if the path
/// is not a Nix store path or can't be parsed.
fn extractPackage(path: []const u8) ?[]const u8 {
    const prefix = "/nix/store/";
    const rest = if (mem.startsWith(u8, path, prefix)) path[prefix.len..] else return null;
    const dash = mem.indexOfScalar(u8, rest, '-') orelse return null;
    return stripVersion(rest[dash + 1 ..]);
}

/// Pure: strip version suffixes from a package name.
/// Stops at "-<digit>" or "-dev".
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

/// One variant per shell environment we recognize. The payload holds
/// only what render needs.
const ShellScenario = union(enum) {
    /// `nix develop` (flake devShell). Renders just a glyph.
    nix_develop,
    /// `nix-shell`. Payload is the raw $buildInputs.
    nix_shell: struct { build_inputs: []const u8 },

    const max_packages = 5;

    /// Pure: write this scenario's label (no newline).
    fn render(self: ShellScenario, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .nix_develop => try w.writeAll("❄"),
            .nix_shell => |s| {
                try w.writeAll("λ");
                var iter = mem.splitScalar(u8, s.build_inputs, ' ');
                var count: usize = 0;
                while (iter.next()) |path| {
                    if (path.len == 0) continue;
                    const pkg = extractPackage(path) orelse continue;
                    if (count > 0) try w.writeByte(':');
                    try w.writeAll(pkg);
                    count += 1;
                    if (count >= max_packages) break;
                }
            },
        }
    }
};

/// Detects one shell environment. Each detector runs on its own and must
/// rule out look-alike environments itself.
const ShellDetector = *const fn (env: *const Env) ?ShellScenario;

fn detectNixDevelop(env: *const Env) ?ShellScenario {
    if (env.get("NIX_GCROOT") == null) return null;
    if (env.get("IN_NIX_SHELL") == null) return null;
    return .nix_develop;
}

/// Pure: the derivation name in a nix develop NIX_GCROOT, e.g.
/// "/nix/store/<hash>-zigutils-env" -> "zigutils-env".
fn gcrootName(gcroot: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(gcroot);
    const dash = mem.indexOfScalar(u8, base, '-') orelse return null;
    return base[dash + 1 ..];
}

fn detectNixShell(env: *const Env) ?ShellScenario {
    // nix develop also sets buildInputs. A nix-shell nested inside nix develop
    // inherits NIX_GCROOT but overwrites $name, so buildInputs belongs to
    // nix develop only when $name still matches the NIX_GCROOT derivation.
    if (env.get("NIX_GCROOT")) |gcroot| {
        const name = env.get("name") orelse return null;
        const dev_name = gcrootName(gcroot) orelse return null;
        if (mem.eql(u8, name, dev_name)) return null;
    }
    const build_inputs = env.get("buildInputs") orelse return null;
    if (mem.trim(u8, build_inputs, " ").len == 0) return null;
    return .{ .nix_shell = .{ .build_inputs = build_inputs } };
}

/// Order here is the order labels appear in the prompt.
/// To add an environment: add a ShellScenario variant, its render arm,
/// and a ShellDetector here.
const shell_detectors = [_]ShellDetector{ detectNixDevelop, detectNixShell };

/// Every ShellScenario that is true right now. More than one can be
/// true at once.
const ActiveShells = struct {
    items: [shell_detectors.len]ShellScenario = undefined,
    len: usize = 0,

    /// Pure: run every detector and keep each match.
    fn detect(env: *const Env) ActiveShells {
        var active: ActiveShells = .{};
        for (shell_detectors) |d| {
            if (d(env)) |scenario| active.append(scenario);
        }
        return active;
    }

    fn append(self: *ActiveShells, scenario: ShellScenario) void {
        self.items[self.len] = scenario;
        self.len += 1;
    }

    fn slice(self: *const ActiveShells) []const ShellScenario {
        return self.items[0..self.len];
    }

    /// Render each ShellScenario back to back; the glyphs separate them.
    fn render(self: *const ActiveShells, w: *std.Io.Writer) std.Io.Writer.Error!void {
        for (self.slice()) |scenario| try scenario.render(w);
    }
};

pub fn main(init: std.process.Init) !void {
    const active = ActiveShells.detect(init.environ_map);
    if (active.len == 0) return;

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    // A full buffer just truncates the label.
    active.render(&w) catch {};
    const out = w.buffered();
    if (out.len == 0) return;
    buf[out.len] = '\n';
    try std.Io.File.stdout().writeStreamingAll(init.io, buf[0 .. out.len + 1]);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn expectRender(env: *const Env, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try ActiveShells.detect(env).render(&w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "stripVersion and extractPackage" {
    try testing.expectEqualStrings("jq", stripVersion("jq-1.8.2-dev"));
    try testing.expectEqualStrings("openssl", stripVersion("openssl-dev"));
    try testing.expectEqualStrings("ripgrep", stripVersion("ripgrep"));
    try testing.expectEqualStrings("jq", extractPackage("/nix/store/za20v1vw-jq-1.8.2-dev").?);
    try testing.expect(extractPackage("/usr/bin/jq") == null);
    try testing.expect(extractPackage("/nix/store/nodash") == null);
}

test "empty env renders nothing" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try testing.expectEqual(@as(usize, 0), ActiveShells.detect(&env).len);
    try expectRender(&env, "");
}

test "nix-shell" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try env.put("IN_NIX_SHELL", "impure");
    try env.put("buildInputs", "/nix/store/za20v1vw-jq-1.8.2-dev /nix/store/abc-ripgrep-14.1.0");
    const active = ActiveShells.detect(&env);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expectEqualStrings(
        "/nix/store/za20v1vw-jq-1.8.2-dev /nix/store/abc-ripgrep-14.1.0",
        active.slice()[0].nix_shell.build_inputs,
    );
    try expectRender(&env, "λjq:ripgrep");
}

test "nix-shell caps package count" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try env.put("buildInputs", "/nix/store/a-p1 /nix/store/a-p2 /nix/store/a-p3 /nix/store/a-p4 /nix/store/a-p5 /nix/store/a-p6");
    try expectRender(&env, "λp1:p2:p3:p4:p5");
}

test "nix-shell with no parseable packages still shows glyph" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try env.put("buildInputs", "/opt/thing");
    try expectRender(&env, "λ");
}

test "nix develop" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try env.put("IN_NIX_SHELL", "impure");
    try env.put("NIX_GCROOT", "/nix/store/91p88x63-zigutils-env");
    try env.put("name", "zigutils-env");
    try env.put("buildInputs", "");
    try env.put("nativeBuildInputs", "/nix/store/h458l5k1-zig-0.18.0-dev.610+720939f8c");
    const active = ActiveShells.detect(&env);
    try testing.expectEqual(@as(usize, 1), active.len);
    try testing.expect(active.slice()[0] == .nix_develop);
    try expectRender(&env, "❄");
}

test "nix develop with buildInputs is not also a nix-shell" {
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try env.put("IN_NIX_SHELL", "impure");
    try env.put("NIX_GCROOT", "/nix/store/91p88x63-zigutils-env");
    try env.put("name", "zigutils-env");
    try env.put("buildInputs", "/nix/store/za20v1vw-jq-1.8.2-dev");
    try expectRender(&env, "❄");
}

test "nix-shell nested inside nix develop shows both" {
    // Env observed from `nix develop -c nix-shell -p jq`.
    var env = Env.init(testing.allocator);
    defer env.deinit();
    try env.put("IN_NIX_SHELL", "impure");
    try env.put("NIX_GCROOT", "/nix/store/91p88x63-zigutils-env");
    try env.put("name", "shell");
    try env.put("buildInputs", "/nix/store/za20v1vw-jq-1.8.2-dev");
    try env.put("nativeBuildInputs", "");
    try expectRender(&env, "❄λjq");
}

test "gcrootName" {
    try testing.expectEqualStrings("zigutils-env", gcrootName("/nix/store/91p88x63-zigutils-env").?);
    try testing.expect(gcrootName("/nix/store/nodash") == null);
}

test "multiple active shells render back to back" {
    var active: ActiveShells = .{};
    active.append(.nix_develop);
    active.append(.{ .nix_shell = .{ .build_inputs = "/nix/store/za20v1vw-jq-1.8.2-dev" } });
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try active.render(&w);
    try testing.expectEqualStrings("❄λjq", w.buffered());
}
