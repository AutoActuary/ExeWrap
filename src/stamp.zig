const std = @import("std");
const builtin = @import("builtin");
const launcher = @import("exewrap");

const max_config_bytes = 1024 * 1024;
const icon_type = 1;
const rt_icon = 3;
const rt_group_icon = 14;
const default_group_icon_id = 1;
const neutral_language = 0;

const StampOptions = struct {
    launcher_path: []const u8,
    config_path: []const u8,
    icon_path: ?[]const u8,
    subsystem: StampSubsystem,
    output_path: []const u8,
};

const StampSubsystem = enum {
    inherit,
    console,
    windowed,
};

const IconImage = struct {
    width: u8,
    height: u8,
    color_count: u8,
    reserved: u8,
    planes: u16,
    bit_count: u16,
    bytes_in_res: u32,
    image_offset: u32,
    id: u16,
};

pub fn main() void {
    run() catch std.process.exit(1);
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);
    const options = parseArgs(args) catch |err| {
        try writeUsage();
        return err;
    };

    const base = try std.fs.cwd().readFileAlloc(allocator, options.launcher_path, launcher.max_exe_bytes);
    const config = try std.fs.cwd().readFileAlloc(allocator, options.config_path, max_config_bytes);
    try launcher.validateConfigBytes(config);
    const existing_range = launcher.embeddedConfigRangeFromBytes(base);

    {
        const output = try std.fs.cwd().createFile(options.output_path, .{ .truncate = true });
        defer output.close();
        try writeBaseBeforeConfig(output, base, existing_range);
    }

    if (options.icon_path) |icon_path| {
        try stampIcon(allocator, options.output_path, icon_path);
    }

    try applySubsystemOverride(options);

    {
        const output = try std.fs.cwd().openFile(options.output_path, .{ .mode = .write_only });
        defer output.close();
        try output.seekFromEnd(0);
        try writeConfigOverlay(output, base, config, existing_range);
    }
}

fn writeBaseBeforeConfig(output: std.fs.File, base: []const u8, existing_range: ?launcher.EmbeddedConfigRange) !void {
    if (existing_range) |range| {
        try output.writeAll(base[0..range.marker_start]);
    } else {
        try output.writeAll(base);
    }
}

fn writeConfigOverlay(output: std.fs.File, base: []const u8, config: []const u8, existing_range: ?launcher.EmbeddedConfigRange) !void {
    if (existing_range) |range| {
        try output.writeAll(launcher.config_start_marker);
        try output.writeAll(config);
        try output.writeAll(base[range.config_end..]);
    } else {
        try output.writeAll(launcher.config_start_marker);
        try output.writeAll(config);
    }
}

fn parseArgs(args: []const [:0]const u8) !StampOptions {
    var launcher_path: ?[]const u8 = null;
    var config_path: ?[]const u8 = null;
    var icon_path: ?[]const u8 = null;
    var subsystem: StampSubsystem = .inherit;
    var output_path: ?[]const u8 = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try writeUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--launcher")) {
            i += 1;
            if (i >= args.len) return error.MissingLauncherPath;
            launcher_path = args[i];
        } else if (std.mem.eql(u8, arg, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigPath;
            config_path = args[i];
        } else if (std.mem.eql(u8, arg, "--icon")) {
            i += 1;
            if (i >= args.len) return error.MissingIconPath;
            icon_path = args[i];
        } else if (std.mem.eql(u8, arg, "--subsystem")) {
            i += 1;
            if (i >= args.len) return error.MissingSubsystem;
            subsystem = try parseSubsystem(args[i]);
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.UnknownOption;
        } else if (output_path == null) {
            output_path = arg;
        } else {
            return error.TooManyOutputPaths;
        }
    }

    return .{
        .launcher_path = launcher_path orelse return error.MissingLauncherPath,
        .config_path = config_path orelse return error.MissingConfigPath,
        .icon_path = icon_path,
        .subsystem = subsystem,
        .output_path = output_path orelse return error.MissingOutputPath,
    };
}

