use std::env;
use std::ffi::{OsStr, OsString, c_void};
use std::fs::{self, File, OpenOptions};
use std::io;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;

use crate::{
    CONFIG_START_MARKER, EmbeddedConfigRange, Error, MAX_EXE_BYTES, Result, WindowsSubsystem,
    embedded_config_range_from_bytes, pe_has_certificate_table, read_file_limited,
    set_windows_subsystem, validate_stampable_config,
};

const MAX_CONFIG_BYTES: u64 = 1024 * 1024;
const MAX_ICON_BYTES: u64 = 16 * 1024 * 1024;
const ICON_TYPE: u16 = 1;
const RT_ICON: u16 = 3;
const RT_GROUP_ICON: u16 = 14;
const DEFAULT_GROUP_ICON_ID: u16 = 1;
const NEUTRAL_LANGUAGE: u16 = 0;
const MOVE_FILE_REPLACE_EXISTING: u32 = 0x1;
const MOVE_FILE_WRITE_THROUGH: u32 = 0x8;
const INVALID_FILE_ATTRIBUTES: u32 = u32::MAX;

#[derive(Clone, Debug, Eq, PartialEq)]
struct StampOptions {
    launcher_path: PathBuf,
    config_path: PathBuf,
    icon_path: Option<PathBuf>,
    subsystem: StampSubsystem,
    output_path: PathBuf,
}

#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
enum StampSubsystem {
    #[default]
    Inherit,
    Console,
    Windowed,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct IconImage {
    width: u8,
    height: u8,
    color_count: u8,
    reserved: u8,
    planes: u16,
    bit_count: u16,
    bytes_in_res: u32,
    image_offset: u32,
    id: u16,
}

pub fn main_entry() -> ! {
    if let Err(error) = run() {
        match &error {
            Error::Io(source) => {
                eprintln!("ExeWrap-stamper error: {}: {source}", error.tag());
            }
            _ => eprintln!("ExeWrap-stamper error: {}", error.tag()),
        }
        std::process::exit(1);
    }
    std::process::exit(0)
}

fn run() -> Result<()> {
    let args = env::args_os().collect::<Vec<_>>();
    let options = parse_args(&args).inspect_err(|_| {
        write_usage();
    })?;
    stamp(&options)
}

fn stamp(options: &StampOptions) -> Result<()> {
    let base = read_file_limited(&options.launcher_path, MAX_EXE_BYTES)?;
    if pe_has_certificate_table(&base)? {
        return Err(Error::SignedLauncherNotSupported);
    }
    let config = read_file_limited(&options.config_path, MAX_CONFIG_BYTES)?;
    validate_stampable_config(&config)?;
    let existing_range = embedded_config_range_from_bytes(&base);
    let (mut staged, mut output) = StagedOutput::create(&options.output_path)?;

    write_base_before_config(&mut output, &base, existing_range)?;
    output.sync_all()?;
    drop(output);
    if let Some(icon_path) = &options.icon_path {
        stamp_icon(&staged.path, icon_path)?;
    }
    apply_subsystem_override(&staged.path, options.subsystem)?;
    {
        let mut output = OpenOptions::new().append(true).open(&staged.path)?;
        write_config_overlay(&mut output, &base, &config, existing_range)?;
        output.sync_all()?;
    }
    staged.commit(&options.output_path)?;
    Ok(())
}

struct StagedOutput {
    path: PathBuf,
    committed: bool,
}

impl StagedOutput {
    fn create(output_path: &Path) -> Result<(Self, File)> {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let parent = output_path
            .parent()
            .filter(|value| !value.as_os_str().is_empty())
            .unwrap_or_else(|| Path::new("."));
        let file_name = output_path.file_name().ok_or(Error::MissingOutputPath)?;
        for _ in 0..128 {
            let sequence = COUNTER.fetch_add(1, Ordering::Relaxed);
            let mut temporary_name = OsString::from(".");
            temporary_name.push(file_name);
            temporary_name.push(format!(".exewrap-{}-{sequence}.tmp", std::process::id()));
            let path = parent.join(temporary_name);
            match OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(file) => {
                    return Ok((
                        Self {
                            path,
                            committed: false,
                        },
                        file,
                    ));
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(error.into()),
            }
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "could not allocate a unique staging file",
        )
        .into())
    }

