use std::ffi::{OsStr, OsString, c_void};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::{env, io, mem, ptr};

#[cfg(windows)]
use std::os::windows::io::AsRawHandle;
#[cfg(windows)]
use std::os::windows::process::CommandExt;

use crate::{
    EnvMap, Error, MAX_EXE_BYTES, ParseConfigOptions, Result, RuntimePaths, WindowsSubsystem,
    child_should_inherit_stdio, embedded_config_from_bytes, parse_config_with_options,
    read_file_limited, windows_subsystem_from_pe_bytes,
};

const CREATE_SUSPENDED: u32 = 0x0000_0004;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x0000_2000;
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS: u32 = 9;

pub fn main_entry() -> ! {
    if run().is_err() {
        std::process::exit(1);
    }
    std::process::exit(0)
}

fn run() -> Result<()> {
    let exe_path = env::current_exe()?;
    let exe_path_text = exe_path
        .to_str()
        .map(str::to_owned)
        .ok_or(Error::WindowsTextMustBeUnicode)?;
    let paths = RuntimePaths::init(exe_path_text.clone())?;
    let exe_bytes = read_executable(&exe_path).inspect_err(|error| {
        eprintln!(
            "ExeWrap error: failed to read launcher executable {}: {}",
            exe_path_text,
            error.tag()
        );
    })?;
    let config_bytes = embedded_config_from_bytes(&exe_bytes).inspect_err(|error| {
        report_embedded_config_error(&exe_path_text, error);
    })?;

    let mut environment = EnvMap::from_current();
    let process_args = env::args_os().collect::<Vec<_>>();
    let args0 = process_args
        .first()
        .and_then(|value| value.to_str())
        .unwrap_or(exe_path_text.as_str());
    let user_args = process_args.get(1..).unwrap_or(&[]);
    let config = parse_config_with_options(
        config_bytes,
        ParseConfigOptions {
            paths: &paths,
            args0,
            args: user_args,
            env_map: &mut environment,
        },
    )
    .inspect_err(|error| {
        report_config_error(error);
    })?;

    let subsystem =
        windows_subsystem_from_pe_bytes(&exe_bytes).unwrap_or(WindowsSubsystem::WindowsConsole);
    let inherit_stdio = child_should_inherit_stdio(subsystem);
    let status = spawn_and_wait(
        &config.command,
        &config.cwd,
        &environment,
        inherit_stdio,
        config.kill_children_on_exit,
    )
    .inspect_err(|error| {
        report_launch_error(&config.command[0], &config.cwd, error);
    })?;
    std::process::exit(compatible_exit_code(status.code()));
}

fn compatible_exit_code(code: Option<i32>) -> i32 {
    code.map_or(1, |value| i32::from(value as u8))
}

fn read_executable(path: &std::path::Path) -> Result<Vec<u8>> {
    read_file_limited(path, MAX_EXE_BYTES)
}

fn report_embedded_config_error(exe_path: &str, error: &Error) {
    match error {
        Error::NoEmbeddedConfig => eprintln!(
            "ExeWrap error: no embedded config found in {exe_path}. Did you run the unstamped base launcher?"
        ),
        Error::EmptyEmbeddedConfig => {
            eprintln!("ExeWrap error: embedded config in {exe_path} is empty.")
        }
        Error::ConfigMustBeUtf8 => {
            eprintln!("ExeWrap config error: embedded config in {exe_path} must be UTF-8.")
        }
        _ => eprintln!(
            "ExeWrap error: failed to read embedded config from {exe_path}: {}",
            error.tag()
        ),
    }
}

fn report_config_error(error: &Error) {
    match error {
        Error::TerminalConfigRemoved => eprintln!(
            "ExeWrap config error: top-level key \"terminal\" was removed. Choose ExeWrap-console.exe or ExeWrap-windowed.exe, or pass ExeWrap-stamper.exe --subsystem console|windowed at stamp time."
        ),
        Error::CommandMustBeLast => eprintln!(
            "ExeWrap config error: \"command\" must be the final top-level field. Put setup fields such as cwd, env, kill_children_on_exit, error_on_missing_env, and error_on_arg_out_of_bounds before command."
        ),
        Error::UnknownTopLevelKey => eprintln!(
            "ExeWrap config error: unknown top-level key. Supported setup fields are cwd, env, kill_children_on_exit, error_on_missing_env, and error_on_arg_out_of_bounds; command must be last."
        ),
        Error::MissingCommand => {
            eprintln!("ExeWrap config error: missing required final top-level field \"command\".")
        }
        Error::KillChildrenOnExitMustBeBoolean => {
            eprintln!("ExeWrap config error: \"kill_children_on_exit\" must be a boolean.")
        }
        Error::ErrorOnMissingEnvMustBeBoolean => {
            eprintln!("ExeWrap config error: \"error_on_missing_env\" must be a boolean.")
        }
        Error::ErrorOnArgOutOfBoundsMustBeBoolean => {
            eprintln!("ExeWrap config error: \"error_on_arg_out_of_bounds\" must be a boolean.")
        }
        Error::ExpectedIndexExpression => eprintln!(
            "ExeWrap config error: list indexes must be integers or end expressions such as args[1], args[end], or args[end-1]."
        ),
        Error::ExpectedOpenBracket => eprintln!(
            "ExeWrap config error: environment lookups must use bracketed keys such as env[\"PATH\"]."
        ),
        Error::ExpectedString => eprintln!(
            "ExeWrap config error: environment lookup keys and string arguments must be quoted."
        ),
        Error::ExpectedCloseBracket => eprintln!(
            "ExeWrap config error: bracket lookup, list index, or slice is missing a closing ]."
        ),
        Error::ExpectedColonOrCloseBracket => eprintln!(
            "ExeWrap config error: list slices must use args[start:stop] or args[start:step:stop]."
        ),
        Error::ZeroSliceStep => {
            eprintln!("ExeWrap config error: list slice step must not be zero.")
        }
        Error::IndexOutOfBounds => eprintln!(
            "ExeWrap config error: list indexes are 1-based; use args[1] for the first item and args[end] for the last item."
        ),
        Error::IndexExpressionOverflow | Error::IntegerOutOfRange => {
            eprintln!("ExeWrap config error: list index expression is too large.")
        }
        _ => eprintln!("ExeWrap config error: {}", error.tag()),
    }
}

