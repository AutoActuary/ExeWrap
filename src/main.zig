const std = @import("std");
const launcher = @import("zig_launcher");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const exe_path = try std.fs.selfExePathAlloc(scratch);
    const paths = try launcher.RuntimePaths.init(scratch, exe_path);
    const config_bytes = try launcher.readEmbeddedConfig(scratch, exe_path);
    const config = try launcher.parseConfig(scratch, config_bytes, paths);

    var env_map = try std.process.getEnvMap(scratch);
    try launcher.applyEnvironment(&env_map, config.env, paths);

    var child = std.process.Child.init(config.command, scratch);
    child.cwd = config.cwd;
    child.env_map = &env_map;
    child.create_no_window = config.silent;

    if (config.silent) {
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
    } else {
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    }

    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |_| std.process.exit(1),
        .Stopped => |_| std.process.exit(1),
        .Unknown => |_| std.process.exit(1),
    }
}
