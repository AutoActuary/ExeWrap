const std = @import("std");
const builtin = @import("builtin");

pub const template_scan = @import("template_scan.zig");
pub const template_expr = @import("template_expr.zig");
pub const command_resolve = @import("command_resolve.zig");

pub const marker_uuid = "8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a";
pub const end_marker_uuid = "ce3beca3-7ed2-40a4-9133-f82198be1d7b";
pub const config_start_marker = marker_uuid;
pub const config_end_marker = end_marker_uuid;
pub const max_exe_bytes = 512 * 1024 * 1024;
pub const max_pe_probe_bytes: usize = 4 * 1024 * 1024;

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

pub const TerminalMode = enum {
    visible,
    hidden,
    auto,
};

pub const Config = struct {
    terminal: TerminalMode,
    kill_children_on_exit: bool,
    cwd: []const u8,
    command: []const []const u8,
    env: []const EnvVar,
};

pub const EmbeddedConfigRange = struct {
    marker_start: usize,
    config_start: usize,
    config_end: usize,
    suffix_start: usize,
    has_end_marker: bool,
};

pub fn readEmbeddedConfig(allocator: std.mem.Allocator, exe_path: []const u8) ![]const u8 {
    const bytes = try std.fs.cwd().readFileAlloc(allocator, exe_path, max_exe_bytes);
    return embeddedConfigFromBytes(bytes);
}

pub fn embeddedConfigFromBytes(bytes: []const u8) ![]const u8 {
    const range = embeddedConfigRangeFromBytes(bytes) orelse return error.NoEmbeddedConfig;
    const config = normalizeConfigBytes(bytes[range.config_start..range.config_end]);
    if (std.mem.trim(u8, config, " \t\r\n").len == 0) return error.EmptyEmbeddedConfig;
    try validateConfigBytes(config);
    return config;
}

pub fn embeddedConfigRangeFromBytes(bytes: []const u8) ?EmbeddedConfigRange {
    const search_start = peOverlayStartOffset(bytes) orelse 0;
    const marker_relative = std.mem.lastIndexOf(u8, bytes[search_start..], config_start_marker) orelse return null;
    const marker_start = search_start + marker_relative;
    const config_start = marker_start + config_start_marker.len;
    const remaining = bytes[config_start..];
    const end_relative = std.mem.indexOf(u8, remaining, config_end_marker);
    const config_end = if (end_relative) |index| config_start + index else bytes.len;
    const suffix_start = if (end_relative) |_| config_end else bytes.len;
    return .{
        .marker_start = marker_start,
        .config_start = config_start,
        .config_end = config_end,
        .suffix_start = suffix_start,
        .has_end_marker = end_relative != null,
    };
}

