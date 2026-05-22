const std = @import("std");

pub const FileExistsFn = *const fn (context: ?*const anyopaque, path: []const u8) bool;

pub const Options = struct {
    cwd: []const u8,
    env_map: *std.process.EnvMap,
    file_exists: FileExistsFn = defaultFileExists,
    file_exists_context: ?*const anyopaque = null,
};

pub const ResolvedCommand = struct {
    argv: []const []const u8,
    executable_path: []const u8,
    found: bool,
};

pub fn resolveCommandForSpawn(
    allocator: std.mem.Allocator,
    command: []const []const u8,
    options: Options,
) !ResolvedCommand {
    const resolved = try resolveExecutable(allocator, command[0], options);
    const executable_path = resolved orelse command[0];
    if (resolved == null or std.mem.eql(u8, executable_path, command[0])) {
        return .{
            .argv = command,
            .executable_path = executable_path,
            .found = resolved != null,
        };
    }

    const argv = try allocator.dupe([]const u8, command);
    argv[0] = executable_path;
    return .{
        .argv = argv,
        .executable_path = executable_path,
        .found = true,
    };
}

fn resolveExecutable(
    allocator: std.mem.Allocator,
    command0: []const u8,
    options: Options,
) !?[]const u8 {
    if (std.fs.path.isAbsolute(command0)) {
        return try resolveExecutablePath(allocator, command0, options);
    }

    if (hasPathSeparator(command0)) {
        const path = try std.fs.path.join(allocator, &.{ options.cwd, command0 });
        return try resolveExecutablePath(allocator, path, options);
    }

    if (try resolveExecutableInDir(allocator, options.cwd, command0, options)) |path| return path;

    const path_value = getEnvValue(options.env_map, "PATH", &.{ "Path", "path" }) orelse return null;
    var path_it = std.mem.splitScalar(u8, path_value, ';');
    while (path_it.next()) |raw_dir| {
        const dir = std.mem.trim(u8, raw_dir, "\" ");
        if (dir.len == 0) continue;
        if (try resolveExecutableInDir(allocator, dir, command0, options)) |path| return path;
    }

    return null;
}

fn resolveExecutableInDir(
    allocator: std.mem.Allocator,
    dir: []const u8,
    name: []const u8,
    options: Options,
) !?[]const u8 {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    return try resolveExecutablePath(allocator, path, options);
}

fn resolveExecutablePath(
    allocator: std.mem.Allocator,
    path: []const u8,
    options: Options,
) !?[]const u8 {
    if (options.file_exists(options.file_exists_context, path)) return path;
    if (std.fs.path.extension(path).len != 0) return null;

    const pathext = getEnvValue(options.env_map, "PATHEXT", &.{"PathExt"}) orelse ".COM;.EXE;.BAT;.CMD";
    var ext_it = std.mem.splitScalar(u8, pathext, ';');
    while (ext_it.next()) |raw_ext| {
        const ext = std.mem.trim(u8, raw_ext, "\" ");
        if (!isSpawnSupportedPathext(ext)) continue;
        const candidate = try std.mem.concat(allocator, u8, &.{ path, ext });
        if (options.file_exists(options.file_exists_context, candidate)) return candidate;
    }

    return null;
}

fn getEnvValue(env_map: *std.process.EnvMap, canonical: []const u8, alternates: []const []const u8) ?[]const u8 {
    if (env_map.get(canonical)) |value| return value;
    for (alternates) |name| {
        if (env_map.get(name)) |value| return value;
    }
    return null;
}

fn isSpawnSupportedPathext(ext: []const u8) bool {
    return std.ascii.eqlIgnoreCase(ext, ".COM") or
        std.ascii.eqlIgnoreCase(ext, ".EXE") or
        std.ascii.eqlIgnoreCase(ext, ".BAT") or
        std.ascii.eqlIgnoreCase(ext, ".CMD");
}

fn defaultFileExists(_: ?*const anyopaque, path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn hasPathSeparator(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, '\\') != null or
        std.mem.indexOfScalar(u8, value, '/') != null;
}
