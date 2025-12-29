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
}