fn peOverlayStartOffset(bytes: []const u8) ?usize {
    const dos_lfanew_offset = 0x3c;
    if (bytes.len < dos_lfanew_offset + @sizeOf(u32)) return null;
    if (!std.mem.eql(u8, bytes[0..2], "MZ")) return null;

    const pe_offset: usize = @intCast(readLittleInt(u32, bytes, dos_lfanew_offset));
    if (pe_offset > bytes.len or bytes.len - pe_offset < 24) return null;
    if (!std.mem.eql(u8, bytes[pe_offset..][0..4], "PE\x00\x00")) return null;

    const section_count: usize = readLittleInt(u16, bytes, pe_offset + 6);
    const optional_header_size: usize = readLittleInt(u16, bytes, pe_offset + 20);
    const optional_header_offset = pe_offset + 24;
    if (optional_header_offset > bytes.len or optional_header_size > bytes.len - optional_header_offset) return null;

    const section_header_size = 40;
    const section_table_offset = optional_header_offset + optional_header_size;
    if (section_table_offset > bytes.len) return null;
    if (section_count > (bytes.len - section_table_offset) / section_header_size) return null;

    var overlay_start = section_table_offset + section_count * section_header_size;
    for (0..section_count) |index| {
        const section_offset = section_table_offset + index * section_header_size;
        const raw_size: usize = @intCast(readLittleInt(u32, bytes, section_offset + 16));
        const raw_pointer: usize = @intCast(readLittleInt(u32, bytes, section_offset + 20));
        if (raw_size == 0) continue;
        if (raw_pointer > bytes.len or raw_size > bytes.len - raw_pointer) return null;
        overlay_start = @max(overlay_start, raw_pointer + raw_size);
    }

    if (optional_header_size >= @sizeOf(u16)) {
        const data_directories_offset = switch (readLittleInt(u16, bytes, optional_header_offset)) {
            0x10b => @as(usize, 96),
            0x20b => @as(usize, 112),
            else => return null,
        };
        const security_directory_offset = data_directories_offset + 4 * 8;
        if (optional_header_size >= security_directory_offset + 8) {
            const directory_offset = optional_header_offset + security_directory_offset;
            const certificate_pointer: usize = @intCast(readLittleInt(u32, bytes, directory_offset));
            const certificate_size: usize = @intCast(readLittleInt(u32, bytes, directory_offset + 4));
            if (certificate_pointer != 0 and certificate_size != 0) {
                if (certificate_pointer > bytes.len or certificate_size > bytes.len - certificate_pointer) return null;
                overlay_start = @max(overlay_start, certificate_pointer + certificate_size);
            }
        }
    }

    if (overlay_start > bytes.len) return null;
    return overlay_start;
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
    try validateTopLevelShape(root);

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

    const terminal = try parseTerminalMode(allocator, root, &eval_ctx, scanned.sentinels);
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

fn validateTopLevelShape(root: std.json.ObjectMap) !void {
    var saw_command = false;
    var it = root.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!isKnownTopLevelKey(key)) return error.UnknownTopLevelKey;
        if (saw_command) return error.CommandMustBeLast;
        if (std.mem.eql(u8, key, "command")) saw_command = true;
    }
    if (!saw_command) return error.MissingCommand;
}

fn isKnownTopLevelKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "command") or
        std.mem.eql(u8, key, "cwd") or
        std.mem.eql(u8, key, "env") or
        std.mem.eql(u8, key, "terminal") or
        std.mem.eql(u8, key, "kill_children_on_exit") or
        std.mem.eql(u8, key, "error_on_missing_env") or
        std.mem.eql(u8, key, "error_on_arg_out_of_bounds");
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

