const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;

    const mod = b.addModule("zig_launcher", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = true,
        .single_threaded = true,
        .omit_frame_pointer = true,
    });

    const launcher = b.addExecutable(.{
        .name = "zig-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .single_threaded = true,
            .omit_frame_pointer = true,
            .imports = &.{
                .{ .name = "zig_launcher", .module = mod },
            },
        }),
    });
    launcher.subsystem = .Windows;
    b.installArtifact(launcher);

    const stamp = b.addExecutable(.{
        .name = "zig-launcher-stamp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stamp.zig"),
            .target = target,
            .optimize = optimize,
            .strip = true,
            .single_threaded = true,
            .omit_frame_pointer = true,
            .imports = &.{
                .{ .name = "zig_launcher", .module = mod },
            },
        }),
    });
    b.installArtifact(stamp);

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
