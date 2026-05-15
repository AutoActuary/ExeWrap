const std = @import("std");

pub const marker_uuid = "8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a";
pub const marker_len = 16;
pub const max_exe_bytes = 512 * 1024 * 1024;

const marker_xor_key: u8 = 0xa7;
const encoded_marker = [_]u8{
    0x2b, 0xa9, 0x2a, 0xeb, 0x95, 0x08, 0xe8, 0x7f,
    0x3b, 0xcf, 0xcd, 0xa8, 0x30, 0x48, 0x4c, 0xcd,
};

pub const RuntimePaths = struct {
    exe_path: []const u8,
    exe_dir: []const u8,
    exe_name: []const u8,
    exe_stem: []const u8,
    launch_cwd: []const u8,

    pub fn init(allocator: std.mem.Allocator, exe_path: []const u8) !RuntimePaths {
        const launch_cwd = try std.process.getCwdAlloc(allocator);
        const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
        const exe_name = std.fs.path.basename(exe_path);
        return .{
            .exe_path = exe_path,
            .exe_dir = exe_dir,
            .exe_name = exe_name,
            .exe_stem = std.fs.path.stem(exe_name),
            .launch_cwd = launch_cwd,
        };
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Config = struct {
    silent: bool,
    cwd: []const u8,
    command: []const []const u8,
    env: []const EnvVar,
};

pub fn markerBytes() [marker_len]u8 {
    var out: [marker_len]u8 = undefined;
    for (&out, encoded_marker) |*dest, encoded| {
        dest.* = encoded ^ marker_xor_key;
    }
    return out;
}

pub fn readEmbeddedConfig(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, exe_path, max_exe_bytes);
    const marker = markerBytes();
    const index = lastIndexOfBytes(bytes, &marker) orelse return error.NoEmbeddedConfig;
    const config = normalizeConfigBytes(bytes[index + marker.len ..]);
    if (std.mem.trim(u8, config, " \t\r\n").len == 0) return error.EmptyEmbeddedConfig;
    try validateConfigBytes(config);
    return config;
}

pub fn validateConfigBytes(bytes: []const u8) !void {
    if (!std.unicode.utf8ValidateSlice(normalizeConfigBytes(bytes))) return error.ConfigMustBeUtf8;
}

pub fn parseConfig(allocator: std.mem.Allocator, bytes: []const u8, paths: RuntimePaths) !Config {
    try validateConfigBytes(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalizeConfigBytes(bytes), .{});
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.ConfigMustBeObject,
    };

    const terminal = getBool(root, "terminal") orelse false;
    const silent = getBool(root, "silent") orelse !terminal;
    const cwd_raw = getString(root, "cwd") orelse "{exe_dir}";
    const command_value = root.get("commandline") orelse root.get("command") orelse return error.MissingCommand;

    const command_array = switch (command_value) {
        .array => |array| array,
        else => return error.CommandMustBeArray,
    };
    if (command_array.items.len == 0) return error.CommandMustNotBeEmpty;

    var command: std.ArrayList([]const u8) = .empty;
    for (command_array.items) |item| {
        const raw = switch (item) {
            .string => |value| value,
            else => return error.CommandEntriesMustBeStrings,
        };
        try command.append(allocator, try expandPlaceholders(allocator, raw, paths));
    }

    const env = try parseEnv(allocator, root.get("env"), paths);

    return .{
        .silent = silent,
        .cwd = try expandPlaceholders(allocator, cwd_raw, paths),
        .command = try command.toOwnedSlice(allocator),
        .env = env,
    };
}

pub fn applyEnvironment(env_map: *std.process.EnvMap, vars: []const EnvVar, paths: RuntimePaths) !void {
    try env_map.put("ZIG_LAUNCHER_EXE", paths.exe_path);
    try env_map.put("ZIG_LAUNCHER_DIR", paths.exe_dir);
    try env_map.put("ZIG_LAUNCHER_NAME", paths.exe_name);
    try env_map.put("ZIG_LAUNCHER_STEM", paths.exe_stem);
    try env_map.put("ZIG_LAUNCHER_LAUNCH_CWD", paths.launch_cwd);

    for (vars) |entry| {
        try env_map.put(entry.name, entry.value);
    }
}

fn parseEnv(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
    paths: RuntimePaths,
) ![]const EnvVar {
    const value = maybe_value orelse return &.{};
    var vars: std.ArrayList(EnvVar) = .empty;

    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                const raw_value = switch (entry.value_ptr.*) {
                    .string => |s| s,
                    else => return error.EnvValuesMustBeStrings,
                };
                try vars.append(allocator, .{
                    .name = try allocator.dupe(u8, entry.key_ptr.*),
                    .value = try expandPlaceholders(allocator, raw_value, paths),
                });
            }
        },
        .array => |array| {
            for (array.items) |item| {
                const object = switch (item) {
                    .object => |object| object,
                    else => return error.EnvEntriesMustBeObjects,
                };
                const name = getString(object, "name") orelse return error.EnvEntryMissingName;
                const raw_value = getString(object, "value") orelse return error.EnvEntryMissingValue;
                try vars.append(allocator, .{
                    .name = try expandPlaceholders(allocator, name, paths),
                    .value = try expandPlaceholders(allocator, raw_value, paths),
                });
            }
        },
        else => return error.EnvMustBeObjectOrArray,
    }

    return try vars.toOwnedSlice(allocator);
}