fn parseTerminalMode(
    allocator: std.mem.Allocator,
    root: std.json.ObjectMap,
    ctx: *template_expr.EvalContext,
    sentinels: []const template_scan.Sentinel,
) !TerminalMode {
    const value = root.get("terminal") orelse return .auto;
    return switch (value) {
        .bool => |b| if (b) .visible else .hidden,
        .string => |s| {
            const resolved = try evalTemplateString(allocator, s, ctx, sentinels);
            if (std.mem.eql(u8, resolved, "auto")) return .auto;
            return error.InvalidTerminalMode;
        },
        else => error.InvalidTerminalMode,
    };
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

pub const WindowsSubsystem = enum {
    native,
    windows_gui,
    windows_console,
    other,
};

pub fn windowsSubsystemFromPeBytes(bytes: []const u8) !WindowsSubsystem {
    const dos_lfanew_offset = 0x3c;
    if (bytes.len < dos_lfanew_offset + @sizeOf(u32)) return error.InvalidPeFile;
    if (!std.mem.eql(u8, bytes[0..2], "MZ")) return error.InvalidPeFile;

    const pe_offset = readLittleInt(u32, bytes, dos_lfanew_offset);
    const pe_offset_usize: usize = @intCast(pe_offset);
    if (pe_offset_usize > bytes.len or bytes.len - pe_offset_usize < 24) return error.InvalidPeFile;
    if (!std.mem.eql(u8, bytes[pe_offset_usize..][0..4], "PE\x00\x00")) return error.InvalidPeFile;

    const optional_header_size = readLittleInt(u16, bytes, pe_offset_usize + 20);
    const optional_header_offset = pe_offset_usize + 24;
    const subsystem_offset = optional_header_offset + 68;
    if (optional_header_size < 70 or subsystem_offset + @sizeOf(u16) > bytes.len) return error.InvalidPeFile;

    const magic = readLittleInt(u16, bytes, optional_header_offset);
    if (magic != 0x10b and magic != 0x20b) return error.InvalidPeFile;

    return switch (readLittleInt(u16, bytes, subsystem_offset)) {
        1 => .native,
        2 => .windows_gui,
        3 => .windows_console,
        else => .other,
    };
}

pub fn terminalVisibleFromWindowsSubsystem(subsystem: WindowsSubsystem) ?bool {
    return switch (subsystem) {
        .windows_console => true,
        .windows_gui => false,
        else => null,
    };
}

pub fn detectTerminalVisibility(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
) bool {
    const bytes = std.fs.cwd().readFileAlloc(allocator, executable_path, max_pe_probe_bytes) catch return true;
    defer allocator.free(bytes);
    const subsystem = windowsSubsystemFromPeBytes(bytes) catch return true;
    return terminalVisibleFromWindowsSubsystem(subsystem) orelse true;
}

fn readLittleInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
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

    try std.testing.expectEqual(TerminalMode.auto, config.terminal);
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

test "overlay markers are documented ASCII UUID strings" {
    try std.testing.expectEqualStrings("8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a", config_start_marker);
    try std.testing.expectEqualStrings("ce3beca3-7ed2-40a4-9133-f82198be1d7b", config_end_marker);
}

test "windows PE subsystem inspection identifies console and GUI executables" {
    var bytes = [_]u8{0} ** 256;
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3c..][0..4], 0x80, .little);
    @memcpy(bytes[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, bytes[0x80 + 20 ..][0..2], 0xf0, .little);
    std.mem.writeInt(u16, bytes[0x80 + 24 ..][0..2], 0x20b, .little);

    std.mem.writeInt(u16, bytes[0x80 + 24 + 68 ..][0..2], 3, .little);
    const console = try windowsSubsystemFromPeBytes(&bytes);
    try std.testing.expectEqual(WindowsSubsystem.windows_console, console);
    try std.testing.expectEqual(true, terminalVisibleFromWindowsSubsystem(console).?);

    std.mem.writeInt(u16, bytes[0x80 + 24 + 68 ..][0..2], 2, .little);
    const gui = try windowsSubsystemFromPeBytes(&bytes);
    try std.testing.expectEqual(WindowsSubsystem.windows_gui, gui);
    try std.testing.expectEqual(false, terminalVisibleFromWindowsSubsystem(gui).?);

    try std.testing.expectError(error.InvalidPeFile, windowsSubsystemFromPeBytes("not pe"));
}

