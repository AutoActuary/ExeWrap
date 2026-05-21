const std = @import("std");

pub const template_scan = @import("template_scan.zig");
pub const template_expr = @import("template_expr.zig");

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
    exe_filename: []const u8 = "",
    exe_filename_noext: []const u8 = "",
    exe_name: []const u8 = "",
    exe_stem: []const u8 = "",
    exe_ext: []const u8 = "",
    exe_ext_dot: []const u8 = "",
    exe_drive: []const u8 = "",
    exe_root: []const u8 = "",
    exe_parent: []const u8 = "",
    launch_cwd: []const u8,
    temp_dir: []const u8 = "",
    home_dir: []const u8 = "",
    appdata_dir: []const u8 = "",
    localappdata_dir: []const u8 = "",
    programdata_dir: []const u8 = "",
    program_files_dir: []const u8 = "",
    program_files_x86_dir: []const u8 = "",
    documents_dir: []const u8 = "",
    downloads_dir: []const u8 = "",
    desktop_dir: []const u8 = "",

    pub fn init(allocator: std.mem.Allocator, exe_path: []const u8) !RuntimePaths {
        const launch_cwd = try std.process.getCwdAlloc(allocator);
        const exe_dir = std.fs.path.dirname(exe_path) orelse ".";
        const exe_filename = std.fs.path.basename(exe_path);
        const exe_ext_dot = std.fs.path.extension(exe_filename);
        const home_dir = try getEnvVarOrEmpty(allocator, "USERPROFILE");
        return .{
            .exe_path = exe_path,
            .exe_dir = exe_dir,
            .exe_filename = exe_filename,
            .exe_filename_noext = std.fs.path.stem(exe_filename),
            .exe_name = exe_filename,
            .exe_stem = std.fs.path.stem(exe_filename),
            .exe_ext = if (exe_ext_dot.len > 0) exe_ext_dot[1..] else "",
            .exe_ext_dot = exe_ext_dot,
            .exe_drive = std.fs.path.diskDesignator(exe_path),
            .exe_root = pathRoot(exe_path),
            .exe_parent = std.fs.path.dirname(exe_dir) orelse exe_dir,
            .launch_cwd = launch_cwd,
            .temp_dir = try getEnvVarOrEmpty(allocator, "TEMP"),
            .home_dir = home_dir,
            .appdata_dir = try getEnvVarOrEmpty(allocator, "APPDATA"),
            .localappdata_dir = try getEnvVarOrEmpty(allocator, "LOCALAPPDATA"),
            .programdata_dir = try getEnvVarOrEmpty(allocator, "ProgramData"),
            .program_files_dir = try getEnvVarOrEmpty(allocator, "ProgramFiles"),
            .program_files_x86_dir = try getEnvVarOrEmpty(allocator, "ProgramFiles(x86)"),
            .documents_dir = try joinKnownHomeDir(allocator, home_dir, "Documents"),
            .downloads_dir = try joinKnownHomeDir(allocator, home_dir, "Downloads"),
            .desktop_dir = try joinKnownHomeDir(allocator, home_dir, "Desktop"),
        };
    }
};

pub const EnvVar = struct {
    name: []const u8,
    value: []const u8,
};

