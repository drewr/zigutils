# Zig 0.16 Migration Notes

API changes applied when upgrading from Zig 0.14/0.15 to 0.16.

## Allocator

`std.heap.GeneralPurposeAllocator` was renamed to `std.heap.DebugAllocator`.

```zig
// before
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();

// after — or better yet, use init.gpa (see main() section below)
var gpa = std.heap.DebugAllocator(.{}){};
defer _ = gpa.deinit();
const allocator = gpa.allocator();
```

## main() signature and process init

The preferred pattern is now to accept `std.process.Init` as the first parameter. This gives you a pre-configured GPA, an arena allocator, parsed environment variables, an `Io` handle, and the command-line args — no manual setup required.

```zig
// before
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

// after
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;   // debug allocator in Debug/ReleaseSafe
```

`std.process.Init` fields used in this project:

| Field | Type | Purpose |
|---|---|---|
| `init.gpa` | `Allocator` | General-purpose allocator (leak-checked in debug builds) |
| `init.arena` | `*ArenaAllocator` | Arena that lives for the whole process |
| `init.io` | `std.Io` | I/O handle required by Dir, File, and Child operations |
| `init.environ_map` | `*Environ.Map` | Parsed environment variables |
| `init.minimal.args` | `std.process.Args` | Command-line arguments |

## Command-line arguments

`process.argsAlloc` / `process.argsFree` were removed.

```zig
// before
const args = try process.argsAlloc(allocator);
defer process.argsFree(allocator, args);

// after (arena owns the memory; no defer needed)
const args = try init.minimal.args.toSlice(init.arena.allocator());
```

`toSlice` requires an arena-style allocator because the returned slices may point into the arena.

## Environment variables

`process.getEnvVarOwned` was removed.

```zig
// before
const val = try process.getEnvVarOwned(allocator, "KEY");
defer allocator.free(val);

// after (no allocation; returns a slice into the map's memory)
const val = init.environ_map.get("KEY") orelse return error.EnvironmentVariableNotFound;
```

## Writing to stdout/stderr

`std.posix.write` / `STDOUT_FILENO` were removed from the public API.

```zig
// before
_ = try std.posix.write(std.posix.STDOUT_FILENO, buf);

// after
try std.Io.File.stdout().writeStreamingAll(init.io, buf);
```

## Filesystem (std.fs.Dir → std.Io.Dir)

`std.fs.cwd()` and the methods on `std.fs.Dir` moved to `std.Io.Dir`. Most operations now take an `io` argument.

```zig
// before
fs.cwd().access(path, .{})
fs.cwd().makePath(path)

// after
std.Io.Dir.cwd().access(init.io, path, .{})
std.Io.Dir.cwd().createDirPath(init.io, path)   // makePath renamed
```

`std.fs.path.join` and the rest of `std.fs.path` are still accessible (though deprecated in favour of `std.Io.Dir.path`).

## Spawning child processes

`process.Child.init` / `child.spawn()` were replaced by `process.spawn`.

```zig
// before
var child = process.Child.init(&.{ "git", "clone", url, dest }, allocator);
child.stdin_behavior = .Ignore;
child.stdout_behavior = .Pipe;
child.stderr_behavior = .Pipe;
try child.spawn();

// after
var child = try process.spawn(init.io, .{
    .argv = &.{ "git", "clone", url, dest },
    .stdin = .ignore,
    .stdout = .pipe,
    .stderr = .pipe,
});
defer child.kill(init.io);   // idempotent; safe to call after wait()
```

## Reading from pipes

`File.read(&buf) → usize` was replaced by scatter/gather streaming reads. End-of-stream is now signalled via `error.EndOfStream` rather than a zero return.

```zig
// before
while (true) {
    const n = file.read(&buf) catch break;
    if (n == 0) break;
    process(buf[0..n]);
}

// after
while (true) {
    const vecs: [1][]u8 = .{buf[0..]};
    const n = file.readStreaming(io, &vecs) catch break;  // EndOfStream → break
    process(buf[0..n]);
}
```

## Waiting for a child process

`child.wait()` now takes `io`, and the `Term` enum variants are lowercase.

```zig
// before
const term = try child.wait();
switch (term) {
    .Exited => |code| { ... },
    else => ...,
}

// after
const term = try child.wait(init.io);
switch (term) {
    .exited => |code| { ... },
    else => ...,
}
```