test "windows PE subsystem inspection rejects malformed inputs without overread" {
    try std.testing.expectError(error.InvalidPeFile, windowsSubsystemFromPeBytes(""));
    try std.testing.expectError(error.InvalidPeFile, windowsSubsystemFromPeBytes("MZ"));

    var bad_offset = [_]u8{0} ** 0x40;
    bad_offset[0] = 'M';
    bad_offset[1] = 'Z';
    std.mem.writeInt(u32, bad_offset[0x3c..][0..4], 0x80, .little);
    try std.testing.expectError(error.InvalidPeFile, windowsSubsystemFromPeBytes(&bad_offset));

    var bad_signature = [_]u8{0} ** 0x100;
    bad_signature[0] = 'M';
    bad_signature[1] = 'Z';
    std.mem.writeInt(u32, bad_signature[0x3c..][0..4], 0x80, .little);
    try std.testing.expectError(error.InvalidPeFile, windowsSubsystemFromPeBytes(&bad_signature));

    var short_optional = [_]u8{0} ** 0x100;
    short_optional[0] = 'M';
    short_optional[1] = 'Z';
    std.mem.writeInt(u32, short_optional[0x3c..][0..4], 0x80, .little);
    @memcpy(short_optional[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, short_optional[0x80 + 20 ..][0..2], 2, .little);
    try std.testing.expectError(error.InvalidPeFile, windowsSubsystemFromPeBytes(&short_optional));

    var bad_magic = [_]u8{0} ** 0x100;
    bad_magic[0] = 'M';
    bad_magic[1] = 'Z';
    std.mem.writeInt(u32, bad_magic[0x3c..][0..4], 0x80, .little);
    @memcpy(bad_magic[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, bad_magic[0x80 + 20 ..][0..2], 0xf0, .little);
    std.mem.writeInt(u16, bad_magic[0x80 + 24 ..][0..2], 0x999, .little);
    try std.testing.expectError(error.InvalidPeFile, windowsSubsystemFromPeBytes(&bad_magic));
}

test "windows PE subsystem inspection handles host console and GUI executables" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const system_root = std.process.getEnvVarOwned(allocator, "SystemRoot") catch return error.SkipZigTest;
    defer allocator.free(system_root);

    const cmd_path = try std.fs.path.join(allocator, &.{ system_root, "System32", "cmd.exe" });
    defer allocator.free(cmd_path);
    const notepad_path = try std.fs.path.join(allocator, &.{ system_root, "System32", "notepad.exe" });
    defer allocator.free(notepad_path);

    const cmd_bytes = try std.fs.cwd().readFileAlloc(allocator, cmd_path, 4 * 1024 * 1024);
    defer allocator.free(cmd_bytes);
    const notepad_bytes = try std.fs.cwd().readFileAlloc(allocator, notepad_path, 4 * 1024 * 1024);
    defer allocator.free(notepad_bytes);

    try std.testing.expectEqual(WindowsSubsystem.windows_console, try windowsSubsystemFromPeBytes(cmd_bytes));
    try std.testing.expectEqual(WindowsSubsystem.windows_gui, try windowsSubsystemFromPeBytes(notepad_bytes));
}

test "terminal auto visibility probe handles ragtag command paths" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const system_root = std.process.getEnvVarOwned(allocator, "SystemRoot") catch return error.SkipZigTest;
    defer allocator.free(system_root);

    var checked: usize = 0;
    checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ system_root, "System32", "cmd.exe" }), true);
    checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ system_root, "System32", "where.exe" }), true);
    checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ system_root, "System32", "notepad.exe" }), false);
    checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ system_root, "System32", "wscript.exe" }), false);
    checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ system_root, "System32", "WindowsPowerShell", "v1.0", "powershell.exe" }), true);
    checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ system_root, "SysWOW64", "cmd.exe" }), true);

    if (std.process.getEnvVarOwned(allocator, "ProgramFiles")) |program_files| {
        defer allocator.free(program_files);
        checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ program_files, "7-Zip", "7z.exe" }), true);
        checked += try expectAutoVisibilityIfExists(allocator, try std.fs.path.join(allocator, &.{ program_files, "7-Zip", "7zFM.exe" }), false);
    } else |_| {}

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "probe.cmd", .data = "@echo off\r\n" });
    try tmp.dir.writeFile(.{ .sub_path = "probe.bat", .data = "@echo off\r\n" });
    try tmp.dir.writeFile(.{ .sub_path = "plain.txt", .data = "plain text is not a PE file\r\n" });
    try tmp.dir.writeFile(.{ .sub_path = "truncated.exe", .data = "MZ" });

    const cmd_script = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "probe.cmd" });
    defer allocator.free(cmd_script);
    const bat_script = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "probe.bat" });
    defer allocator.free(bat_script);
    const text_file = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "plain.txt" });
    defer allocator.free(text_file);
    const truncated_exe = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "truncated.exe" });
    defer allocator.free(truncated_exe);
    const missing_exe = try std.fs.path.join(allocator, &.{ ".zig-cache", "tmp", tmp.sub_path[0..], "missing.exe" });
    defer allocator.free(missing_exe);

    try std.testing.expectEqual(true, detectTerminalVisibility(allocator, cmd_script));
    try std.testing.expectEqual(true, detectTerminalVisibility(allocator, bat_script));
    try std.testing.expectEqual(true, detectTerminalVisibility(allocator, text_file));
    try std.testing.expectEqual(true, detectTerminalVisibility(allocator, truncated_exe));
    try std.testing.expectEqual(true, detectTerminalVisibility(allocator, missing_exe));
    try std.testing.expect(checked >= 4);
}

