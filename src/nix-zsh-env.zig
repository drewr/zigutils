const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Get the buildInputs environment variable (contains explicitly requested packages)
    const build_inputs = std.process.getEnvVarOwned(alloc, "buildInputs") catch |err| {
        // If buildInputs is not set, we're not in a nix-shell, just exit silently
        if (err == error.EnvironmentVariableNotFound) {
            return;
        }
        return err;
    };
    defer alloc.free(build_inputs);

    // Split buildInputs by space
    var input_iter = std.mem.splitScalar(u8, build_inputs, ' ');

    // Use fixed array since we only need up to 5 packages
    var nix_packages: [5][]const u8 = undefined;
    var package_count: usize = 0;

    // Iterate through each build input path
    while (input_iter.next()) |input_path| {
        // Skip empty entries
        if (input_path.len == 0) continue;

        // Check if this path is from /nix/store
        if (std.mem.startsWith(u8, input_path, "/nix/store/")) {
            // Extract the package name from the path
            // Format: /nix/store/<hash>-<package-name>
            const after_store = input_path["/nix/store/".len..];

            // Split by '-' to separate hash from package name
            // Format: <hash>-<package-name>
            if (std.mem.indexOfScalar(u8, after_store, '-')) |dash_pos| {
                const package_name = after_store[dash_pos + 1..];

                // Strip version number and suffixes (everything after first '-' followed by a digit or 'dev')
                var name_without_version = package_name;
                for (package_name, 0..) |c, idx| {
                    if (c == '-' and idx + 1 < package_name.len) {
                        const next_char = package_name[idx + 1];
                        if ((next_char >= '0' and next_char <= '9') or
                            std.mem.startsWith(u8, package_name[idx + 1..], "dev")) {
                            name_without_version = package_name[0..idx];
                            break;
                        }
                    }
                }

                nix_packages[package_count] = name_without_version;
                package_count += 1;

                // Stop after collecting 5 packages
                if (package_count >= 5) {
                    break;
                }
            }
        }
    }

    // Build and write output
    if (package_count > 0) {
        // Use a fixed buffer for output (should be plenty for 5 package names)
        var output_buf: [1024]u8 = undefined;
        var output_len: usize = 0;

        for (nix_packages[0..package_count], 0..) |package, i| {
            if (i > 0) {
                output_buf[output_len] = ':';
                output_len += 1;
            }
            @memcpy(output_buf[output_len..][0..package.len], package);
            output_len += package.len;
        }

        output_buf[output_len] = '\n';
        output_len += 1;

        _ = try std.posix.write(std.posix.STDOUT_FILENO, output_buf[0..output_len]);
    }
}