pub const Config = struct {
    terminal: bool,
    kill_children_on_exit: bool,
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

pub const ParseConfigOptions = struct {
    paths: RuntimePaths,
    args0: []const u8 = "",
    args: []const []const u8 = &.{},
    env_map: *std.process.EnvMap,
};

pub fn parseConfig(allocator: std.mem.Allocator, bytes: []const u8, paths: RuntimePaths) !Config {
    try validateConfigBytes(bytes);
    var env_map = std.process.EnvMap.init(allocator);
    errdefer env_map.deinit();
    return parseConfigWithOptions(allocator, bytes, .{
        .paths = paths,
        .args0 = paths.exe_path,
        .args = &.{},
        .env_map = &env_map,
    });
}

pub fn parseConfigWithOptions(allocator: std.mem.Allocator, bytes: []const u8, options: ParseConfigOptions) !Config {
    try validateConfigBytes(bytes);

    const scanned = try template_scan.scanWithRandomSentinels(allocator, normalizeConfigBytes(bytes));
    defer scanned.deinit(allocator);
    try rejectDuplicateKeys(allocator, scanned.json);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, scanned.json, .{ .allocate = .alloc_always });
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return error.ConfigMustBeObject,
    };
    try rejectTemplateObjectKeys(parsed.value, scanned.sentinels);

    const strictness = template_expr.Strictness{
        .error_on_missing_env = getBool(root, "error_on_missing_env") orelse false,
        .error_on_arg_out_of_bounds = getBool(root, "error_on_arg_out_of_bounds") orelse false,
    };
    var eval_ctx = template_expr.EvalContext{
        .allocator = allocator,
        .metadata = metadataFromRuntime(options.paths, if (options.args0.len > 0) options.args0 else options.paths.exe_path),
        .env = options.env_map,
        .args = options.args,
        .strictness = strictness,
    };

    const terminal = getBool(root, "terminal") orelse false;
    const kill_children_on_exit = getBool(root, "kill_children_on_exit") orelse false;

    const env = try parseEnv(allocator, root.get("env"), &eval_ctx, scanned.sentinels);

    const cwd = if (root.get("cwd")) |cwd_value|
        try evalStringField(allocator, cwd_value, &eval_ctx, scanned.sentinels, error.CwdMustBeString)
    else
        options.paths.exe_dir;

    const command_value = root.get("command") orelse return error.MissingCommand;
    const command = try evalCommand(allocator, command_value, &eval_ctx, scanned.sentinels);

    return .{
        .terminal = terminal,
        .kill_children_on_exit = kill_children_on_exit,
        .cwd = cwd,
        .command = command,
        .env = env,
    };
}

fn parseEnv(
    allocator: std.mem.Allocator,
    maybe_value: ?std.json.Value,
    ctx: *template_expr.EvalContext,
    sentinels: []const template_scan.Sentinel,
) ![]const EnvVar {
    const value = maybe_value orelse return &.{};
    var vars: std.ArrayList(EnvVar) = .empty;

    const object = switch (value) {
        .object => |object| object,
        else => return error.EnvMustBeObject,
    };

    var it = object.iterator();
    while (it.next()) |entry| {
        const value_string = try evalStringField(allocator, entry.value_ptr.*, ctx, sentinels, error.EnvValuesMustBeStrings);
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        try vars.append(allocator, .{ .name = name, .value = value_string });
        try ctx.env.put(name, value_string);
    }

    return try vars.toOwnedSlice(allocator);
}

fn evalStringField(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    ctx: *template_expr.EvalContext,
    sentinels: []const template_scan.Sentinel,
    type_error: anyerror,
) ![]const u8 {
    const raw = switch (value) {
        .string => |s| s,
        else => return type_error,
    };
    return evalTemplateString(allocator, raw, ctx, sentinels);
}

fn evalCommand(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    ctx: *template_expr.EvalContext,
    sentinels: []const template_scan.Sentinel,
) ![]const []const u8 {
    const array = switch (value) {
        .array => |array| array,
        else => return error.CommandMustBeArray,
    };
    if (array.items.len == 0) return error.CommandMustNotBeEmpty;

    var command: std.ArrayList([]const u8) = .empty;
    for (array.items) |item| {
        const raw = switch (item) {
            .string => |s| s,
            else => return error.CommandEntriesMustBeStrings,
        };

        if (findExactSentinel(raw, sentinels)) |sentinel| {
            const value_result = try template_expr.evaluate(sentinel.expression, ctx);
            switch (value_result) {
                .string => |s| try command.append(allocator, s),
                .list => |items| try command.appendSlice(allocator, items),
                .integer => return error.TemplateMustEvaluateToString,
            }
            continue;
        }

        try command.append(allocator, try evalTemplateString(allocator, raw, ctx, sentinels));
    }
    return try command.toOwnedSlice(allocator);
}

