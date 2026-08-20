const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSmall;
    const release_small = optimize == .ReleaseSmall;

    const mod = b.addModule("exewrap", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = release_small,
        .single_threaded = true,
        .omit_frame_pointer = release_small,
    });

    const launcher_console = b.addExecutable(.{
        .name = "ExeWrap-console",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = release_small,
            .single_threaded = true,
            .omit_frame_pointer = release_small,
            .imports = &.{
                .{ .name = "exewrap", .module = mod },
            },
        }),
    });
    launcher_console.subsystem = .Console;
    b.installArtifact(launcher_console);

    const launcher_windowed = b.addExecutable(.{
        .name = "ExeWrap-windowed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = release_small,
            .single_threaded = true,
            .omit_frame_pointer = release_small,
            .imports = &.{
                .{ .name = "exewrap", .module = mod },
            },
        }),
    });
    launcher_windowed.subsystem = .Windows;
    b.installArtifact(launcher_windowed);

    const stamp = b.addExecutable(.{
        .name = "ExeWrap-stamper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stamp.zig"),
            .target = target,
            .optimize = optimize,
            .strip = release_small,
            .single_threaded = true,
            .omit_frame_pointer = release_small,
            .imports = &.{
                .{ .name = "exewrap", .module = mod },
            },
        }),
    });
    b.installArtifact(stamp);

    const tests = b.addTest(.{
        .root_module = mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const stamp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stamp.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "exewrap", .module = mod },
            },
        }),
    });
    const run_stamp_tests = b.addRunArtifact(stamp_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_stamp_tests.step);
}