    fn commit(&mut self, output_path: &Path) -> Result<()> {
        replace_file(&self.path, output_path)?;
        self.committed = true;
        Ok(())
    }
}

impl Drop for StagedOutput {
    fn drop(&mut self) {
        if !self.committed {
            let _ = fs::remove_file(&self.path);
        }
    }
}

fn write_base_before_config(
    output: &mut File,
    base: &[u8],
    existing_range: Option<EmbeddedConfigRange>,
) -> Result<()> {
    if let Some(range) = existing_range {
        output.write_all(&base[..range.marker_start])?;
    } else {
        output.write_all(base)?;
    }
    Ok(())
}

fn write_config_overlay(
    output: &mut File,
    base: &[u8],
    config: &[u8],
    existing_range: Option<EmbeddedConfigRange>,
) -> Result<()> {
    output.write_all(CONFIG_START_MARKER)?;
    output.write_all(config)?;
    if let Some(range) = existing_range {
        output.write_all(&base[range.config_end..])?;
    }
    Ok(())
}

fn parse_args(args: &[OsString]) -> Result<StampOptions> {
    let mut launcher_path = None;
    let mut config_path = None;
    let mut icon_path = None;
    let mut subsystem = StampSubsystem::Inherit;
    let mut output_path = None;
    let mut index = 1;

    while index < args.len() {
        match args[index].to_str() {
            Some("--help" | "-h") => {
                write_usage();
                std::process::exit(0);
            }
            Some("--launcher") => {
                index += 1;
                launcher_path = Some(PathBuf::from(
                    args.get(index).ok_or(Error::MissingLauncherPath)?,
                ));
            }
            Some("--config") => {
                index += 1;
                config_path = Some(PathBuf::from(
                    args.get(index).ok_or(Error::MissingConfigPath)?,
                ));
            }
            Some("--icon") => {
                index += 1;
                icon_path = Some(PathBuf::from(
                    args.get(index).ok_or(Error::MissingIconPath)?,
                ));
            }
            Some("--subsystem") => {
                index += 1;
                subsystem = parse_subsystem(args.get(index).ok_or(Error::MissingSubsystem)?)?;
            }
            Some(option) if option.starts_with("--") => return Err(Error::UnknownOption),
            _ if output_path.is_none() => output_path = Some(PathBuf::from(&args[index])),
            _ => return Err(Error::TooManyOutputPaths),
        }
        index += 1;
    }

    Ok(StampOptions {
        launcher_path: launcher_path.ok_or(Error::MissingLauncherPath)?,
        config_path: config_path.ok_or(Error::MissingConfigPath)?,
        icon_path,
        subsystem,
        output_path: output_path.ok_or(Error::MissingOutputPath)?,
    })
}

fn parse_subsystem(value: &OsStr) -> Result<StampSubsystem> {
    match value.to_str() {
        Some("inherit") => Ok(StampSubsystem::Inherit),
        Some("console") => Ok(StampSubsystem::Console),
        Some("windowed") => Ok(StampSubsystem::Windowed),
        _ => Err(Error::InvalidSubsystem),
    }
}

fn write_usage() {
    eprintln!(
        "usage: ExeWrap-stamper.exe --launcher <base-launcher.exe> --config <config.json> [--icon <logo.ico>] [--subsystem inherit|console|windowed] <output.exe>"
    );
}

fn apply_subsystem_override(output_path: &Path, requested: StampSubsystem) -> Result<()> {
    let subsystem = match requested {
        StampSubsystem::Inherit => return Ok(()),
        StampSubsystem::Console => WindowsSubsystem::WindowsConsole,
        StampSubsystem::Windowed => WindowsSubsystem::WindowsGui,
    };
    set_windows_subsystem(output_path, subsystem)
}

fn stamp_icon(output_path: &Path, icon_path: &Path) -> Result<()> {
    if !cfg!(windows) {
        return Err(Error::IconStampingRequiresWindows);
    }
    let icon_bytes = read_file_limited(icon_path, MAX_ICON_BYTES)?;
    let images = parse_icon_directory(&icon_bytes)?;
    let group = build_group_icon_resource(&images)?;
    update_icon_resources(output_path, &icon_bytes, &images, &group)
}