fn evalTemplateString(
    allocator: std.mem.Allocator,
    raw: []const u8,
    ctx: *template_expr.EvalContext,
    sentinels: []const template_scan.Sentinel,
) ![]const u8 {
    if (findExactSentinel(raw, sentinels)) |sentinel| {
        const value = try template_expr.evaluate(sentinel.expression, ctx);
        return switch (value) {
            .string => |s| s,
            .list => error.ListTemplateNotAllowedInString,
            .integer => error.TemplateMustEvaluateToString,
        };
    }

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var changed = false;
    while (i < raw.len) {
        if (findSentinelAt(raw[i..], sentinels)) |sentinel| {
            const value = try template_expr.evaluate(sentinel.expression, ctx);
            switch (value) {
                .string => |s| try out.appendSlice(allocator, s),
                .list => return error.ListTemplateNotAllowedInString,
                .integer => return error.TemplateMustEvaluateToString,
            }
            i += sentinel.uuid.len;
            changed = true;
            continue;
        }
        try out.append(allocator, raw[i]);
        i += 1;
    }
    if (!changed) return raw;
    return try out.toOwnedSlice(allocator);
}

fn findExactSentinel(value: []const u8, sentinels: []const template_scan.Sentinel) ?template_scan.Sentinel {
    for (sentinels) |sentinel| {
        if (std.mem.eql(u8, value, sentinel.uuid)) return sentinel;
    }
    return null;
}

fn findSentinelAt(value: []const u8, sentinels: []const template_scan.Sentinel) ?template_scan.Sentinel {
    for (sentinels) |sentinel| {
        if (std.mem.startsWith(u8, value, sentinel.uuid)) return sentinel;
    }
    return null;
}

fn stringContainsSentinel(value: []const u8, sentinels: []const template_scan.Sentinel) bool {
    for (sentinels) |sentinel| {
        if (std.mem.indexOf(u8, value, sentinel.uuid) != null) return true;
    }
    return false;
}

fn rejectTemplateObjectKeys(value: std.json.Value, sentinels: []const template_scan.Sentinel) !void {
    switch (value) {
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| {
                if (stringContainsSentinel(entry.key_ptr.*, sentinels)) return error.TemplateInObjectKey;
                try rejectTemplateObjectKeys(entry.value_ptr.*, sentinels);
            }
        },
        .array => |array| {
            for (array.items) |item| try rejectTemplateObjectKeys(item, sentinels);
        },
        else => {},
    }
}