fn expandPlaceholders(allocator: std.mem.Allocator, input: []const u8, paths: RuntimePaths) ![]const u8 {
    const Placeholder = struct {
        tag: []const u8,
        value: []const u8,
    };
    const placeholders = [_]Placeholder{
        .{ .tag = "{exe}", .value = paths.exe_path },
        .{ .tag = "{exe_path}", .value = paths.exe_path },
        .{ .tag = "{launcher_path}", .value = paths.exe_path },
        .{ .tag = "{exe_dir}", .value = paths.exe_dir },
        .{ .tag = "{launcher_dir}", .value = paths.exe_dir },
        .{ .tag = "{app_dir}", .value = paths.exe_dir },
        .{ .tag = "{exe_name}", .value = paths.exe_name },
        .{ .tag = "{argv0}", .value = paths.exe_name },
        .{ .tag = "{exe_stem}", .value = paths.exe_stem },
        .{ .tag = "{app_name}", .value = paths.exe_stem },
        .{ .tag = "{cwd}", .value = paths.launch_cwd },
        .{ .tag = "{launch_cwd}", .value = paths.launch_cwd },
        .{ .tag = "{initial_cwd}", .value = paths.launch_cwd },
    };

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        var matched = false;
        for (placeholders) |placeholder| {
            if (std.mem.startsWith(u8, input[i..], placeholder.tag)) {
                try out.appendSlice(allocator, placeholder.value);
                i += placeholder.tag.len;
                matched = true;
                break;
            }
        }
        if (matched) continue;

        try out.append(allocator, input[i]);
        i += 1;
    }
    return try out.toOwnedSlice(allocator);
}

fn getBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn getString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |s| s,
        else => null,
    };
}

fn normalizeConfigBytes(bytes: []const u8) []const u8 {
    var out = std.mem.trimLeft(u8, bytes, " \t\r\n");
    if (std.mem.startsWith(u8, out, "\xEF\xBB\xBF")) {
        out = out[3..];
        out = std.mem.trimLeft(u8, out, " \t\r\n");
    }
    return out;
}

fn lastIndexOfBytes(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;

    var i = haystack.len - needle.len;
    while (true) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
        if (i == 0) break;
        i -= 1;
    }
    return null;
}

test "normalizes UTF-8 BOM before parsing config" {
    const allocator = std.testing.allocator;
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = try parseConfig(
        arena.allocator(),
        "\xEF\xBB\xBF{\"command\":[\"cmd.exe\",\"/C\",\"exit /b 0\"]}",
        paths,
    );

    try std.testing.expect(config.silent);
    try std.testing.expectEqualStrings("cmd.exe", config.command[0]);
}

test "rejects non UTF-8 config bytes before JSON parsing" {
    const allocator = std.testing.allocator;
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };

    try std.testing.expectError(
        error.ConfigMustBeUtf8,
        parseConfig(allocator, "{ \"command\": [\"\xFF\"] }", paths),
    );
}

test "accepts UTF-8 config strings" {
    const allocator = std.testing.allocator;
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };
    const json =
        \\{
        \\  "command": ["cmd.exe", "/C", "echo café"]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = try parseConfig(arena.allocator(), json, paths);

    try std.testing.expectEqualStrings("echo café", config.command[2]);
}

test "marker bytes match documented UUID" {
    const marker = markerBytes();
    const expected = [_]u8{
        0x8c, 0x0e, 0x8d, 0x4c, 0x32, 0xaf, 0x4f, 0xd8,
        0x9c, 0x68, 0x6a, 0x0f, 0x97, 0xef, 0xeb, 0x6a,
    };
    try std.testing.expectEqualSlices(u8, &expected, &marker);
}

test "parse config expands paths" {
    const allocator = std.testing.allocator;
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };
    const json =
        \\{
        \\  "terminal": true,
        \\  "cwd": "{exe_dir}",
        \\  "env": { "SCRIPT_HOME": "{exe_dir}" },
        \\  "command": ["cmd.exe", "/C", "{exe_dir}\\run.cmd"]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = try parseConfig(arena.allocator(), json, paths);

    try std.testing.expect(!config.silent);
    try std.testing.expectEqualStrings("C:\\apps\\demo", config.cwd);
    try std.testing.expectEqual(@as(usize, 3), config.command.len);
    try std.testing.expectEqualStrings("C:\\apps\\demo\\run.cmd", config.command[2]);
    try std.testing.expectEqualStrings("SCRIPT_HOME", config.env[0].name);
    try std.testing.expectEqualStrings("C:\\apps\\demo", config.env[0].value);
}

test "unknown brace groups remain literal for shell scriptblocks" {
    const allocator = std.testing.allocator;
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };
    const json =
        \\{
        \\  "command": [
        \\    "powershell.exe",
        \\    "-Command",
        \\    "Get-Process | Where-Object { $_.Name -eq 'demo' }; & '{exe_dir}\\run.ps1'"
        \\  ]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = try parseConfig(arena.allocator(), json, paths);

    try std.testing.expectEqualStrings(
        "Get-Process | Where-Object { $_.Name -eq 'demo' }; & 'C:\\apps\\demo\\run.ps1'",
        config.command[2],
    );
}