fn report_launch_error(command0: &OsStr, cwd: &str, error: &Error) {
    let command0 = command0.to_string_lossy();
    if matches!(error, Error::Io(io_error) if io_error.kind() == io::ErrorKind::NotFound) {
        eprintln!("ExeWrap launch error: command[0] not found: {command0}. cwd={cwd}");
    } else {
        eprintln!(
            "ExeWrap launch error: failed to start {command0} from cwd {cwd}: {}",
            error.tag()
        );
    }
}

fn configured_command(
    command: &[OsString],
    cwd: &str,
    environment: &EnvMap,
    inherit_stdio: bool,
) -> Result<Command> {
    let program = resolve_program(&command[0], cwd);
    validate_batch_arguments(&program, &command[1..])?;
    let mut child = Command::new(program);
    child.args(&command[1..]);
    child.current_dir(cwd);
    child.env_clear();
    child.envs(environment.iter());
    if inherit_stdio {
        child.stdin(Stdio::inherit());
        child.stdout(Stdio::inherit());
        child.stderr(Stdio::inherit());
    } else {
        child.stdin(Stdio::null());
        child.stdout(Stdio::null());
        child.stderr(Stdio::null());
        #[cfg(windows)]
        child.creation_flags(CREATE_NO_WINDOW);
    }
    Ok(child)
}

fn validate_batch_arguments(program: &Path, arguments: &[OsString]) -> Result<()> {
    let is_batch = program
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("bat") || extension.eq_ignore_ascii_case("cmd")
        });
    if is_batch
        && arguments.iter().any(|argument| {
            #[cfg(windows)]
            {
                use std::os::windows::ffi::OsStrExt;
                argument
                    .encode_wide()
                    .any(|value| matches!(value, 0 | 10 | 13))
            }
            #[cfg(not(windows))]
            {
                argument
                    .to_string_lossy()
                    .chars()
                    .any(|value| matches!(value, '\0' | '\n' | '\r'))
            }
        })
    {
        Err(Error::InvalidBatchScriptArg)
    } else {
        Ok(())
    }
}