test "embedded config ignores marker literals inside PE image" {
    var bytes = [_]u8{0} ** 0x300;
    writeMinimalPeHeader(&bytes, 0x200, 0x100);
    @memcpy(bytes[0x220..][0..config_start_marker.len], config_start_marker);

    try std.testing.expect(embeddedConfigRangeFromBytes(&bytes) == null);
    try std.testing.expectError(error.NoEmbeddedConfig, embeddedConfigFromBytes(&bytes));
}

test "embedded config scans PE overlay after image data" {
    const config_text = "{\"command\":[\"cmd.exe\"]}";
    var bytes = [_]u8{0} ** (0x300 + config_start_marker.len + config_text.len);
    writeMinimalPeHeader(&bytes, 0x200, 0x100);
    @memcpy(bytes[0x220..][0..config_start_marker.len], config_start_marker);
    @memcpy(bytes[0x300..][0..config_start_marker.len], config_start_marker);
    @memcpy(bytes[0x300 + config_start_marker.len ..][0..config_text.len], config_text);

    const range = embeddedConfigRangeFromBytes(&bytes).?;
    try std.testing.expectEqual(@as(usize, 0x300), range.marker_start);
    try std.testing.expectEqualStrings(config_text, try embeddedConfigFromBytes(&bytes));
}

fn writeMinimalPeHeader(bytes: []u8, raw_pointer: u32, raw_size: u32) void {
    bytes[0] = 'M';
    bytes[1] = 'Z';
    std.mem.writeInt(u32, bytes[0x3c..][0..4], 0x80, .little);
    @memcpy(bytes[0x80..][0..4], "PE\x00\x00");
    std.mem.writeInt(u16, bytes[0x80 + 6 ..][0..2], 1, .little);
    std.mem.writeInt(u16, bytes[0x80 + 20 ..][0..2], 0xf0, .little);
    std.mem.writeInt(u16, bytes[0x80 + 24 ..][0..2], 0x20b, .little);

    const section_offset = 0x80 + 24 + 0xf0;
    std.mem.writeInt(u32, bytes[section_offset + 16 ..][0..4], raw_size, .little);
    std.mem.writeInt(u32, bytes[section_offset + 20 ..][0..4], raw_pointer, .little);
}

fn expectAutoVisibilityIfExists(
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: bool,
) !usize {
    defer allocator.free(path);
    std.fs.cwd().access(path, .{}) catch return 0;
    try std.testing.expectEqual(expected, detectTerminalVisibility(allocator, path));
    return 1;
}

test "embedded config reads to EOF when end marker is absent" {
    const bytes = "base bytes" ++ config_start_marker ++ "{\"command\":[\"cmd.exe\"]}";
    const config = try embeddedConfigFromBytes(bytes);
    try std.testing.expectEqualStrings("{\"command\":[\"cmd.exe\"]}", config);
}

test "embedded config range reads to EOF when end marker is absent" {
    const bytes = "base bytes" ++ config_start_marker ++ "{\"command\":[\"cmd.exe\"]}";
    const range = embeddedConfigRangeFromBytes(bytes).?;
    try std.testing.expectEqual(@as(usize, "base bytes".len), range.marker_start);
    try std.testing.expectEqual(@as(usize, "base bytes".len + config_start_marker.len), range.config_start);
    try std.testing.expectEqual(@as(usize, bytes.len), range.config_end);
    try std.testing.expectEqual(@as(usize, bytes.len), range.suffix_start);
    try std.testing.expect(!range.has_end_marker);
}

test "embedded config reads between start and end markers" {
    const bytes = "base bytes" ++ config_start_marker ++ "{\"command\":[\"cmd.exe\"]}" ++ config_end_marker ++ "icon or other bytes";
    const config = try embeddedConfigFromBytes(bytes);
    try std.testing.expectEqualStrings("{\"command\":[\"cmd.exe\"]}", config);
}

