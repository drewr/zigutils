const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gitclone = b.addExecutable(.{
        .name = "gitclone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gitclone.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(gitclone);

    const nix_zsh_env = b.addExecutable(.{
        .name = "nix-zsh-env",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nix-zsh-env.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(nix_zsh_env);

    // Run steps
    const run_gitclone = b.step("run-gitclone", "Run gitclone");
    const run_gitclone_exe = b.addRunArtifact(gitclone);
    run_gitclone.dependOn(&run_gitclone_exe.step);

    const run_nix_zsh_env = b.step("run-nix-zsh-env", "Run nix-zsh-env");
    const run_nix_zsh_env_exe = b.addRunArtifact(nix_zsh_env);
    run_nix_zsh_env.dependOn(&run_nix_zsh_env_exe.step);

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
}