fn parse_icon_directory(bytes: &[u8]) -> Result<Vec<IconImage>> {
    if read_u16(bytes, 0) != Some(0) || read_u16(bytes, 2) != Some(ICON_TYPE) {
        return Err(Error::InvalidIconFile);
    }
    let count = usize::from(read_u16(bytes, 4).ok_or(Error::InvalidIconFile)?);
    if count == 0 {
        return Err(Error::InvalidIconFile);
    }
    let directory_end = 6usize
        .checked_add(count.checked_mul(16).ok_or(Error::InvalidIconFile)?)
        .ok_or(Error::InvalidIconFile)?;
    if bytes.len() < directory_end {
        return Err(Error::InvalidIconFile);
    }
    let mut images = Vec::with_capacity(count);
    for index in 0..count {
        let offset = 6 + index * 16;
        let bytes_in_res = read_u32(bytes, offset + 8).ok_or(Error::InvalidIconFile)?;
        let image_offset = read_u32(bytes, offset + 12).ok_or(Error::InvalidIconFile)?;
        let start = usize::try_from(image_offset).map_err(|_| Error::InvalidIconFile)?;
        let length = usize::try_from(bytes_in_res).map_err(|_| Error::InvalidIconFile)?;
        bytes
            .get(start..start.checked_add(length).ok_or(Error::InvalidIconFile)?)
            .ok_or(Error::InvalidIconFile)?;
        images.push(IconImage {
            width: bytes[offset],
            height: bytes[offset + 1],
            color_count: bytes[offset + 2],
            reserved: bytes[offset + 3],
            planes: read_u16(bytes, offset + 4).ok_or(Error::InvalidIconFile)?,
            bit_count: read_u16(bytes, offset + 6).ok_or(Error::InvalidIconFile)?,
            bytes_in_res,
            image_offset,
            id: u16::try_from(index + 1).map_err(|_| Error::InvalidIconFile)?,
        });
    }
    Ok(images)
}

fn build_group_icon_resource(images: &[IconImage]) -> Result<Vec<u8>> {
    let length = 6usize
        .checked_add(images.len().checked_mul(14).ok_or(Error::InvalidIconFile)?)
        .ok_or(Error::InvalidIconFile)?;
    let mut group = vec![0u8; length];
    write_u16(&mut group, 0, 0)?;
    write_u16(&mut group, 2, ICON_TYPE)?;
    write_u16(
        &mut group,
        4,
        u16::try_from(images.len()).map_err(|_| Error::InvalidIconFile)?,
    )?;
    for (index, image) in images.iter().enumerate() {
        let offset = 6 + index * 14;
        group[offset] = image.width;
        group[offset + 1] = image.height;
        group[offset + 2] = image.color_count;
        group[offset + 3] = image.reserved;
        write_u16(&mut group, offset + 4, image.planes)?;
        write_u16(&mut group, offset + 6, image.bit_count)?;
        write_u32(&mut group, offset + 8, image.bytes_in_res)?;
        write_u16(&mut group, offset + 12, image.id)?;
    }
    Ok(group)
}

#[cfg(windows)]
fn update_icon_resources(
    output_path: &Path,
    icon_bytes: &[u8],
    images: &[IconImage],
    group_resource: &[u8],
) -> Result<()> {
    let path = output_path
        .as_os_str()
        .encode_wide()
        .chain(Some(0))
        .collect::<Vec<_>>();
    // SAFETY: `path` is NUL-terminated and remains alive for this call.
    let handle = unsafe { BeginUpdateResourceW(path.as_ptr(), 0) };
    if handle.is_null() {
        return Err(Error::BeginUpdateResourceFailed);
    }
    let update = ResourceUpdate { handle };
    for image in images {
        let offset = image.image_offset as usize;
        let length = image.bytes_in_res as usize;
        let data = &icon_bytes[offset..offset + length];
        // SAFETY: the update handle is live and data points to `length` bytes.
        if unsafe {
            UpdateResourceW(
                update.handle,
                resource_id(RT_ICON),
                resource_id(image.id),
                NEUTRAL_LANGUAGE,
                data.as_ptr().cast(),
                data.len() as u32,
            )
        } == 0
        {
            return Err(Error::UpdateIconResourceFailed);
        }
    }
    // SAFETY: the update handle is live and group_resource points to its reported length.
    if unsafe {
        UpdateResourceW(
            update.handle,
            resource_id(RT_GROUP_ICON),
            resource_id(DEFAULT_GROUP_ICON_ID),
            NEUTRAL_LANGUAGE,
            group_resource.as_ptr().cast(),
            group_resource.len() as u32,
        )
    } == 0
    {
        return Err(Error::UpdateIconResourceFailed);
    }
    update.commit()
}