fn parseSubsystem(value: []const u8) !StampSubsystem {
    if (std.mem.eql(u8, value, "inherit")) return .inherit;
    if (std.mem.eql(u8, value, "console")) return .console;
    if (std.mem.eql(u8, value, "windowed") or std.mem.eql(u8, value, "gui")) return .windowed;
    return error.InvalidSubsystem;
}

fn writeUsage() !void {
    const stderr = std.fs.File.stderr();
    try stderr.writeAll(
        \\usage: ExeWrap-stamper.exe --launcher <base-launcher.exe> --config <config.json> [--icon <logo.ico>] [--subsystem inherit|console|windowed|gui] <output.exe>
        \\
    );
}

fn applySubsystemOverride(options: StampOptions) !void {
    const subsystem: launcher.WindowsSubsystem = switch (options.subsystem) {
        .inherit => return,
        .console => .windows_console,
        .windowed => .windows_gui,
    };
    launcher.setWindowsSubsystem(options.output_path, subsystem) catch |err| {
        reportSubsystemPatchError(options.output_path, err);
        return err;
    };
}

fn reportSubsystemPatchError(output_path: []const u8, err: anyerror) void {
    switch (err) {
        error.InvalidPeFile => std.debug.print(
            "ExeWrap-stamper error: cannot set subsystem on malformed PE file: {s}\n",
            .{output_path},
        ),
        else => std.debug.print(
            "ExeWrap-stamper error: cannot set subsystem on {s}: {s}\n",
            .{ output_path, @errorName(err) },
        ),
    }
}

fn stampIcon(allocator: std.mem.Allocator, output_path: []const u8, icon_path: []const u8) !void {
    if (builtin.os.tag != .windows) return error.IconStampingRequiresWindows;

    const icon_bytes = try std.fs.cwd().readFileAlloc(allocator, icon_path, 16 * 1024 * 1024);
    const images = try parseIconDirectory(allocator, icon_bytes);
    const group_resource = try buildGroupIconResource(allocator, images);

    try updateIconResources(allocator, output_path, icon_bytes, images, group_resource);
}

fn parseIconDirectory(allocator: std.mem.Allocator, bytes: []const u8) ![]IconImage {
    if (bytes.len < 6) return error.InvalidIconFile;
    if (readInt(u16, bytes, 0) != 0) return error.InvalidIconFile;
    if (readInt(u16, bytes, 2) != icon_type) return error.InvalidIconFile;

    const count = readInt(u16, bytes, 4);
    if (count == 0) return error.InvalidIconFile;

    const entry_bytes = @as(usize, count) * 16;
    if (bytes.len < 6 + entry_bytes) return error.InvalidIconFile;

    const images = try allocator.alloc(IconImage, count);
    for (images, 0..) |*image, index| {
        const offset = 6 + index * 16;
        const bytes_in_res = readInt(u32, bytes, offset + 8);
        const image_offset = readInt(u32, bytes, offset + 12);
        const image_offset_usize = @as(usize, image_offset);
        const bytes_in_res_usize = @as(usize, bytes_in_res);
        if (image_offset_usize > bytes.len or bytes_in_res_usize > bytes.len - image_offset_usize) {
            return error.InvalidIconFile;
        }

        image.* = .{
            .width = bytes[offset],
            .height = bytes[offset + 1],
            .color_count = bytes[offset + 2],
            .reserved = bytes[offset + 3],
            .planes = readInt(u16, bytes, offset + 4),
            .bit_count = readInt(u16, bytes, offset + 6),
            .bytes_in_res = bytes_in_res,
            .image_offset = image_offset,
            .id = @intCast(index + 1),
        };
    }
    return images;
}

fn buildGroupIconResource(allocator: std.mem.Allocator, images: []const IconImage) ![]u8 {
    const group = try allocator.alloc(u8, 6 + images.len * 14);
    writeInt(u16, group, 0, 0);
    writeInt(u16, group, 2, icon_type);
    writeInt(u16, group, 4, @intCast(images.len));

    for (images, 0..) |image, index| {
        const offset = 6 + index * 14;
        group[offset] = image.width;
        group[offset + 1] = image.height;
        group[offset + 2] = image.color_count;
        group[offset + 3] = image.reserved;
        writeInt(u16, group, offset + 4, image.planes);
        writeInt(u16, group, offset + 6, image.bit_count);
        writeInt(u32, group, offset + 8, image.bytes_in_res);
        writeInt(u16, group, offset + 12, image.id);
    }
    return group;
}

