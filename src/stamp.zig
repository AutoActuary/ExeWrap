const std = @import("std");
const launcher = @import("zig_launcher");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 4) {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll(
            "usage: zig-launcher-stamp <base-exe> <config.json> <output-exe>\n",
        );
        std.process.exit(2);
    }

    const base = try std.fs.cwd().readFileAlloc(allocator, args[1], launcher.max_exe_bytes);
    defer allocator.free(base);
    const config = try std.fs.cwd().readFileAlloc(allocator, args[2], 1024 * 1024);
    defer allocator.free(config);

    const output = try std.fs.cwd().createFile(args[3], .{ .truncate = true });
    defer output.close();

    const marker = launcher.markerBytes();
    try output.writeAll(base);
    try output.writeAll(&marker);
    try output.writeAll(config);
}