#[cfg(not(windows))]
fn update_icon_resources(_: &Path, _: &[u8], _: &[IconImage], _: &[u8]) -> Result<()> {
    Err(Error::IconStampingRequiresWindows)
}

#[cfg(windows)]
struct ResourceUpdate {
    handle: *mut c_void,
}

#[cfg(windows)]
impl ResourceUpdate {
    fn commit(mut self) -> Result<()> {
        // EndUpdateResourceW invalidates the handle even when the commit fails.
        let handle = std::mem::replace(&mut self.handle, std::ptr::null_mut());
        // SAFETY: the handle is live and this is its single commit call.
        if unsafe { EndUpdateResourceW(handle, 0) } == 0 {
            return Err(Error::EndUpdateResourceFailed);
        }
        Ok(())
    }
}

#[cfg(windows)]
impl Drop for ResourceUpdate {
    fn drop(&mut self) {
        if !self.handle.is_null() {
            // SAFETY: an uncommitted handle must be discarded before leaving scope.
            unsafe { EndUpdateResourceW(self.handle, 1) };
        }
    }
}

#[cfg(windows)]
fn resource_id(id: u16) -> *const u16 {
    usize::from(id) as *const u16
}

#[cfg(windows)]
fn replace_file(source: &Path, destination: &Path) -> Result<()> {
    let source = nul_terminated_path(source)?;
    let destination = nul_terminated_path(destination)?;
    let replaced = if destination_path_exists(destination.as_slice()) {
        // SAFETY: both paths are live NUL-terminated buffers and no backup is requested.
        unsafe {
            ReplaceFileW(
                destination.as_ptr(),
                source.as_ptr(),
                std::ptr::null(),
                0,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        }
    } else {
        // SAFETY: both paths are live NUL-terminated buffers for this call.
        unsafe {
            MoveFileExW(
                source.as_ptr(),
                destination.as_ptr(),
                MOVE_FILE_REPLACE_EXISTING | MOVE_FILE_WRITE_THROUGH,
            )
        }
    };
    if replaced == 0 {
        Err(io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}

#[cfg(windows)]
fn destination_path_exists(path: &[u16]) -> bool {
    // SAFETY: path is a live NUL-terminated buffer.
    unsafe { GetFileAttributesW(path.as_ptr()) != INVALID_FILE_ATTRIBUTES }
}

#[cfg(windows)]
fn nul_terminated_path(path: &Path) -> Result<Vec<u16>> {
    let mut value = path.as_os_str().encode_wide().collect::<Vec<_>>();
    if value.contains(&0) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "path contains NUL").into());
    }
    value.push(0);
    Ok(value)
}

#[cfg(not(windows))]
fn replace_file(source: &Path, destination: &Path) -> Result<()> {
    fs::rename(source, destination)?;
    Ok(())
}

fn read_u16(bytes: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_le_bytes(
        bytes.get(offset..offset.checked_add(2)?)?.try_into().ok()?,
    ))
}

fn read_u32(bytes: &[u8], offset: usize) -> Option<u32> {
    Some(u32::from_le_bytes(
        bytes.get(offset..offset.checked_add(4)?)?.try_into().ok()?,
    ))
}

fn write_u16(bytes: &mut [u8], offset: usize, value: u16) -> Result<()> {
    bytes
        .get_mut(offset..offset.checked_add(2).ok_or(Error::InvalidIconFile)?)
        .ok_or(Error::InvalidIconFile)?
        .copy_from_slice(&value.to_le_bytes());
    Ok(())
}

