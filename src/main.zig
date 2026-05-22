const std = @import("std");
const builtin = @import("builtin");
const launcher = @import("exewrap");
const windows = std.os.windows;

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x00002000;
const JobObjectExtendedLimitInformation: u32 = 9;

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: i64 = 0,
    PerJobUserTimeLimit: i64 = 0,
    LimitFlags: u32 = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: u32 = 0,
    Affinity: usize = 0,
    PriorityClass: u32 = 0,
    SchedulingClass: u32 = 0,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*anyopaque,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?windows.HANDLE;

extern "kernel32" fn SetInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInfoClass: u32,
    lpJobObjectInfo: *const anyopaque,
    cbJobObjectInfoLength: windows.DWORD,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.winapi) windows.DWORD;

pub fn main() void {
    run() catch std.process.exit(1);
}

fn run() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const exe_path = try std.fs.selfExePathAlloc(scratch);
    const paths = try launcher.RuntimePaths.init(scratch, exe_path);
    const exe_bytes = std.fs.cwd().readFileAlloc(scratch, exe_path, launcher.max_exe_bytes) catch |err| {
        reportExeReadError(exe_path, err);
        return err;
    };
    const config_bytes = launcher.embeddedConfigFromBytes(exe_bytes) catch |err| {
        reportEmbeddedConfigError(exe_path, err);
        return err;
    };

    var env_map = try std.process.getEnvMap(scratch);

    const process_args = try std.process.argsAlloc(scratch);
    const args0 = if (process_args.len > 0) process_args[0] else exe_path;
    var user_args: std.ArrayList([]const u8) = .empty;
    for (process_args[1..]) |arg| {
        try user_args.append(scratch, arg);
    }

    const config = launcher.parseConfigWithOptions(scratch, config_bytes, .{
        .paths = paths,
        .args0 = args0,
        .args = user_args.items,
        .env_map = &env_map,
    }) catch |err| {
        reportConfigError(err);
        return err;
    };

    const launcher_subsystem = launcher.windowsSubsystemFromPeBytes(exe_bytes) catch .windows_console;
    const inherit_stdio = launcher.childShouldInheritStdio(launcher_subsystem);

    var child = std.process.Child.init(config.command, scratch);
    child.cwd = config.cwd;
    child.env_map = &env_map;
    child.create_no_window = !inherit_stdio;

    if (inherit_stdio) {
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    } else {
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
    }

    const term = if (config.kill_children_on_exit and builtin.os.tag == .windows)
        spawnWithKillOnCloseJob(&child)
    else
        child.spawnAndWait();

    const child_term = term catch |err| {
        reportLaunchError(config.command[0], config.cwd, err);
        return err;
    };

    switch (child_term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |_| std.process.exit(1),
        .Stopped => |_| std.process.exit(1),
        .Unknown => |_| std.process.exit(1),
    }
}

fn reportExeReadError(exe_path: []const u8, err: anyerror) void {
    std.debug.print("ExeWrap error: failed to read launcher executable {s}: {s}\n", .{ exe_path, @errorName(err) });
}

fn reportEmbeddedConfigError(exe_path: []const u8, err: anyerror) void {
    switch (err) {
        error.NoEmbeddedConfig => std.debug.print(
            "ExeWrap error: no embedded config found in {s}. Did you run the unstamped base launcher?\n",
            .{exe_path},
        ),
        error.EmptyEmbeddedConfig => std.debug.print(
            "ExeWrap error: embedded config in {s} is empty.\n",
            .{exe_path},
        ),
        error.ConfigMustBeUtf8 => std.debug.print(
            "ExeWrap config error: embedded config in {s} must be UTF-8.\n",
            .{exe_path},
        ),
        else => std.debug.print(
            "ExeWrap error: failed to read embedded config from {s}: {s}\n",
            .{ exe_path, @errorName(err) },
        ),
    }
}

fn reportConfigError(err: anyerror) void {
    switch (err) {
        error.TerminalConfigRemoved => std.debug.print(
            "ExeWrap config error: top-level key \"terminal\" was removed. Choose ExeWrap-console.exe or ExeWrap-windowed.exe, or pass ExeWrap-stamper.exe --subsystem console|windowed at stamp time.\n",
            .{},
        ),
        error.CommandMustBeLast => std.debug.print(
            "ExeWrap config error: \"command\" must be the final top-level field. Put setup fields such as cwd, env, kill_children_on_exit, error_on_missing_env, and error_on_arg_out_of_bounds before command.\n",
            .{},
        ),
        error.UnknownTopLevelKey => std.debug.print(
            "ExeWrap config error: unknown top-level key. Supported setup fields are cwd, env, kill_children_on_exit, error_on_missing_env, and error_on_arg_out_of_bounds; command must be last.\n",
            .{},
        ),
        error.MissingCommand => std.debug.print(
            "ExeWrap config error: missing required final top-level field \"command\".\n",
            .{},
        ),
        error.KillChildrenOnExitMustBeBoolean => std.debug.print(
            "ExeWrap config error: \"kill_children_on_exit\" must be a boolean.\n",
            .{},
        ),
        error.ErrorOnMissingEnvMustBeBoolean => std.debug.print(
            "ExeWrap config error: \"error_on_missing_env\" must be a boolean.\n",
            .{},
        ),
        error.ErrorOnArgOutOfBoundsMustBeBoolean => std.debug.print(
            "ExeWrap config error: \"error_on_arg_out_of_bounds\" must be a boolean.\n",
            .{},
        ),
        else => std.debug.print("ExeWrap config error: {s}\n", .{@errorName(err)}),
    }
}

fn reportLaunchError(command0: []const u8, cwd: []const u8, err: anyerror) void {
    if (err == error.FileNotFound) {
        std.debug.print("ExeWrap launch error: command[0] not found: {s}. cwd={s}\n", .{ command0, cwd });
    } else {
        std.debug.print("ExeWrap launch error: failed to start {s} from cwd {s}: {s}\n", .{ command0, cwd, @errorName(err) });
    }
}

fn spawnWithKillOnCloseJob(child: *std.process.Child) !std.process.Child.Term {
    const job = try createKillOnCloseJob();
    defer windows.CloseHandle(job);

    child.start_suspended = true;
    try child.spawn();
    errdefer _ = child.kill() catch {};

    if (AssignProcessToJobObject(job, child.id) == windows.FALSE) {
        return error.AssignProcessToJobObjectFailed;
    }
    if (ResumeThread(child.thread_handle) == std.math.maxInt(windows.DWORD)) {
        return error.ResumeThreadFailed;
    }

    return child.wait();
}

fn createKillOnCloseJob() !windows.HANDLE {
    const job = CreateJobObjectW(null, null) orelse return error.CreateJobObjectFailed;
    errdefer windows.CloseHandle(job);

    var limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION{};
    limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;

    if (SetInformationJobObject(
        job,
        JobObjectExtendedLimitInformation,
        &limits,
        @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == windows.FALSE) {
        return error.SetInformationJobObjectFailed;
    }

    return job;
}
