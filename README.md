
## Quickstart

```
% git clone --recurse-submodules https://github.com/drewr/zigutils
% ./bootstrap.sh
% zig build run
```

## nix-zsh-env

Prints a compact label describing the active Nix shells, meant for a zsh
`precmd`:

```zsh
nix_info=$(nix-zsh-env)
[[ -n $nix_info ]] && nix_prompt="[${nix_info}]"
```

| Active shells             | Output         |
|---------------------------|----------------|
| none                      | (empty)        |
| `nix-shell -p jq ripgrep` | `λjq:ripgrep`  |
| `nix develop`             | `❄`            |
| both                      | `❄λjq:ripgrep` |

Each environment is a `ShellScenario` variant with a `ShellDetector` that
inspects the environment. `ActiveShells` runs every detector, so more than one
scenario can be active at once. To support a new environment, add a variant
and its render arm to `ShellScenario` and a detector to `shell_detectors` in
`src/nix-zsh-env.zig`.