const DuplicateKeyScanner = struct {
    allocator: std.mem.Allocator,
    input: []const u8,
    index: usize = 0,

    fn scan(self: *DuplicateKeyScanner) anyerror!void {
        try self.skipValue();
        self.skipWhitespace();
        if (self.index != self.input.len) return error.InvalidJson;
    }

    fn skipValue(self: *DuplicateKeyScanner) anyerror!void {
        self.skipWhitespace();
        if (self.index >= self.input.len) return error.InvalidJson;
        return switch (self.input[self.index]) {
            '{' => self.skipObject(),
            '[' => self.skipArray(),
            '"' => {
                _ = try self.readString();
            },
            't' => self.skipLiteral("true"),
            'f' => self.skipLiteral("false"),
            'n' => self.skipLiteral("null"),
            '-', '0'...'9' => self.skipNumber(),
            else => error.InvalidJson,
        };
    }

    fn skipObject(self: *DuplicateKeyScanner) anyerror!void {
        self.index += 1;
        var seen = std.StringHashMap(void).init(self.allocator);
        defer seen.deinit();
        self.skipWhitespace();
        if (self.consume('}')) return;

        while (true) {
            self.skipWhitespace();
            if (self.index >= self.input.len or self.input[self.index] != '"') return error.InvalidJson;
            const key = try self.readString();
            if (seen.contains(key)) return error.DuplicateJsonKey;
            try seen.put(key, {});

            self.skipWhitespace();
            if (!self.consume(':')) return error.InvalidJson;
            try self.skipValue();
            self.skipWhitespace();
            if (self.consume('}')) return;
            if (!self.consume(',')) return error.InvalidJson;
        }
    }

    fn skipArray(self: *DuplicateKeyScanner) anyerror!void {
        self.index += 1;
        self.skipWhitespace();
        if (self.consume(']')) return;
        while (true) {
            try self.skipValue();
            self.skipWhitespace();
            if (self.consume(']')) return;
            if (!self.consume(',')) return error.InvalidJson;
        }
    }

    fn readString(self: *DuplicateKeyScanner) ![]const u8 {
        const start = self.index;
        self.index += 1;
        while (self.index < self.input.len) {
            const c = self.input[self.index];
            if (c == '"') {
                self.index += 1;
                return self.input[start..self.index];
            }
            if (c == '\\') {
                self.index += 1;
                if (self.index >= self.input.len) return error.InvalidJson;
                if (self.input[self.index] == 'u') {
                    if (self.index + 4 >= self.input.len) return error.InvalidJson;
                    self.index += 4;
                }
            } else if (c < 0x20) {
                return error.InvalidJson;
            }
            self.index += 1;
        }
        return error.InvalidJson;
    }

    fn skipLiteral(self: *DuplicateKeyScanner, literal: []const u8) !void {
        if (!std.mem.startsWith(u8, self.input[self.index..], literal)) return error.InvalidJson;
        self.index += literal.len;
    }

    fn skipNumber(self: *DuplicateKeyScanner) !void {
        if (self.consume('-') and self.index >= self.input.len) return error.InvalidJson;
        try self.skipDigits();
        if (self.consume('.')) try self.skipDigits();
        if (self.index < self.input.len and (self.input[self.index] == 'e' or self.input[self.index] == 'E')) {
            self.index += 1;
            _ = self.consume('+') or self.consume('-');
            try self.skipDigits();
        }
    }

    fn skipDigits(self: *DuplicateKeyScanner) !void {
        const start = self.index;
        while (self.index < self.input.len and self.input[self.index] >= '0' and self.input[self.index] <= '9') {
            self.index += 1;
        }
        if (self.index == start) return error.InvalidJson;
    }

    fn skipWhitespace(self: *DuplicateKeyScanner) void {
        while (self.index < self.input.len) : (self.index += 1) {
            switch (self.input[self.index]) {
                ' ', '\t', '\r', '\n' => {},
                else => break,
            }
        }
    }

    fn consume(self: *DuplicateKeyScanner, c: u8) bool {
        if (self.index < self.input.len and self.input[self.index] == c) {
            self.index += 1;
            return true;
        }
        return false;
    }
};

fn rejectDuplicateKeys(allocator: std.mem.Allocator, json: []const u8) !void {
    var scanner = DuplicateKeyScanner{ .allocator = allocator, .input = json };
    try scanner.scan();
}

fn metadataFromRuntime(paths: RuntimePaths, args0: []const u8) template_expr.Metadata {
    return .{
        .exe_path = paths.exe_path,
        .exe_dir = paths.exe_dir,
        .exe_filename = if (paths.exe_filename.len > 0) paths.exe_filename else paths.exe_name,
        .exe_filename_noext = if (paths.exe_filename_noext.len > 0) paths.exe_filename_noext else paths.exe_stem,
        .exe_ext = paths.exe_ext,
        .exe_ext_dot = paths.exe_ext_dot,
        .exe_drive = paths.exe_drive,
        .exe_root = paths.exe_root,
        .exe_parent = paths.exe_parent,
        .args0 = args0,
        .cwd = paths.launch_cwd,
        .temp_dir = paths.temp_dir,
        .home_dir = paths.home_dir,
        .appdata_dir = paths.appdata_dir,
        .localappdata_dir = paths.localappdata_dir,
        .programdata_dir = paths.programdata_dir,
        .program_files_dir = paths.program_files_dir,
        .program_files_x86_dir = paths.program_files_x86_dir,
        .documents_dir = paths.documents_dir,
        .downloads_dir = paths.downloads_dir,
        .desktop_dir = paths.desktop_dir,
        .os = @tagName(@import("builtin").os.tag),
        .arch = @tagName(@import("builtin").cpu.arch),
        .dir_sep = std.fs.path.sep_str,
        .path_sep = &.{std.fs.path.delimiter},
    };
}