#[cfg(windows)]
fn resolve_program(program: &OsStr, cwd: &str) -> PathBuf {
    let program_path = Path::new(program);
    let Some(filename) = program_path.file_name() else {
        return program_path.to_owned();
    };
    let current_dir = env::current_dir().unwrap_or_default();
    let child_cwd = absolute_from(&current_dir, Path::new(cwd));

    let mut directories = Vec::new();
    if program_path.is_absolute() {
        directories.push(
            program_path
                .parent()
                .map_or_else(PathBuf::new, Path::to_owned),
        );
    } else if let Some(parent) = program_path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        directories.push(absolute_from(&child_cwd, parent));
    } else {
        directories.push(child_cwd);
        if let Some(path) = env::var_os("PATH") {
            directories
                .extend(env::split_paths(&path).filter(|entry| !entry.as_os_str().is_empty()));
        }
    }

    let extensions = env::var_os("PATHEXT")
        .map(|value| {
            value
                .to_string_lossy()
                .split(';')
                .filter(|extension| is_supported_windows_extension(extension))
                .map(str::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let explicit_path = program_path.is_absolute()
        || program_path
            .parent()
            .is_some_and(|parent| !parent.as_os_str().is_empty());
    let has_extension = Path::new(filename).extension().is_some();
    for directory in directories {
        let exact = directory.join(filename);
        if (explicit_path || has_extension) && exact.is_file() {
            return exact;
        }
        if !has_extension {
            for extension in &extensions {
                let mut extended = filename.to_os_string();
                extended.push(extension);
                let candidate = directory.join(extended);
                if candidate.is_file() {
                    return candidate;
                }
            }
        }
    }
    program_path.to_owned()
}

#[cfg(windows)]
fn absolute_from(base: &Path, path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_owned()
    } else {
        base.join(path)
    }
}

#[cfg(windows)]
fn is_supported_windows_extension(extension: &str) -> bool {
    [".BAT", ".CMD", ".COM", ".EXE"]
        .iter()
        .any(|supported| extension.eq_ignore_ascii_case(supported))
}

#[cfg(not(windows))]
fn resolve_program(program: &OsStr, _: &str) -> PathBuf {
    PathBuf::from(program)
}

fn spawn_and_wait(
    command: &[OsString],
    cwd: &str,
    environment: &EnvMap,
    inherit_stdio: bool,
    kill_children_on_exit: bool,
) -> Result<ExitStatus> {
    let mut child = configured_command(command, cwd, environment, inherit_stdio)?;
    if kill_children_on_exit && cfg!(windows) {
        spawn_with_kill_on_close_job(&mut child, inherit_stdio)
    } else {
        Ok(child.status()?)
    }
}

#[cfg(windows)]
fn spawn_with_kill_on_close_job(command: &mut Command, inherit_stdio: bool) -> Result<ExitStatus> {
    let job = create_kill_on_close_job()?;
    let flags = CREATE_SUSPENDED | if inherit_stdio { 0 } else { CREATE_NO_WINDOW };
    command.creation_flags(flags);
    let mut child = command.spawn()?;
    let process = child.as_raw_handle().cast::<c_void>();

    // SAFETY: `job` and `process` are live kernel handles owned by this scope and Child.
    if unsafe { AssignProcessToJobObject(job.0, process) } == 0 {
        let _ = child.kill();
        return Err(Error::AssignProcessToJobObjectFailed);
    }
    // SAFETY: `process` is a live child handle created with CREATE_SUSPENDED.
    if unsafe { NtResumeProcess(process) } < 0 {
        let _ = child.kill();
        return Err(Error::ResumeThreadFailed);
    }
    Ok(child.wait()?)
}

#[cfg(not(windows))]
fn spawn_with_kill_on_close_job(command: &mut Command, _: bool) -> Result<ExitStatus> {
    Ok(command.status()?)
}

#[repr(C)]
#[derive(Default)]
struct JobObjectBasicLimitInformation {
    per_process_user_time_limit: i64,
    per_job_user_time_limit: i64,
    limit_flags: u32,
    minimum_working_set_size: usize,
    maximum_working_set_size: usize,
    active_process_limit: u32,
    affinity: usize,
    priority_class: u32,
    scheduling_class: u32,
}

#[repr(C)]
#[derive(Default)]
struct IoCounters {
    read_operation_count: u64,
    write_operation_count: u64,
    other_operation_count: u64,
    read_transfer_count: u64,
    write_transfer_count: u64,
    other_transfer_count: u64,
}

#[repr(C)]
#[derive(Default)]
struct JobObjectExtendedLimitInformation {
    basic_limit_information: JobObjectBasicLimitInformation,
    io_info: IoCounters,
    process_memory_limit: usize,
    job_memory_limit: usize,
    peak_process_memory_used: usize,
    peak_job_memory_used: usize,
}

#[cfg(windows)]
struct OwnedHandle(*mut c_void);

#[cfg(windows)]
impl Drop for OwnedHandle {
    fn drop(&mut self) {
        // SAFETY: OwnedHandle is created only from a successful Win32 handle-returning API.
        unsafe { CloseHandle(self.0) };
    }
}

#[cfg(windows)]
fn create_kill_on_close_job() -> Result<OwnedHandle> {
    // SAFETY: null security attributes and name request an unnamed job with defaults.
    let job = unsafe { CreateJobObjectW(ptr::null(), ptr::null()) };
    if job.is_null() {
        return Err(Error::CreateJobObjectFailed);
    }
    let job = OwnedHandle(job);
    let mut limits = JobObjectExtendedLimitInformation::default();
    limits.basic_limit_information.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    // SAFETY: `limits` has the documented C layout and the byte count matches its type.
    if unsafe {
        SetInformationJobObject(
            job.0,
            JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS,
            (&raw const limits).cast(),
            mem::size_of::<JobObjectExtendedLimitInformation>() as u32,
        )
    } == 0
    {
        return Err(Error::SetInformationJobObjectFailed);
    }
    Ok(job)
}

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CreateJobObjectW(attributes: *const c_void, name: *const u16) -> *mut c_void;
    fn SetInformationJobObject(
        job: *mut c_void,
        information_class: u32,
        information: *const c_void,
        information_length: u32,
    ) -> i32;
    fn AssignProcessToJobObject(job: *mut c_void, process: *mut c_void) -> i32;
    fn CloseHandle(handle: *mut c_void) -> i32;
}

#[cfg(windows)]
#[link(name = "ntdll")]
unsafe extern "system" {
    fn NtResumeProcess(process: *mut c_void) -> i32;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn child_exit_codes_keep_v2_low_byte_behavior() {
        assert_eq!(compatible_exit_code(Some(0)), 0);
        assert_eq!(compatible_exit_code(Some(255)), 255);
        assert_eq!(compatible_exit_code(Some(256)), 0);
        assert_eq!(compatible_exit_code(Some(4660)), 52);
        assert_eq!(compatible_exit_code(None), 1);
    }
}
