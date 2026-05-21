const std = @import("std");
const builtin = @import("builtin");
const launcher = @import("exewrap");
const windows = std.os.windows;

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x00002000;
const JobObjectExtendedLimitInformation: u32 = 9;
const max_pe_probe_bytes: usize = 4 * 1024 * 1024;

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

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const exe_path = try std.fs.selfExePathAlloc(scratch);
    const paths = try launcher.RuntimePaths.init(scratch, exe_path);
    const config_bytes = try launcher.readEmbeddedConfig(scratch, exe_path);

    var env_map = try std.process.getEnvMap(scratch);

    const process_args = try std.process.argsAlloc(scratch);
    const args0 = if (process_args.len > 0) process_args[0] else exe_path;
    var user_args: std.ArrayList([]const u8) = .empty;
    for (process_args[1..]) |arg| {
        try user_args.append(scratch, arg);
    }

    const config = try launcher.parseConfigWithOptions(scratch, config_bytes, .{
        .paths = paths,
        .args0 = args0,
        .args = user_args.items,
        .env_map = &env_map,
    });

    const resolved_command = try launcher.command_resolve.resolveCommandForSpawn(scratch, config.command, .{
        .cwd = config.cwd,
        .env_map = &env_map,
    });

    var child = std.process.Child.init(resolved_command.argv, scratch);
    child.cwd = config.cwd;
    child.env_map = &env_map;

    const terminal_visible = switch (config.terminal) {
        .visible => true,
        .hidden => false,
        .auto => detectTerminalVisibility(scratch, resolved_command.executable_path),
    };

    child.create_no_window = !terminal_visible;

    if (terminal_visible) {
        child.stdin_behavior = .Inherit;
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    } else {
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
    }

    const term = if (config.kill_children_on_exit and builtin.os.tag == .windows)
        try spawnWithKillOnCloseJob(&child)
    else
        try child.spawnAndWait();

    switch (term) {
        .Exited => |code| std.process.exit(code),
        .Signal => |_| std.process.exit(1),
        .Stopped => |_| std.process.exit(1),
        .Unknown => |_| std.process.exit(1),
    }
}

fn detectTerminalVisibility(
    allocator: std.mem.Allocator,
    executable_path: []const u8,
) bool {
    const bytes = std.fs.cwd().readFileAlloc(allocator, executable_path, max_pe_probe_bytes) catch return true;
    const subsystem = launcher.windowsSubsystemFromPeBytes(bytes) catch return true;
    return launcher.terminalVisibleFromWindowsSubsystem(subsystem) orelse true;
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
