# Build Instructions

## Prerequisites

- **Zig 0.18.0-dev.610+720939f8c** (pinned in `flake.nix`)
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
zig build run-zsh-nix-env    # runs zsh-nix-env
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
| `packages.<system>.zsh-nix-env` | Standalone `zsh-nix-env` binary |
| `packages.<system>.default` | Both binaries via `symlinkJoin` |
| `apps.<system>.gitclone` | Runnable `gitclone` app |
| `apps.<system>.zsh-nix-env` | Runnable `zsh-nix-env` app |
| `devShells.default` | Development shell with Zig |

Examples:

```bash
nix build                   # builds default (both binaries)
nix build .#gitclone        # builds gitclone only
nix run .                   # runs gitclone
nix run .#zsh-nix-env       # runs zsh-nix-env
```

## Build Options

| Flag | Description | Default |
|------|-------------|---------|
| `-Doptimize=<mode>` | Optimization level | `Debug` |
| `-Dtarget=<triple>` | Build target | native |

Optimization modes: `Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`