fn updateIconResources(allocator: std.mem.Allocator, output_path: []const u8, icon_bytes: []const u8, images: []const IconImage, group_resource: []const u8) !void {
    const output_path_w = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, output_path);

    const handle = BeginUpdateResourceW(output_path_w.ptr, 0) orelse return error.BeginUpdateResourceFailed;
    var committed = false;
    defer {
        if (!committed) _ = EndUpdateResourceW(handle, 1);
    }

    for (images) |image| {
        const offset = @as(usize, image.image_offset);
        const len = @as(usize, image.bytes_in_res);
        const data = icon_bytes[offset .. offset + len];
        if (UpdateResourceW(handle, resourceId(rt_icon), resourceId(image.id), neutral_language, data.ptr, @intCast(data.len)) == 0) {
            return error.UpdateIconResourceFailed;
        }
    }

    if (UpdateResourceW(handle, resourceId(rt_group_icon), resourceId(default_group_icon_id), neutral_language, group_resource.ptr, @intCast(group_resource.len)) == 0) {
        return error.UpdateIconResourceFailed;
    }

    if (EndUpdateResourceW(handle, 0) == 0) return error.EndUpdateResourceFailed;
    committed = true;
}

fn resourceId(id: u16) std.os.windows.LPCWSTR {
    return @ptrFromInt(@as(usize, id));
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}

fn writeInt(comptime T: type, bytes: []u8, offset: usize, value: T) void {
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}

extern "kernel32" fn BeginUpdateResourceW(
    pFileName: std.os.windows.LPCWSTR,
    bDeleteExistingResources: std.os.windows.BOOL,
) callconv(.winapi) ?std.os.windows.HANDLE;

extern "kernel32" fn UpdateResourceW(
    hUpdate: std.os.windows.HANDLE,
    lpType: std.os.windows.LPCWSTR,
    lpName: std.os.windows.LPCWSTR,
    wLanguage: std.os.windows.WORD,
    lpData: ?*const anyopaque,
    cbData: std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn EndUpdateResourceW(
    hUpdate: std.os.windows.HANDLE,
    fDiscard: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

test "stamper arg parsing accepts subsystem values" {
    const args = [_][:0]const u8{
        "ExeWrap-stamper.exe",
        "--launcher",
        "ExeWrap-console.exe",
        "--config",
        "config.json",
        "--subsystem",
        "gui",
        "out.exe",
    };
    const options = try parseArgs(&args);

    try std.testing.expectEqualStrings("ExeWrap-console.exe", options.launcher_path);
    try std.testing.expectEqualStrings("config.json", options.config_path);
    try std.testing.expect(options.icon_path == null);
    try std.testing.expectEqual(StampSubsystem.windowed, options.subsystem);
    try std.testing.expectEqualStrings("out.exe", options.output_path);

    try std.testing.expectEqual(StampSubsystem.inherit, try parseSubsystem("inherit"));
    try std.testing.expectEqual(StampSubsystem.console, try parseSubsystem("console"));
    try std.testing.expectEqual(StampSubsystem.windowed, try parseSubsystem("windowed"));
    try std.testing.expectEqual(StampSubsystem.windowed, try parseSubsystem("gui"));
    try std.testing.expectError(error.InvalidSubsystem, parseSubsystem("hidden"));
}

test "stamper subsystem defaults to inherit" {
    const args = [_][:0]const u8{
        "ExeWrap-stamper.exe",
        "--launcher",
        "ExeWrap-windowed.exe",
        "--config",
        "config.json",
        "out.exe",
    };
    const options = try parseArgs(&args);

    try std.testing.expectEqual(StampSubsystem.inherit, options.subsystem);
}
