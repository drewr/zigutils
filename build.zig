const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const regex_mod = b.createModule(.{
        .root_source_file = b.path("src/regex.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gitclone = b.addExecutable(.{
        .name = "gitclone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gitclone.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gitclone);

    const zsh_nix_env = b.addExecutable(.{
        .name = "zsh-nix-env",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zsh-nix-env.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(zsh_nix_env);

    const tmphttp = b.addExecutable(.{
        .name = "tmphttp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tmphttp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(tmphttp);

    const zsh_hist = b.addExecutable(.{
        .name = "zsh-hist",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zsh-hist.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
            },
        }),
    });
    b.installArtifact(zsh_hist);

    // Run steps
    const run_gitclone = b.step("run-gitclone", "Run gitclone");
    const run_gitclone_exe = b.addRunArtifact(gitclone);
    run_gitclone.dependOn(&run_gitclone_exe.step);

    const run_zsh_nix_env = b.step("run-zsh-nix-env", "Run zsh-nix-env");
    const run_zsh_nix_env_exe = b.addRunArtifact(zsh_nix_env);
    run_zsh_nix_env.dependOn(&run_zsh_nix_env_exe.step);

    const run_tmphttp = b.step("run-tmphttp", "Run tmphttp");
    const run_tmphttp_exe = b.addRunArtifact(tmphttp);
    run_tmphttp.dependOn(&run_tmphttp_exe.step);

    const run_zsh_hist = b.step("run-zsh-hist", "Run zsh-hist");
    const run_zsh_hist_exe = b.addRunArtifact(zsh_hist);
    run_zsh_hist.dependOn(&run_zsh_hist_exe.step);

    // Default run step runs gitclone
    const run_default = b.step("run", "Run gitclone (default)");
    const run_default_exe = b.addRunArtifact(gitclone);
    run_default.dependOn(&run_default_exe.step);

    // Test step
    const test_step = b.step("test", "Run tests");
    const gitclone_test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gitclone_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_test = b.addRunArtifact(gitclone_test_exe);
    test_step.dependOn(&run_test.step);

    const zsh_nix_env_test = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zsh-nix-env.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zsh_nix_env_test).step);

    const tmphttp_test = b.addExecutable(.{
        .name = "tmphttp_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tmphttp_test.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    const run_tmphttp_test = b.addRunArtifact(tmphttp_test);
    run_tmphttp_test.addArtifactArg(tmphttp);
    test_step.dependOn(&run_tmphttp_test.step);

    const regex_test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/regex_test.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(regex_test_exe).step);

    const zsh_hist_test_exe = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zsh-hist_test.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "regex", .module = regex_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(zsh_hist_test_exe).step);
}