fn write_u32(bytes: &mut [u8], offset: usize, value: u32) -> Result<()> {
    bytes
        .get_mut(offset..offset.checked_add(4).ok_or(Error::InvalidIconFile)?)
        .ok_or(Error::InvalidIconFile)?
        .copy_from_slice(&value.to_le_bytes());
    Ok(())
}

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn BeginUpdateResourceW(file_name: *const u16, delete_existing: i32) -> *mut c_void;
    fn UpdateResourceW(
        update: *mut c_void,
        resource_type: *const u16,
        name: *const u16,
        language: u16,
        data: *const c_void,
        data_length: u32,
    ) -> i32;
    fn EndUpdateResourceW(update: *mut c_void, discard: i32) -> i32;
    fn ReplaceFileW(
        replaced_file_name: *const u16,
        replacement_file_name: *const u16,
        backup_file_name: *const u16,
        replace_flags: u32,
        exclude: *mut c_void,
        reserved: *mut c_void,
    ) -> i32;
    fn MoveFileExW(existing_file_name: *const u16, new_file_name: *const u16, flags: u32) -> i32;
    fn GetFileAttributesW(file_name: *const u16) -> u32;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stamper_arg_parsing_accepts_subsystem_values() {
        let args = [
            "ExeWrap-stamper.exe",
            "--launcher",
            "ExeWrap-console.exe",
            "--config",
            "config.json",
            "--subsystem",
            "windowed",
            "out.exe",
        ]
        .map(OsString::from);
        let options = parse_args(&args).unwrap();
        assert_eq!(options.launcher_path, Path::new("ExeWrap-console.exe"));
        assert_eq!(options.config_path, Path::new("config.json"));
        assert!(options.icon_path.is_none());
        assert_eq!(options.subsystem, StampSubsystem::Windowed);
        assert_eq!(options.output_path, Path::new("out.exe"));
        assert_eq!(
            parse_subsystem(OsStr::new("inherit")).unwrap(),
            StampSubsystem::Inherit
        );
        assert_eq!(
            parse_subsystem(OsStr::new("console")).unwrap(),
            StampSubsystem::Console
        );
        assert_eq!(
            parse_subsystem(OsStr::new("windowed")).unwrap(),
            StampSubsystem::Windowed
        );
        assert!(matches!(
            parse_subsystem(OsStr::new("gui")),
            Err(Error::InvalidSubsystem)
        ));
    }

    #[test]
    fn stamper_subsystem_defaults_to_inherit() {
        let args = [
            "ExeWrap-stamper.exe",
            "--launcher",
            "ExeWrap-windowed.exe",
            "--config",
            "config.json",
            "out.exe",
        ]
        .map(OsString::from);
        assert_eq!(
            parse_args(&args).unwrap().subsystem,
            StampSubsystem::Inherit
        );
    }

    #[test]
    fn icon_directory_parser_validates_ranges_and_builds_group() {
        let mut icon = vec![0u8; 22 + 4];
        icon[2..4].copy_from_slice(&ICON_TYPE.to_le_bytes());
        icon[4..6].copy_from_slice(&1u16.to_le_bytes());
        icon[6] = 16;
        icon[7] = 16;
        icon[10..12].copy_from_slice(&1u16.to_le_bytes());
        icon[12..14].copy_from_slice(&32u16.to_le_bytes());
        icon[14..18].copy_from_slice(&4u32.to_le_bytes());
        icon[18..22].copy_from_slice(&22u32.to_le_bytes());
        let images = parse_icon_directory(&icon).unwrap();
        let group = build_group_icon_resource(&images).unwrap();
        assert_eq!(images[0].id, 1);
        assert_eq!(group.len(), 20);
        assert_eq!(&group[4..6], &1u16.to_le_bytes());
    }

    #[test]
    fn failed_stamp_preserves_existing_output() {
        let root = env::temp_dir().join(format!(
            "exewrap-atomic-stamp-test-{}-{}",
            std::process::id(),
            COUNTER_FOR_TESTS.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        let config_path = root.join("config.json");
        let icon_path = root.join("invalid.ico");
        let output_path = root.join("existing.exe");
        fs::write(&config_path, br#"{"command":["cmd.exe"]}"#).unwrap();
        fs::write(&icon_path, b"not an icon").unwrap();
        fs::write(&output_path, b"keep me").unwrap();
        let options = StampOptions {
            launcher_path: env::current_exe().unwrap(),
            config_path,
            icon_path: Some(icon_path),
            subsystem: StampSubsystem::Inherit,
            output_path: output_path.clone(),
        };
        assert!(matches!(stamp(&options), Err(Error::InvalidIconFile)));
        assert_eq!(fs::read(&output_path).unwrap(), b"keep me");
        assert!(fs::read_dir(&root).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .contains("exewrap-")
        }));
        fs::remove_dir_all(root).unwrap();
    }

    static COUNTER_FOR_TESTS: AtomicU64 = AtomicU64::new(0);
}