fn getBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .bool => |b| b,
        else => null,
    };
}

fn getEnvVarOrEmpty(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => "",
        else => return err,
    };
}

fn joinKnownHomeDir(allocator: std.mem.Allocator, home_dir: []const u8, child: []const u8) ![]const u8 {
    if (home_dir.len == 0) return "";
    return std.fs.path.join(allocator, &.{ home_dir, child });
}

fn pathRoot(path: []const u8) []const u8 {
    var it = std.fs.path.NativeComponentIterator.init(path) catch return "";
    return it.root() orelse "";
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

    try std.testing.expect(!config.terminal);
    try std.testing.expect(!config.kill_children_on_exit);
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
        \\  "cwd": "@{exe_dir}",
        \\  "env": { "SCRIPT_HOME": "@{exe_dir}" },
        \\  "command": ["cmd.exe", "/C", "@{exe_dir}\\run.cmd"]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = try parseConfig(arena.allocator(), json, paths);

    try std.testing.expect(config.terminal);
    try std.testing.expect(!config.kill_children_on_exit);
    try std.testing.expectEqualStrings("C:\\apps\\demo", config.cwd);
    try std.testing.expectEqual(@as(usize, 3), config.command.len);
    try std.testing.expectEqualStrings("C:\\apps\\demo\\run.cmd", config.command[2]);
    try std.testing.expectEqualStrings("SCRIPT_HOME", config.env[0].name);
    try std.testing.expectEqualStrings("C:\\apps\\demo", config.env[0].value);
}

test "parse config accepts kill children on exit option" {
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
        \\  "kill_children_on_exit": true,
        \\  "command": ["cmd.exe", "/C", "exit /b 0"]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = try parseConfig(arena.allocator(), json, paths);

    try std.testing.expect(config.kill_children_on_exit);
}

test "commandline alias is not accepted" {
    const allocator = std.testing.allocator;
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };

    try std.testing.expectError(
        error.MissingCommand,
        parseConfig(allocator, "{\"commandline\":[\"cmd.exe\"]}", paths),
    );
}

test "env must be an ordered object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };
    var env_map = std.process.EnvMap.init(allocator);

    try std.testing.expectError(error.EnvMustBeObject, parseConfigWithOptions(
        allocator,
        "{\"env\":[{\"name\":\"PATH\",\"value\":\"x\"}],\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    ));
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
        \\    "Get-Process | Where-Object { $_.Name -eq 'demo' }; & '@{exe_dir}\\run.ps1'"
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

test "bare brace placeholders are literal under the template spec" {
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
        \\  "command": ["cmd.exe", "/C", "{exe_dir}"]
        \\}
    ;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const config = try parseConfig(arena.allocator(), json, paths);

    try std.testing.expectEqualStrings("{exe_dir}", config.command[2]);
}

test "templated JSON command supports raw quotes and args splicing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const paths = RuntimePaths{
        .exe_path = "C:\\Bundle\\bin\\tool.exe",
        .exe_dir = "C:\\Bundle\\bin",
        .exe_name = "tool.exe",
        .exe_stem = "tool",
        .exe_parent = "C:\\Bundle",
        .launch_cwd = "C:\\work",
    };
    var env_map = std.process.EnvMap.init(allocator);
    const args = [_][]const u8{ "--input", "file.json", "--verbose" };
    const json =
        \\{
        \\  "terminal": true,
        \\  "cwd": "@{exe_dir:parent:join("app")}",
        \\  "command": [
        \\    "@{exe_dir:parent:join("python"):join("python.exe")}",
        \\    "-m",
        \\    "my_module",
        \\    @{args}
        \\  ]
        \\}
    ;

    const config = try parseConfigWithOptions(allocator, json, .{
        .paths = paths,
        .args0 = ".\\tool.exe",
        .args = &args,
        .env_map = &env_map,
    });

    try std.testing.expect(config.terminal);
    try std.testing.expectEqualStrings("C:\\Bundle\\app", config.cwd);
    try std.testing.expectEqual(@as(usize, 6), config.command.len);
    try std.testing.expectEqualStrings("C:\\Bundle\\python\\python.exe", config.command[0]);
    try std.testing.expectEqualStrings("--input", config.command[3]);
    try std.testing.expectEqualStrings("file.json", config.command[4]);
    try std.testing.expectEqualStrings("--verbose", config.command[5]);
}

