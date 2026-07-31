# Build Instructions

## Prerequisites

- **Zig 0.16** (latest stable)
- **Nix** (optional, for reproducible builds and development shell)

## Building

### With Nix (recommended)

```bash
nix develop
zig build
```

### With bare Zig

```bash
zig build
```

## Running

```bash
zig build run                # runs gitclone
zig build run-gitclone       # runs gitclone
zig build run-nix-zsh-env    # runs nix-zsh-env
```

## Testing

```bash
zig build test
```

## Installing

```bash
zig build install --prefix /usr/local
```

## Nix Flakes

The project provides Nix flake outputs:

| Output | Description |
|--------|-------------|
| `packages.<system>.gitclone` | Standalone `gitclone` binary |
| `packages.<system>.nix-zsh-env` | Standalone `nix-zsh-env` binary |
| `packages.<system>.default` | Both binaries via `symlinkJoin` |
| `apps.<system>.gitclone` | Runnable `gitclone` app |
| `apps.<system>.nix-zsh-env` | Runnable `nix-zsh-env` app |
| `devShells.default` | Development shell with Zig |

Examples:

```bash
nix build                   # builds default (both binaries)
nix build .#gitclone        # builds gitclone only
nix run .                   # runs gitclone
nix run .#nix-zsh-env       # runs nix-zsh-env
```

## Build Options

| Flag | Description | Default |
|------|-------------|---------|
| `-Doptimize=<mode>` | Optimization level | `Debug` |
| `-Dtarget=<triple>` | Build target | native |

Optimization modes: `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`
