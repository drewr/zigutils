const std = @import("std");
const libcurl = @import("lib/zig-libcurl/libcurl.zig");
const libssh2 = @import("lib/zig-libssh2/libssh2.zig");
const zlib = @import("lib/zig-zlib/zlib.zig");
const mbedtls = @import("lib/zig-mbedtls/mbedtls.zig");

pub fn build(b: *std.build.Builder) !void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const _zlib = zlib.create(b, target, mode);
    const _mbedtls = mbedtls.create(b, target, mode);
    const _libssh2 = libssh2.create(b, target, mode);
    const _libcurl = try libcurl.create(b, target, mode);

    _mbedtls.link(_libssh2.step);
    _libssh2.link(_libcurl.step);
    _mbedtls.link(_libcurl.step);
    _zlib.link(_libcurl.step, .{});
    _libcurl.step.install();

    const exe = b.addExecutable("main", "src/main.zig");
    _libcurl.link(exe, .{ .import_name = "curl" });

    const tests = b.addTest("src/main.zig");
    tests.setBuildMode(mode);
    tests.setTarget(target);
    _libcurl.link(tests, .{});
    _zlib.link(tests, .{});
    _mbedtls.link(tests);
    _libssh2.link(tests);

    _zlib.link(exe, .{});
    _mbedtls.link(exe);
    _libssh2.link(exe);

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    // Add nix-zsh-env executable
    const nix_zsh_env = b.addExecutable("nix-zsh-env", "src/nix-zsh-env.zig");
    nix_zsh_env.setTarget(target);
    nix_zsh_env.setBuildMode(mode);
    nix_zsh_env.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const exe_tests = b.addTest("src/main.zig");
    exe_tests.setTarget(target);
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