test "environment values mutate in source order and command sees final env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const paths = RuntimePaths{
        .exe_path = "C:\\Bundle\\bin\\tool.exe",
        .exe_dir = "C:\\Bundle\\bin",
        .exe_name = "tool.exe",
        .exe_stem = "tool",
        .exe_parent = "C:\\Bundle",
        .launch_cwd = "C:\\work",
    };
    var env_map = std.process.EnvMap.init(allocator);
    try env_map.put("PATH", "C:\\Windows");
    const json =
        \\{
        \\  "env": {
        \\    "PATH": "@{env:"PATH":prepend_env(exe_parent:join("python"))}",
        \\    "PATH_AFTER": "@{env:"PATH"}"
        \\  },
        \\  "command": ["@{env:"PATH_AFTER"}"]
        \\}
    ;

    const config = try parseConfigWithOptions(allocator, json, .{
        .paths = paths,
        .args0 = "tool.exe",
        .args = &.{},
        .env_map = &env_map,
    });

    try std.testing.expectEqualStrings("C:\\Bundle\\python;C:\\Windows", config.env[0].value);
    try std.testing.expectEqualStrings("C:\\Bundle\\python;C:\\Windows", config.env[1].value);
    try std.testing.expectEqualStrings("C:\\Bundle\\python;C:\\Windows", config.command[0]);
}

test "strict missing environment and arg index failures are reported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };
    var env_map = std.process.EnvMap.init(allocator);

    try std.testing.expectError(error.MissingEnvironmentVariable, parseConfigWithOptions(
        allocator,
        "{\"error_on_missing_env\":true,\"command\":[\"@{env:\"MISSING\"}\"]}",
        .{ .paths = paths, .env_map = &env_map },
    ));

    const args = [_][]const u8{"only-one"};
    try std.testing.expectError(error.ArgumentOutOfBounds, parseConfigWithOptions(
        allocator,
        "{\"error_on_arg_out_of_bounds\":true,\"command\":[\"@{args:2}\"]}",
        .{ .paths = paths, .args = &args, .env_map = &env_map },
    ));
}

test "rejects unsafe list contexts object key templates and duplicate keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const paths = RuntimePaths{
        .exe_path = "C:\\apps\\demo\\demo.exe",
        .exe_dir = "C:\\apps\\demo",
        .exe_name = "demo.exe",
        .exe_stem = "demo",
        .launch_cwd = "C:\\work",
    };
    var env_map = std.process.EnvMap.init(allocator);
    const args = [_][]const u8{ "a", "b" };

    try std.testing.expectError(error.ListTemplateNotAllowedInString, parseConfigWithOptions(
        allocator,
        "{\"command\":[\"prefix @{args} suffix\"]}",
        .{ .paths = paths, .args = &args, .env_map = &env_map },
    ));

    try std.testing.expectError(error.TemplateInObjectKey, parseConfigWithOptions(
        allocator,
        "{\"env\":{\"@{exe_filename}\":\"value\"},\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .args = &.{}, .env_map = &env_map },
    ));

    try std.testing.expectError(error.DuplicateJsonKey, parseConfigWithOptions(
        allocator,
        "{\"command\":[\"one\"],\"command\":[\"two\"]}",
        .{ .paths = paths, .args = &.{}, .env_map = &env_map },
    ));
}

test "duplicate key scanner releases temporary object maps" {
    const allocator = std.testing.allocator;
    try rejectDuplicateKeys(
        allocator,
        "{\"a\":1,\"b\":{\"c\":2,\"d\":3},\"e\":[{\"f\":4},{\"g\":5}]}",
    );
}