test "embedded config range reads between start and end markers" {
    const config_text = "{\"command\":[\"cmd.exe\"]}";
    const suffix = config_end_marker ++ "icon or other bytes";
    const bytes = "base bytes" ++ config_start_marker ++ config_text ++ suffix;
    const range = embeddedConfigRangeFromBytes(bytes).?;
    try std.testing.expectEqual(@as(usize, "base bytes".len), range.marker_start);
    try std.testing.expectEqual(@as(usize, "base bytes".len + config_start_marker.len), range.config_start);
    try std.testing.expectEqual(@as(usize, "base bytes".len + config_start_marker.len + config_text.len), range.config_end);
    try std.testing.expectEqual(range.config_end, range.suffix_start);
    try std.testing.expect(range.has_end_marker);
}

test "embedded config uses the last start marker" {
    const bytes = "old" ++ config_start_marker ++ "{}" ++ "new" ++ config_start_marker ++ "{\"command\":[\"cmd.exe\"]}";
    const config = try embeddedConfigFromBytes(bytes);
    try std.testing.expectEqualStrings("{\"command\":[\"cmd.exe\"]}", config);
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

    try std.testing.expectEqual(TerminalMode.visible, config.terminal);
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

test "terminal mode defaults to auto and accepts strict values" {
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
    try env_map.put("TERMINAL_MODE", "auto");

    const default_config = try parseConfigWithOptions(
        allocator,
        "{\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    );
    try std.testing.expectEqual(TerminalMode.auto, default_config.terminal);

    const true_config = try parseConfigWithOptions(
        allocator,
        "{\"terminal\":true,\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    );
    try std.testing.expectEqual(TerminalMode.visible, true_config.terminal);

    const false_config = try parseConfigWithOptions(
        allocator,
        "{\"terminal\":false,\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    );
    try std.testing.expectEqual(TerminalMode.hidden, false_config.terminal);

    const auto_config = try parseConfigWithOptions(
        allocator,
        "{\"terminal\":\"@{env:\"TERMINAL_MODE\"}\",\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    );
    try std.testing.expectEqual(TerminalMode.auto, auto_config.terminal);

    try std.testing.expectError(error.InvalidTerminalMode, parseConfigWithOptions(
        allocator,
        "{\"terminal\":\"true\",\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    ));

    try std.testing.expectError(error.InvalidTerminalMode, parseConfigWithOptions(
        allocator,
        "{\"terminal\":1,\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    ));
}

test "command resolver uses final cwd PATH and PATHEXT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env_map = std.process.EnvMap.init(allocator);
    try env_map.put("PATH", "C:\\Ignored;C:\\Tools");
    try env_map.put("PATHEXT", ".PY;.EXE;.CMD");

    const mock = MockFiles{ .paths = &.{
        "C:\\App\\python.EXE",
        "C:\\Tools\\tool.CMD",
        "C:\\Tools\\script.PY",
        "C:\\Tools\\script.EXE",
    } };

    const command = [_][]const u8{ "python", "-V" };
    const resolved = try command_resolve.resolveCommandForSpawn(allocator, &command, .{
        .cwd = "C:\\App",
        .env_map = &env_map,
        .file_exists = MockFiles.exists,
        .file_exists_context = &mock,
    });
    try std.testing.expect(resolved.found);
    try std.testing.expectEqualStrings("C:\\App\\python.EXE", resolved.executable_path);
    try std.testing.expectEqualStrings("C:\\App\\python.EXE", resolved.argv[0]);
    try std.testing.expectEqualStrings("-V", resolved.argv[1]);

    const path_command = [_][]const u8{ "tool", "arg" };
    const path_resolved = try command_resolve.resolveCommandForSpawn(allocator, &path_command, .{
        .cwd = "C:\\App",
        .env_map = &env_map,
        .file_exists = MockFiles.exists,
        .file_exists_context = &mock,
    });
    try std.testing.expect(path_resolved.found);
    try std.testing.expectEqualStrings("C:\\Tools\\tool.CMD", path_resolved.executable_path);
    try std.testing.expectEqualStrings("C:\\Tools\\tool.CMD", path_resolved.argv[0]);

    const unsupported_first = [_][]const u8{"script"};
    const unsupported_resolved = try command_resolve.resolveCommandForSpawn(allocator, &unsupported_first, .{
        .cwd = "C:\\App",
        .env_map = &env_map,
        .file_exists = MockFiles.exists,
        .file_exists_context = &mock,
    });
    try std.testing.expect(unsupported_resolved.found);
    try std.testing.expectEqualStrings("C:\\Tools\\script.EXE", unsupported_resolved.executable_path);
}

test "command resolver supports batch scripts but skips extensionless VBS" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env_map = std.process.EnvMap.init(allocator);
    try env_map.put("PATH", "C:\\Tools");
    try env_map.put("PATHEXT", ".VBS;.BAT;.CMD;.EXE");

    const mock = MockFiles{ .paths = &.{
        "C:\\Tools\\only_vbs.VBS",
        "C:\\Tools\\tool.BAT",
        "C:\\Tools\\script.CMD",
    } };

    const bat_command = [_][]const u8{"tool"};
    const bat_resolved = try command_resolve.resolveCommandForSpawn(allocator, &bat_command, .{
        .cwd = "C:\\App",
        .env_map = &env_map,
        .file_exists = MockFiles.exists,
        .file_exists_context = &mock,
    });
    try std.testing.expect(bat_resolved.found);
    try std.testing.expectEqualStrings("C:\\Tools\\tool.BAT", bat_resolved.executable_path);

    const cmd_command = [_][]const u8{"script"};
    const cmd_resolved = try command_resolve.resolveCommandForSpawn(allocator, &cmd_command, .{
        .cwd = "C:\\App",
        .env_map = &env_map,
        .file_exists = MockFiles.exists,
        .file_exists_context = &mock,
    });
    try std.testing.expect(cmd_resolved.found);
    try std.testing.expectEqualStrings("C:\\Tools\\script.CMD", cmd_resolved.executable_path);

    const vbs_command = [_][]const u8{"only_vbs"};
    const vbs_resolved = try command_resolve.resolveCommandForSpawn(allocator, &vbs_command, .{
        .cwd = "C:\\App",
        .env_map = &env_map,
        .file_exists = MockFiles.exists,
        .file_exists_context = &mock,
    });
    try std.testing.expect(!vbs_resolved.found);
    try std.testing.expectEqualStrings("only_vbs", vbs_resolved.executable_path);
}

test "command resolver leaves unresolved commands untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var env_map = std.process.EnvMap.init(allocator);
    try env_map.put("PATH", "C:\\Tools");

    const mock = MockFiles{ .paths = &.{} };
    const command = [_][]const u8{ "missing.exe", "arg" };
    const resolved = try command_resolve.resolveCommandForSpawn(allocator, &command, .{
        .cwd = "C:\\App",
        .env_map = &env_map,
        .file_exists = MockFiles.exists,
        .file_exists_context = &mock,
    });

    try std.testing.expect(!resolved.found);
    try std.testing.expectEqualStrings("missing.exe", resolved.executable_path);
    try std.testing.expectEqualStrings("missing.exe", resolved.argv[0]);
}

const MockFiles = struct {
    paths: []const []const u8,

    fn exists(context: ?*const anyopaque, path: []const u8) bool {
        const self: *const MockFiles = @ptrCast(@alignCast(context.?));
        for (self.paths) |candidate| {
            if (std.ascii.eqlIgnoreCase(candidate, path)) return true;
        }
        return false;
    }
};

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
        error.UnknownTopLevelKey,
        parseConfig(allocator, "{\"commandline\":[\"cmd.exe\"]}", paths),
    );
}

test "top-level keys are strict and command must be last" {
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

    try std.testing.expectError(error.UnknownTopLevelKey, parseConfigWithOptions(
        allocator,
        "{\"terminal\":true,\"foobar\":false,\"command\":[\"cmd.exe\"]}",
        .{ .paths = paths, .env_map = &env_map },
    ));

    try std.testing.expectError(error.CommandMustBeLast, parseConfigWithOptions(
        allocator,
        "{\"command\":[\"cmd.exe\"],\"terminal\":true}",
        .{ .paths = paths, .env_map = &env_map },
    ));

    try std.testing.expectError(error.MissingCommand, parseConfigWithOptions(
        allocator,
        "{\"terminal\":true}",
        .{ .paths = paths, .env_map = &env_map },
    ));
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

    try std.testing.expectEqual(TerminalMode.visible, config.terminal);
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
