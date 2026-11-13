
## Quickstart

```
% git clone --recurse-submodules https://github.com/drewr/zigutils
% ./bootstrap.sh
% zig build run
```

## zsh-nix-env

Prints a compact label describing the active Nix shells, meant for a zsh
`precmd`:

```zsh
nix_info=$(zsh-nix-env)
[[ -n $nix_info ]] && nix_prompt="[${nix_info}]"
```

| Active shells             | Output         |
|---------------------------|----------------|
| none                      | (empty)        |
| `nix-shell -p jq ripgrep` | `λjq:ripgrep`  |
| `nix shell nixpkgs#cargo` | `λcargo`       |
| `nix develop`             | `❄`            |
| `nix-shell` inside `nix develop` | `❄λjq:ripgrep` |

`nix shell` exports no package list, so its names are inferred from the
leading `/nix/store/<hash>-<package>/bin` entries in `$PATH`. A `nix shell`
nested inside `nix develop` or `nix-shell` cannot be told apart from the
outer shell and is not reported separately.

Each environment is a `ShellScenario` variant with a `ShellDetector` that
inspects the environment. `ActiveShells` runs every detector, so more than one
scenario can be active at once. To support a new environment, add a variant
and its render arm to `ShellScenario` and a detector to `shell_detectors` in
`src/zsh-nix-env.zig`.

## zsh-hist

Delete entries matching a pattern from zsh history. It is a dry run by
default; pass `--delete` to rewrite the file. A backup is written first and
the original file permissions are preserved.

```
zsh-hist [options] PATTERN
```

| Option | Meaning |
|--------|---------|
| `-d`, `--delete` | actually delete matching entries |
| `-F`, `--fixed-strings` | treat `PATTERN` as a literal string |
| `-i`, `--ignore-case` | case-insensitive match |
| `-x`, `--line-regexp` | `PATTERN` must match the whole command |
| `-f`, `--file FILE` | history file (default: `$HISTFILE` or `~/.zsh_history`) |
| `--no-backup` | don't write a backup before deleting |
| `-h`, `--help` | show help |

Examples:

```zsh
% zsh-hist 'git status'            # preview matching entries
% zsh-hist -x 'git status'         # commands that are exactly "git status"
% zsh-hist -F 'npm run build'      # literal, not a regex
% zsh-hist -d '^cd /tmp'           # delete entries starting with "cd /tmp"
```

Plain and `EXTENDED_HISTORY` (`: <ts>:<dur>;cmd`) entries are handled, as are
multi-line commands and zsh's metafied encoding of non-ASCII bytes. With
`--delete`, the tool takes zsh's `HISTFILE.LOCK` first so a shell appending to
the history during the rewrite cannot lose lines.

**Shared-history caveat:** open shells keep their own copy of the history in
memory and may write it back later. After deleting entries, run `fc -R` in each
open shell (or restart them) to reload the cleaned file.

## regex (library)

`src/regex.zig` is a small pure-Zig regular-expression library used by
`zsh-hist`. It has no IO and no dependencies beyond `std`. `src/regex_test.zig`
covers it with example-based, generative and fuzz tests.

The public API is:

```zig
const regex = @import("regex");

var re = try regex.Regex.compile(gpa, "a+", .{ .case_insensitive = true });
defer re.deinit(gpa);
if (re.isMatch("BAA")) { /* ... */ }
```

`Options` also has `literal` (quote the whole pattern) and `whole` (anchor
both ends). `regex.escape(gpa, bytes)` returns a pattern that matches `bytes`
exactly. The parser's `Node` and `parse()` are exported for tests but are
internal details.

Supported syntax:

- literals, `.` (any byte except newline), `^`, `$`, `\A`, `\Z`
- alternation, `(...)` and `(?:...)`
- `* + ? {m} {m,} {,n} {m,n}`, with an optional lazy `?` (it is accepted and
  ignored, since matching only answers yes or no)
- bracket classes `[...]` and `[^...]`, with ranges and escapes
- `\d \D \w \W \s \S \b \B \n \t \r \f \v`, and `\` before any punctuation

Patterns match bytes, so UTF-8 text works as its byte sequence. Matching uses
a Thompson NFA, so it is linear in the input size for a fixed pattern and does
not backtrack.

To use the library from another tool, add an import in `build.zig`:

```zig
const regex_mod = b.createModule(.{
    .root_source_file = b.path("src/regex.zig"),
    .target = target,
    .optimize = optimize,
});

const my_tool = b.addExecutable(.{
    .name = "my-tool",
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/my-tool.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "regex", .module = regex_mod }},
    }),
});
```
