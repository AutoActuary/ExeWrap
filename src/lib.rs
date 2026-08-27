#![cfg_attr(not(windows), allow(dead_code))]

use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{OsStr, OsString, c_void};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;
use std::{env, io, ptr, slice};

#[cfg(windows)]
use std::os::windows::ffi::OsStrExt;

#[cfg(test)]
use std::fs;

pub mod launcher;
pub mod stamp;
pub mod template_expr;
pub mod template_scan;

pub const MARKER_UUID: &str = "8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a";
pub const END_MARKER_UUID: &str = "ce3beca3-7ed2-40a4-9133-f82198be1d7b";
pub const CONFIG_START_MARKER: &[u8] = MARKER_UUID.as_bytes();
pub const CONFIG_END_MARKER: &[u8] = END_MARKER_UUID.as_bytes();
pub const MAX_EXE_BYTES: u64 = 512 * 1024 * 1024;
const MAX_JSON_DEPTH: usize = 128;
pub const PE_SUBSYSTEM_CONSOLE: u16 = 3;
pub const PE_SUBSYSTEM_WINDOWED: u16 = 2;

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug)]
pub enum Error {
    Io(io::Error),
    FileTooBig,
    SyntaxError,
    NoEmbeddedConfig,
    EmptyEmbeddedConfig,
    ConfigMustBeUtf8,
    ReservedOverlayMarkerInConfig,
    SignedLauncherNotSupported,
    WindowsTextMustBeUnicode,
    ArgumentMustBeUnicode,
    EnvironmentValueMustBeUnicode,
    InvalidPeFile,
    UnsupportedWindowsSubsystem,
    ConfigMustBeObject,
    InvalidJson,
    DuplicateJsonKey,
    TemplateInObjectKey,
    TerminalConfigRemoved,
    UnknownTopLevelKey,
    CommandMustBeLast,
    MissingCommand,
    KillChildrenOnExitMustBeBoolean,
    ErrorOnMissingEnvMustBeBoolean,
    ErrorOnArgOutOfBoundsMustBeBoolean,
    EnvMustBeObject,
    EnvValuesMustBeStrings,
    CwdMustBeString,
    CommandMustBeArray,
    CommandMustNotBeEmpty,
    CommandEntriesMustBeStrings,
    TemplateMustEvaluateToList,
    ListTemplateNotAllowedInString,
    TemplateMustEvaluateToString,
    EmptyTemplateExpression,
    UnclosedTemplateString,
    UnclosedTemplateParenthesis,
    UnclosedTemplateExpression,
    InvalidTemplateStringEscape,
    InvalidSentinelKey,
    TestSentinelExhausted,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidString,
    IntegerOutOfRange,
    Overflow,
    ExpectedIdentifier,
    ExpectedInteger,
    ExpectedString,
    ExpectedColon,
    ExpectedOpenParen,
    ExpectedCloseParen,
    ExpectedOpenBracket,
    ExpectedCloseBracket,
    ExpectedPlus,
    ExpectedMinus,
    ExpectedEndOfExpression,
    ExpectedColonOrCloseBracket,
    ExpectedIndexExpression,
    ExpectedArgument,
    IndexExpressionOverflow,
    UnknownBase,
    MissingEnvironmentVariable,
    IndexOutOfBounds,
    ArgumentOutOfBounds,
    ZeroSliceStep,
    WrongTransformType,
    MissingTransformArgument,
    UnexpectedTransformArgument,
    UnknownTransform,
    MissingLauncherPath,
    MissingConfigPath,
    MissingIconPath,
    MissingSubsystem,
    MissingOutputPath,
    UnknownOption,
    TooManyOutputPaths,
    InvalidSubsystem,
    InvalidIconFile,
    IconStampingRequiresWindows,
    BeginUpdateResourceFailed,
    UpdateIconResourceFailed,
    EndUpdateResourceFailed,
    CreateJobObjectFailed,
    SetInformationJobObjectFailed,
    AssignProcessToJobObjectFailed,
    ResumeThreadFailed,
    InvalidBatchScriptArg,
    RandomGenerationFailed,
}

impl Error {
    pub fn tag(&self) -> &'static str {
        match self {
            Self::Io(error) => {
                if matches!(error.raw_os_error(), Some(191 | 193 | 216)) {
                    "InvalidExe"
                } else {
                    match error.kind() {
                        io::ErrorKind::NotFound => "FileNotFound",
                        io::ErrorKind::PermissionDenied => "AccessDenied",
                        io::ErrorKind::AlreadyExists => "PathAlreadyExists",
                        io::ErrorKind::InvalidData => "InvalidData",
                        _ => "IoError",
                    }
                }
            }
            Self::FileTooBig => "FileTooBig",
            Self::SyntaxError => "SyntaxError",
            Self::NoEmbeddedConfig => "NoEmbeddedConfig",
            Self::EmptyEmbeddedConfig => "EmptyEmbeddedConfig",
            Self::ConfigMustBeUtf8 => "ConfigMustBeUtf8",
            Self::ReservedOverlayMarkerInConfig => "ReservedOverlayMarkerInConfig",
            Self::SignedLauncherNotSupported => "SignedLauncherNotSupported",
            Self::WindowsTextMustBeUnicode => "WindowsTextMustBeUnicode",
            Self::ArgumentMustBeUnicode => "ArgumentMustBeUnicode",
            Self::EnvironmentValueMustBeUnicode => "EnvironmentValueMustBeUnicode",
            Self::InvalidPeFile => "InvalidPeFile",
            Self::UnsupportedWindowsSubsystem => "UnsupportedWindowsSubsystem",
            Self::ConfigMustBeObject => "ConfigMustBeObject",
            Self::InvalidJson => "InvalidJson",
            Self::DuplicateJsonKey => "DuplicateJsonKey",
            Self::TemplateInObjectKey => "TemplateInObjectKey",
            Self::TerminalConfigRemoved => "TerminalConfigRemoved",
            Self::UnknownTopLevelKey => "UnknownTopLevelKey",
            Self::CommandMustBeLast => "CommandMustBeLast",
            Self::MissingCommand => "MissingCommand",
            Self::KillChildrenOnExitMustBeBoolean => "KillChildrenOnExitMustBeBoolean",
            Self::ErrorOnMissingEnvMustBeBoolean => "ErrorOnMissingEnvMustBeBoolean",
            Self::ErrorOnArgOutOfBoundsMustBeBoolean => "ErrorOnArgOutOfBoundsMustBeBoolean",
            Self::EnvMustBeObject => "EnvMustBeObject",
            Self::EnvValuesMustBeStrings => "EnvValuesMustBeStrings",
            Self::CwdMustBeString => "CwdMustBeString",
            Self::CommandMustBeArray => "CommandMustBeArray",
            Self::CommandMustNotBeEmpty => "CommandMustNotBeEmpty",
            Self::CommandEntriesMustBeStrings => "CommandEntriesMustBeStrings",
            Self::TemplateMustEvaluateToList => "TemplateMustEvaluateToList",
            Self::ListTemplateNotAllowedInString => "ListTemplateNotAllowedInString",
            Self::TemplateMustEvaluateToString => "TemplateMustEvaluateToString",
            Self::EmptyTemplateExpression => "EmptyTemplateExpression",
            Self::UnclosedTemplateString => "UnclosedTemplateString",
            Self::UnclosedTemplateParenthesis => "UnclosedTemplateParenthesis",
            Self::UnclosedTemplateExpression => "UnclosedTemplateExpression",
            Self::InvalidTemplateStringEscape => "InvalidTemplateStringEscape",
            Self::InvalidSentinelKey => "InvalidSentinelKey",
            Self::TestSentinelExhausted => "TestSentinelExhausted",
            Self::UnexpectedCharacter => "UnexpectedCharacter",
            Self::UnterminatedString => "UnterminatedString",
            Self::InvalidString => "InvalidString",
            Self::IntegerOutOfRange => "IntegerOutOfRange",
            Self::Overflow => "Overflow",
            Self::ExpectedIdentifier => "ExpectedIdentifier",
            Self::ExpectedInteger => "ExpectedInteger",
            Self::ExpectedString => "ExpectedString",
            Self::ExpectedColon => "ExpectedColon",
            Self::ExpectedOpenParen => "ExpectedOpenParen",
            Self::ExpectedCloseParen => "ExpectedCloseParen",
            Self::ExpectedOpenBracket => "ExpectedOpenBracket",
            Self::ExpectedCloseBracket => "ExpectedCloseBracket",
            Self::ExpectedPlus => "ExpectedPlus",
            Self::ExpectedMinus => "ExpectedMinus",
            Self::ExpectedEndOfExpression => "ExpectedEndOfExpression",
            Self::ExpectedColonOrCloseBracket => "ExpectedColonOrCloseBracket",
            Self::ExpectedIndexExpression => "ExpectedIndexExpression",
            Self::ExpectedArgument => "ExpectedArgument",
            Self::IndexExpressionOverflow => "IndexExpressionOverflow",
            Self::UnknownBase => "UnknownBase",
            Self::MissingEnvironmentVariable => "MissingEnvironmentVariable",
            Self::IndexOutOfBounds => "IndexOutOfBounds",
            Self::ArgumentOutOfBounds => "ArgumentOutOfBounds",
            Self::ZeroSliceStep => "ZeroSliceStep",
            Self::WrongTransformType => "WrongTransformType",
            Self::MissingTransformArgument => "MissingTransformArgument",
            Self::UnexpectedTransformArgument => "UnexpectedTransformArgument",
            Self::UnknownTransform => "UnknownTransform",
            Self::MissingLauncherPath => "MissingLauncherPath",
            Self::MissingConfigPath => "MissingConfigPath",
            Self::MissingIconPath => "MissingIconPath",
            Self::MissingSubsystem => "MissingSubsystem",
            Self::MissingOutputPath => "MissingOutputPath",
            Self::UnknownOption => "UnknownOption",
            Self::TooManyOutputPaths => "TooManyOutputPaths",
            Self::InvalidSubsystem => "InvalidSubsystem",
            Self::InvalidIconFile => "InvalidIconFile",
            Self::IconStampingRequiresWindows => "IconStampingRequiresWindows",
            Self::BeginUpdateResourceFailed => "BeginUpdateResourceFailed",
            Self::UpdateIconResourceFailed => "UpdateIconResourceFailed",
            Self::EndUpdateResourceFailed => "EndUpdateResourceFailed",
            Self::CreateJobObjectFailed => "CreateJobObjectFailed",
            Self::SetInformationJobObjectFailed => "SetInformationJobObjectFailed",
            Self::AssignProcessToJobObjectFailed => "AssignProcessToJobObjectFailed",
            Self::ResumeThreadFailed => "ResumeThreadFailed",
            Self::InvalidBatchScriptArg => "InvalidBatchScriptArg",
            Self::RandomGenerationFailed => "RandomGenerationFailed",
        }
    }
}

impl From<io::Error> for Error {
    fn from(value: io::Error) -> Self {
        Self::Io(value)
    }
}

#[derive(Clone, Debug)]
struct EnvKey {
    raw: OsString,
    #[cfg(windows)]
    wide: Vec<u16>,
}

impl EnvKey {
    fn new(raw: OsString) -> Self {
        #[cfg(windows)]
        let wide = raw.encode_wide().collect();
        Self {
            raw,
            #[cfg(windows)]
            wide,
        }
    }
}

impl PartialEq for EnvKey {
    fn eq(&self, other: &Self) -> bool {
        self.cmp(other) == Ordering::Equal
    }
}

impl Eq for EnvKey {}

impl PartialOrd for EnvKey {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl Ord for EnvKey {
    fn cmp(&self, other: &Self) -> Ordering {
        #[cfg(windows)]
        {
            let (Ok(left_len), Ok(right_len)) = (
                i32::try_from(self.wide.len()),
                i32::try_from(other.wide.len()),
            ) else {
                return self.wide.cmp(&other.wide);
            };
            // SAFETY: both stored UTF-16 buffers are live for their supplied lengths.
            match unsafe {
                CompareStringOrdinal(
                    self.wide.as_ptr(),
                    left_len,
                    other.wide.as_ptr(),
                    right_len,
                    1,
                )
            } {
                1 => Ordering::Less,
                2 => Ordering::Equal,
                3 => Ordering::Greater,
                _ => self.wide.cmp(&other.wide),
            }
        }
        #[cfg(not(windows))]
        {
            self.raw.cmp(&other.raw)
        }
    }
}

#[derive(Clone, Debug, Default)]
pub struct EnvMap {
    entries: BTreeMap<EnvKey, OsString>,
}

impl EnvMap {
    pub fn from_current() -> Self {
        Self {
            entries: env::vars_os()
                .map(|(name, value)| (EnvKey::new(name), value))
                .collect(),
        }
    }

    pub fn get(&self, name: &str) -> Option<&str> {
        self.entries
            .get(&EnvKey::new(name.into()))
            .and_then(|value| value.to_str())
    }

    pub fn get_os(&self, name: &str) -> Option<&OsStr> {
        self.entries
            .get(&EnvKey::new(name.into()))
            .map(OsString::as_os_str)
    }

    pub fn put(&mut self, name: String, value: String) {
        let key = EnvKey::new(name.into());
        self.entries.remove(&key);
        self.entries.insert(key, value.into());
    }

    pub fn iter(&self) -> impl Iterator<Item = (&OsStr, &OsStr)> {
        self.entries
            .iter()
            .map(|(name, value)| (name.raw.as_os_str(), value.as_os_str()))
    }
}

#[cfg(windows)]
#[link(name = "kernel32")]
unsafe extern "system" {
    fn CompareStringOrdinal(
        left: *const u16,
        left_len: i32,
        right: *const u16,
        right_len: i32,
        ignore_case: i32,
    ) -> i32;
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum JsonValue {
    Null,
    Bool(bool),
    Number(String),
    String(String),
    Array(Vec<JsonValue>),
    Object(Vec<(String, JsonValue)>),
}

impl JsonValue {
    fn as_object(&self) -> Option<&[(String, JsonValue)]> {
        match self {
            Self::Object(value) => Some(value),
            _ => None,
        }
    }

    fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            Self::Array(value) => Some(value),
            _ => None,
        }
    }

    fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(value) => Some(value),
            _ => None,
        }
    }
}

struct JsonParser<'a> {
    input: &'a str,
    index: usize,
}

impl JsonParser<'_> {
    fn parse(input: &str) -> Result<JsonValue> {
        let mut parser = JsonParser { input, index: 0 };
        let value = parser.parse_value(0)?;
        parser.skip_whitespace();
        if parser.index == input.len() {
            Ok(value)
        } else {
            Err(Error::SyntaxError)
        }
    }

    fn parse_value(&mut self, depth: usize) -> Result<JsonValue> {
        if depth > MAX_JSON_DEPTH {
            return Err(Error::SyntaxError);
        }
        self.skip_whitespace();
        match self.input.as_bytes().get(self.index).copied() {
            Some(b'{') => self.parse_object(depth),
            Some(b'[') => self.parse_array(depth),
            Some(b'"') => self.parse_string().map(JsonValue::String),
            Some(b't') => {
                self.parse_literal("true")?;
                Ok(JsonValue::Bool(true))
            }
            Some(b'f') => {
                self.parse_literal("false")?;
                Ok(JsonValue::Bool(false))
            }
            Some(b'n') => {
                self.parse_literal("null")?;
                Ok(JsonValue::Null)
            }
            Some(b'-' | b'0'..=b'9') => self.parse_number().map(JsonValue::Number),
            _ => Err(Error::SyntaxError),
        }
    }

    fn parse_object(&mut self, depth: usize) -> Result<JsonValue> {
        self.index += 1;
        self.skip_whitespace();
        let mut object = Vec::new();
        let mut keys = BTreeSet::new();
        if self.consume(b'}') {
            return Ok(JsonValue::Object(object));
        }
        loop {
            self.skip_whitespace();
            if self.input.as_bytes().get(self.index) != Some(&b'"') {
                return Err(Error::SyntaxError);
            }
            let key = self.parse_string()?;
            if !keys.insert(key.clone()) {
                return Err(Error::DuplicateJsonKey);
            }
            self.skip_whitespace();
            if !self.consume(b':') {
                return Err(Error::SyntaxError);
            }
            let value = self.parse_value(depth + 1)?;
            object.push((key, value));
            self.skip_whitespace();
            if self.consume(b'}') {
                return Ok(JsonValue::Object(object));
            }
            if !self.consume(b',') {
                return Err(Error::SyntaxError);
            }
        }
    }

    fn parse_array(&mut self, depth: usize) -> Result<JsonValue> {
        self.index += 1;
        self.skip_whitespace();
        let mut array = Vec::new();
        if self.consume(b']') {
            return Ok(JsonValue::Array(array));
        }
        loop {
            array.push(self.parse_value(depth + 1)?);
            self.skip_whitespace();
            if self.consume(b']') {
                return Ok(JsonValue::Array(array));
            }
            if !self.consume(b',') {
                return Err(Error::SyntaxError);
            }
        }
    }

    fn parse_string(&mut self) -> Result<String> {
        if !self.consume(b'"') {
            return Err(Error::SyntaxError);
        }
        let bytes = self.input.as_bytes();
        let mut output = Vec::new();
        while self.index < bytes.len() {
            match bytes[self.index] {
                b'"' => {
                    self.index += 1;
                    return String::from_utf8(output).map_err(|_| Error::SyntaxError);
                }
                b'\\' => {
                    self.index += 1;
                    let escaped = bytes.get(self.index).copied().ok_or(Error::SyntaxError)?;
                    match escaped {
                        b'"' | b'\\' | b'/' => output.push(escaped),
                        b'b' => output.push(0x08),
                        b'f' => output.push(0x0c),
                        b'n' => output.push(b'\n'),
                        b'r' => output.push(b'\r'),
                        b't' => output.push(b'\t'),
                        b'u' => {
                            let first = self.parse_hex_escape()?;
                            let codepoint = if (0xd800..=0xdbff).contains(&first) {
                                if bytes.get(self.index + 1..self.index + 3) != Some(b"\\u") {
                                    return Err(Error::SyntaxError);
                                }
                                self.index += 2;
                                let second = self.parse_hex_escape()?;
                                if !(0xdc00..=0xdfff).contains(&second) {
                                    return Err(Error::SyntaxError);
                                }
                                0x1_0000
                                    + ((u32::from(first) - 0xd800) << 10)
                                    + (u32::from(second) - 0xdc00)
                            } else if (0xdc00..=0xdfff).contains(&first) {
                                return Err(Error::SyntaxError);
                            } else {
                                u32::from(first)
                            };
                            let character = char::from_u32(codepoint).ok_or(Error::SyntaxError)?;
                            let mut encoded = [0u8; 4];
                            output
                                .extend_from_slice(character.encode_utf8(&mut encoded).as_bytes());
                        }
                        _ => return Err(Error::SyntaxError),
                    }
                    self.index += 1;
                }
                0x00..=0x1f => return Err(Error::SyntaxError),
                byte => {
                    output.push(byte);
                    self.index += 1;
                }
            }
        }
        Err(Error::SyntaxError)
    }

    fn parse_hex_escape(&mut self) -> Result<u16> {
        let start = self.index.checked_add(1).ok_or(Error::SyntaxError)?;
        let end = start.checked_add(4).ok_or(Error::SyntaxError)?;
        let digits = self.input.get(start..end).ok_or(Error::SyntaxError)?;
        self.index = end - 1;
        u16::from_str_radix(digits, 16).map_err(|_| Error::SyntaxError)
    }

    fn parse_number(&mut self) -> Result<String> {
        let start = self.index;
        self.consume(b'-');
        match self.input.as_bytes().get(self.index).copied() {
            Some(b'0') => {
                self.index += 1;
                if self
                    .input
                    .as_bytes()
                    .get(self.index)
                    .is_some_and(u8::is_ascii_digit)
                {
                    return Err(Error::SyntaxError);
                }
            }
            Some(b'1'..=b'9') => self.consume_digits(),
            _ => return Err(Error::SyntaxError),
        }
        if self.consume(b'.') {
            let digits = self.index;
            self.consume_digits();
            if self.index == digits {
                return Err(Error::SyntaxError);
            }
        }
        if self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(|byte| matches!(byte, b'e' | b'E'))
        {
            self.index += 1;
            if !self.consume(b'+') {
                self.consume(b'-');
            }
            let digits = self.index;
            self.consume_digits();
            if self.index == digits {
                return Err(Error::SyntaxError);
            }
        }
        Ok(self.input[start..self.index].to_owned())
    }

    fn consume_digits(&mut self) {
        while self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(u8::is_ascii_digit)
        {
            self.index += 1;
        }
    }

    fn parse_literal(&mut self, literal: &str) -> Result<()> {
        if self.input[self.index..].starts_with(literal) {
            self.index += literal.len();
            Ok(())
        } else {
            Err(Error::SyntaxError)
        }
    }

    fn skip_whitespace(&mut self) {
        while self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(|byte| matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
        {
            self.index += 1;
        }
    }

    fn consume(&mut self, byte: u8) -> bool {
        if self.input.as_bytes().get(self.index) == Some(&byte) {
            self.index += 1;
            true
        } else {
            false
        }
    }
}

fn object_get<'a>(object: &'a [(String, JsonValue)], key: &str) -> Option<&'a JsonValue> {
    object
        .iter()
        .find(|(candidate, _)| candidate == key)
        .map(|(_, value)| value)
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct RuntimePaths {
    pub exe_path: String,
    pub exe_dir: String,
    pub exe_filename: String,
    pub exe_filename_noext: String,
    pub exe_name: String,
    pub exe_stem: String,
    pub exe_ext: String,
    pub exe_ext_dot: String,
    pub exe_drive: String,
    pub exe_root: String,
    pub launch_cwd: String,
    pub temp_dir: String,
    pub home_dir: String,
    pub appdata_dir: String,
    pub localappdata_dir: String,
    pub programdata_dir: String,
    pub program_files_dir: String,
    pub program_files_x86_dir: String,
    pub documents_dir: String,
    pub downloads_dir: String,
    pub desktop_dir: String,
}

impl RuntimePaths {
    pub fn init(exe_path: String) -> Result<Self> {
        let user_dirs = KnownUserDirs::init()?;
        Self::init_with_known_user_dirs(exe_path, user_dirs)
    }

    fn init_with_known_user_dirs(exe_path: String, user_dirs: KnownUserDirs) -> Result<Self> {
        let path = Path::new(&exe_path);
        let exe_dir = path
            .parent()
            .map(path_to_string)
            .transpose()?
            .unwrap_or_else(|| ".".into());
        let exe_filename = path
            .file_name()
            .map(os_to_string)
            .transpose()?
            .unwrap_or_default();
        let exe_filename_noext = path
            .file_stem()
            .map(os_to_string)
            .transpose()?
            .unwrap_or_default();
        let exe_ext = path
            .extension()
            .map(os_to_string)
            .transpose()?
            .unwrap_or_default();
        let exe_ext_dot = if exe_ext.is_empty() {
            String::new()
        } else {
            format!(".{exe_ext}")
        };
        Ok(Self {
            exe_drive: path_drive(&exe_path).to_owned(),
            exe_root: path_root(&exe_path).to_owned(),
            launch_cwd: path_to_string(&env::current_dir()?)?,
            temp_dir: path_to_string(&env::temp_dir())?,
            home_dir: env_var_or_empty("USERPROFILE")?,
            appdata_dir: env_var_or_empty("APPDATA")?,
            localappdata_dir: env_var_or_empty("LOCALAPPDATA")?,
            programdata_dir: env_var_or_empty("ProgramData")?,
            program_files_dir: env_var_or_empty("ProgramFiles")?,
            program_files_x86_dir: env_var_or_empty("ProgramFiles(x86)")?,
            documents_dir: user_dirs.documents,
            downloads_dir: user_dirs.downloads,
            desktop_dir: user_dirs.desktop,
            exe_name: exe_filename.clone(),
            exe_stem: exe_filename_noext.clone(),
            exe_path,
            exe_dir,
            exe_filename,
            exe_filename_noext,
            exe_ext,
            exe_ext_dot,
        })
    }
}

fn os_to_string(value: &OsStr) -> Result<String> {
    value
        .to_str()
        .map(str::to_owned)
        .ok_or(Error::WindowsTextMustBeUnicode)
}

fn path_to_string(value: &Path) -> Result<String> {
    os_to_string(value.as_os_str())
}

fn env_var_or_empty(name: &str) -> Result<String> {
    env::var_os(name).map_or_else(|| Ok(String::new()), |value| os_to_string(&value))
}

#[derive(Default)]
struct KnownUserDirs {
    documents: String,
    downloads: String,
    desktop: String,
}

impl KnownUserDirs {
    fn init() -> Result<Self> {
        Ok(Self {
            documents: known_user_folder_or_empty(&FOLDER_ID_DOCUMENTS)?,
            downloads: known_user_folder_or_empty(&FOLDER_ID_DOWNLOADS)?,
            desktop: known_user_folder_or_empty(&FOLDER_ID_DESKTOP)?,
        })
    }
}

#[repr(C)]
struct Guid {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [u8; 8],
}

const FOLDER_ID_DOCUMENTS: Guid = Guid {
    data1: 0xFDD39AD0,
    data2: 0x238F,
    data3: 0x46AF,
    data4: [0xAD, 0xB4, 0x6C, 0x85, 0x48, 0x03, 0x69, 0xC7],
};
const FOLDER_ID_DOWNLOADS: Guid = Guid {
    data1: 0x374DE290,
    data2: 0x123F,
    data3: 0x4565,
    data4: [0x91, 0x64, 0x39, 0xC4, 0x92, 0x5E, 0x46, 0x7B],
};
const FOLDER_ID_DESKTOP: Guid = Guid {
    data1: 0xB4BFCC3A,
    data2: 0xDB2C,
    data3: 0x424C,
    data4: [0xB0, 0x29, 0x7F, 0xE9, 0x9A, 0x87, 0xC6, 0x41],
};

#[cfg(windows)]
#[link(name = "shell32")]
unsafe extern "system" {
    fn SHGetKnownFolderPath(
        rfid: *const Guid,
        flags: u32,
        token: *mut c_void,
        path: *mut *mut u16,
    ) -> i32;
}

#[cfg(windows)]
#[link(name = "ole32")]
unsafe extern "system" {
    fn CoTaskMemFree(memory: *mut c_void);
}

fn known_user_folder_or_empty(folder: &Guid) -> Result<String> {
    #[cfg(windows)]
    {
        let mut raw_path = ptr::null_mut();
        // SAFETY: `folder` is a valid GUID and `raw_path` is a writable out-pointer.
        let result = unsafe { SHGetKnownFolderPath(folder, 0, ptr::null_mut(), &mut raw_path) };
        if result < 0 {
            if !raw_path.is_null() {
                // SAFETY: any allocation returned through this API uses the COM task allocator.
                unsafe { CoTaskMemFree(raw_path.cast()) };
            }
            return Ok(String::new());
        }
        if raw_path.is_null() {
            return Ok(String::new());
        }
        let mut length = 0usize;
        // SAFETY: a successful SHGetKnownFolderPath returns a NUL-terminated allocation.
        unsafe {
            while *raw_path.add(length) != 0 {
                length += 1;
            }
        }
        // SAFETY: the preceding scan found the terminating NUL within the API allocation.
        let value = String::from_utf16(unsafe { slice::from_raw_parts(raw_path, length) })
            .map_err(|_| Error::WindowsTextMustBeUnicode);
        // SAFETY: SHGetKnownFolderPath allocates with the COM task allocator.
        unsafe { CoTaskMemFree(raw_path.cast()) };
        value
    }
    #[cfg(not(windows))]
    {
        let _ = folder;
        Ok(String::new())
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct EnvVar {
    pub name: String,
    pub value: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum WindowsSubsystem {
    Native,
    WindowsGui,
    WindowsConsole,
    Other,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Config {
    pub kill_children_on_exit: bool,
    pub cwd: String,
    pub command: Vec<OsString>,
    pub env: Vec<EnvVar>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct EmbeddedConfigRange {
    pub marker_start: usize,
    pub config_start: usize,
    pub config_end: usize,
    pub suffix_start: usize,
    pub has_end_marker: bool,
}

pub fn read_embedded_config(exe_path: &Path) -> Result<Vec<u8>> {
    let bytes = read_file_limited(exe_path, MAX_EXE_BYTES)?;
    embedded_config_from_bytes(&bytes).map(<[u8]>::to_vec)
}

pub fn embedded_config_from_bytes(bytes: &[u8]) -> Result<&[u8]> {
    let range = embedded_config_range_from_bytes(bytes).ok_or(Error::NoEmbeddedConfig)?;
    let config = normalize_config_bytes(&bytes[range.config_start..range.config_end]);
    if config
        .iter()
        .all(|byte| matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
    {
        return Err(Error::EmptyEmbeddedConfig);
    }
    validate_config_bytes(config)?;
    Ok(config)
}

pub fn embedded_config_range_from_bytes(bytes: &[u8]) -> Option<EmbeddedConfigRange> {
    let search_start = pe_overlay_start_offset(bytes).unwrap_or(0);
    let marker_relative = rfind_bytes(&bytes[search_start..], CONFIG_START_MARKER)?;
    let marker_start = search_start.checked_add(marker_relative)?;
    let config_start = marker_start.checked_add(CONFIG_START_MARKER.len())?;
    let end_relative = find_bytes(&bytes[config_start..], CONFIG_END_MARKER);
    let config_end = end_relative
        .and_then(|index| config_start.checked_add(index))
        .unwrap_or(bytes.len());
    Some(EmbeddedConfigRange {
        marker_start,
        config_start,
        config_end,
        suffix_start: if end_relative.is_some() {
            config_end
        } else {
            bytes.len()
        },
        has_end_marker: end_relative.is_some(),
    })
}

fn pe_overlay_start_offset(bytes: &[u8]) -> Option<usize> {
    if bytes.get(..2)? != b"MZ" {
        return None;
    }
    let pe_offset = usize::try_from(read_u32(bytes, 0x3c)?).ok()?;
    if bytes.get(pe_offset..pe_offset.checked_add(24)?)?.get(..4)? != b"PE\0\0" {
        return None;
    }
    let section_count = usize::from(read_u16(bytes, pe_offset.checked_add(6)?)?);
    let optional_header_size = usize::from(read_u16(bytes, pe_offset.checked_add(20)?)?);
    let optional_header_offset = pe_offset.checked_add(24)?;
    bytes.get(optional_header_offset..optional_header_offset.checked_add(optional_header_size)?)?;

    let section_table_offset = optional_header_offset.checked_add(optional_header_size)?;
    let section_table_size = section_count.checked_mul(40)?;
    bytes.get(section_table_offset..section_table_offset.checked_add(section_table_size)?)?;
    let mut overlay_start = section_table_offset.checked_add(section_table_size)?;
    for index in 0..section_count {
        let section_offset = section_table_offset.checked_add(index.checked_mul(40)?)?;
        let raw_size = usize::try_from(read_u32(bytes, section_offset.checked_add(16)?)?).ok()?;
        let raw_pointer =
            usize::try_from(read_u32(bytes, section_offset.checked_add(20)?)?).ok()?;
        if raw_size == 0 {
            continue;
        }
        let raw_end = raw_pointer.checked_add(raw_size)?;
        bytes.get(raw_pointer..raw_end)?;
        overlay_start = overlay_start.max(raw_end);
    }

    let directories_offset = match read_u16(bytes, optional_header_offset)? {
        0x10b => 96usize,
        0x20b => 112usize,
        _ => return None,
    };
    let security_offset = directories_offset.checked_add(4 * 8)?;
    if optional_header_size >= security_offset.checked_add(8)? {
        let directory_offset = optional_header_offset.checked_add(security_offset)?;
        let certificate_pointer = usize::try_from(read_u32(bytes, directory_offset)?).ok()?;
        let certificate_size = usize::try_from(read_u32(bytes, directory_offset + 4)?).ok()?;
        if certificate_pointer != 0 && certificate_size != 0 {
            let certificate_end = certificate_pointer.checked_add(certificate_size)?;
            bytes.get(certificate_pointer..certificate_end)?;
            overlay_start = overlay_start.max(certificate_end);
        }
    }
    (overlay_start <= bytes.len()).then_some(overlay_start)
}

pub fn windows_subsystem_from_pe_bytes(bytes: &[u8]) -> Result<WindowsSubsystem> {
    let offset = windows_subsystem_field_offset_from_pe_bytes(bytes)?;
    Ok(match read_u16(bytes, offset).ok_or(Error::InvalidPeFile)? {
        1 => WindowsSubsystem::Native,
        PE_SUBSYSTEM_WINDOWED => WindowsSubsystem::WindowsGui,
        PE_SUBSYSTEM_CONSOLE => WindowsSubsystem::WindowsConsole,
        _ => WindowsSubsystem::Other,
    })
}

pub fn pe_has_certificate_table(bytes: &[u8]) -> Result<bool> {
    if bytes.get(..2) != Some(b"MZ".as_slice()) {
        return Err(Error::InvalidPeFile);
    }
    let pe_offset = usize::try_from(read_u32(bytes, 0x3c).ok_or(Error::InvalidPeFile)?)
        .map_err(|_| Error::InvalidPeFile)?;
    let optional_offset = pe_offset.checked_add(24).ok_or(Error::InvalidPeFile)?;
    if bytes
        .get(pe_offset..optional_offset)
        .and_then(|header| header.get(..4))
        != Some(b"PE\0\0")
    {
        return Err(Error::InvalidPeFile);
    }
    let optional_size = usize::from(read_u16(bytes, pe_offset + 20).ok_or(Error::InvalidPeFile)?);
    let directories_offset = match read_u16(bytes, optional_offset) {
        Some(0x10b) => 96usize,
        Some(0x20b) => 112usize,
        _ => return Err(Error::InvalidPeFile),
    };
    let security_offset = directories_offset
        .checked_add(4 * 8)
        .ok_or(Error::InvalidPeFile)?;
    if optional_size < security_offset + 8 {
        return Ok(false);
    }
    let directory_offset = optional_offset
        .checked_add(security_offset)
        .ok_or(Error::InvalidPeFile)?;
    let certificate_pointer = read_u32(bytes, directory_offset).ok_or(Error::InvalidPeFile)?;
    let certificate_size = read_u32(bytes, directory_offset + 4).ok_or(Error::InvalidPeFile)?;
    Ok(certificate_pointer != 0 || certificate_size != 0)
}

pub fn set_windows_subsystem(path: &Path, subsystem: WindowsSubsystem) -> Result<()> {
    let mut file = OpenOptions::new().read(true).write(true).open(path)?;
    let metadata = file.metadata()?;
    if metadata.len() > MAX_EXE_BYTES {
        return Err(Error::FileTooBig);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    (&mut file)
        .take(MAX_EXE_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_EXE_BYTES {
        return Err(Error::FileTooBig);
    }
    let offset = windows_subsystem_field_offset_from_pe_bytes(&bytes)?;
    set_windows_subsystem_in_bytes(&mut bytes, subsystem)?;
    file.seek(SeekFrom::Start(offset as u64))?;
    file.write_all(&bytes[offset..offset + 2])?;
    Ok(())
}

pub fn set_windows_subsystem_in_bytes(bytes: &mut [u8], subsystem: WindowsSubsystem) -> Result<()> {
    let offset = windows_subsystem_field_offset_from_pe_bytes(bytes)?;
    let value = match subsystem {
        WindowsSubsystem::WindowsConsole => PE_SUBSYSTEM_CONSOLE,
        WindowsSubsystem::WindowsGui => PE_SUBSYSTEM_WINDOWED,
        _ => return Err(Error::UnsupportedWindowsSubsystem),
    };
    bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    Ok(())
}

pub fn child_should_inherit_stdio(subsystem: WindowsSubsystem) -> bool {
    subsystem != WindowsSubsystem::WindowsGui
}

fn windows_subsystem_field_offset_from_pe_bytes(bytes: &[u8]) -> Result<usize> {
    if bytes.get(..2) != Some(b"MZ".as_slice()) {
        return Err(Error::InvalidPeFile);
    }
    let pe_offset = usize::try_from(read_u32(bytes, 0x3c).ok_or(Error::InvalidPeFile)?)
        .map_err(|_| Error::InvalidPeFile)?;
    let header_end = pe_offset.checked_add(24).ok_or(Error::InvalidPeFile)?;
    if bytes
        .get(pe_offset..header_end)
        .and_then(|header| header.get(..4))
        != Some(b"PE\0\0")
    {
        return Err(Error::InvalidPeFile);
    }
    let optional_size = usize::from(read_u16(bytes, pe_offset + 20).ok_or(Error::InvalidPeFile)?);
    let optional_offset = pe_offset + 24;
    bytes
        .get(
            optional_offset
                ..optional_offset
                    .checked_add(optional_size)
                    .ok_or(Error::InvalidPeFile)?,
        )
        .ok_or(Error::InvalidPeFile)?;
    if optional_size < 70 || !matches!(read_u16(bytes, optional_offset), Some(0x10b | 0x20b)) {
        return Err(Error::InvalidPeFile);
    }
    optional_offset.checked_add(68).ok_or(Error::InvalidPeFile)
}

pub fn validate_config_bytes(bytes: &[u8]) -> Result<()> {
    std::str::from_utf8(normalize_config_bytes(bytes))
        .map(|_| ())
        .map_err(|_| Error::ConfigMustBeUtf8)
}

pub fn validate_stampable_config(bytes: &[u8]) -> Result<()> {
    validate_config_bytes(bytes)?;
    let normalized = normalize_config_bytes(bytes);
    if find_bytes(normalized, CONFIG_START_MARKER).is_some()
        || find_bytes(normalized, CONFIG_END_MARKER).is_some()
    {
        return Err(Error::ReservedOverlayMarkerInConfig);
    }

    let text = std::str::from_utf8(normalized).map_err(|_| Error::ConfigMustBeUtf8)?;
    let scanned = template_scan::scan_with_random_sentinels(text)?;
    reject_duplicate_keys(&scanned.json)?;
    JsonParser::parse(&scanned.json)?;

    for sentinel in &scanned.sentinels {
        template_expr::parse(&sentinel.expression)?;
    }
    Ok(())
}

pub struct ParseConfigOptions<'a> {
    pub paths: &'a RuntimePaths,
    pub args0: &'a str,
    pub args: &'a [OsString],
    pub env_map: &'a mut EnvMap,
}

pub fn parse_config(bytes: &[u8], paths: &RuntimePaths) -> Result<Config> {
    let mut environment = EnvMap::default();
    parse_config_with_options(
        bytes,
        ParseConfigOptions {
            paths,
            args0: &paths.exe_path,
            args: &[],
            env_map: &mut environment,
        },
    )
}

pub fn parse_config_with_options(bytes: &[u8], options: ParseConfigOptions<'_>) -> Result<Config> {
    validate_config_bytes(bytes)?;
    let normalized =
        std::str::from_utf8(normalize_config_bytes(bytes)).map_err(|_| Error::ConfigMustBeUtf8)?;
    let scanned = template_scan::scan_with_random_sentinels(normalized)?;
    reject_duplicate_keys(&scanned.json)?;
    let parsed = JsonParser::parse(&scanned.json)?;
    let root = parsed.as_object().ok_or(Error::ConfigMustBeObject)?;
    reject_template_object_keys(&parsed, &scanned.sentinels)?;
    validate_top_level_shape(root)?;

    let strictness = template_expr::Strictness {
        error_on_missing_env: get_bool(
            root,
            "error_on_missing_env",
            Error::ErrorOnMissingEnvMustBeBoolean,
        )?
        .unwrap_or(false),
        error_on_arg_out_of_bounds: get_bool(
            root,
            "error_on_arg_out_of_bounds",
            Error::ErrorOnArgOutOfBoundsMustBeBoolean,
        )?
        .unwrap_or(false),
    };
    let metadata = metadata_from_runtime(
        options.paths,
        if options.args0.is_empty() {
            &options.paths.exe_path
        } else {
            options.args0
        },
    );
    let mut context = template_expr::EvalContext {
        metadata: &metadata,
        env: options.env_map,
        args: options.args,
        strictness,
    };
    let kill_children_on_exit = get_bool(
        root,
        "kill_children_on_exit",
        Error::KillChildrenOnExitMustBeBoolean,
    )?
    .unwrap_or(false);
    let environment = parse_env(object_get(root, "env"), &mut context, &scanned.sentinels)?;
    let cwd = match object_get(root, "cwd") {
        Some(value) => eval_string_field(
            value,
            &mut context,
            &scanned.sentinels,
            Error::CwdMustBeString,
        )?,
        None => options.paths.launch_cwd.clone(),
    };
    let command = eval_command(
        object_get(root, "command").ok_or(Error::MissingCommand)?,
        &mut context,
        &scanned.sentinels,
    )?;
    Ok(Config {
        kill_children_on_exit,
        cwd,
        command,
        env: environment,
    })
}

fn validate_top_level_shape(root: &[(String, JsonValue)]) -> Result<()> {
    let mut saw_command = false;
    for (key, _) in root {
        if key == "terminal" {
            return Err(Error::TerminalConfigRemoved);
        }
        if !is_known_top_level_key(key) {
            return Err(Error::UnknownTopLevelKey);
        }
        if saw_command {
            return Err(Error::CommandMustBeLast);
        }
        saw_command = key == "command";
    }
    if saw_command {
        Ok(())
    } else {
        Err(Error::MissingCommand)
    }
}

fn is_known_top_level_key(key: &str) -> bool {
    matches!(
        key,
        "command"
            | "cwd"
            | "env"
            | "kill_children_on_exit"
            | "error_on_missing_env"
            | "error_on_arg_out_of_bounds"
    )
}

fn parse_env(
    value: Option<&JsonValue>,
    context: &mut template_expr::EvalContext<'_>,
    sentinels: &[template_scan::Sentinel],
) -> Result<Vec<EnvVar>> {
    let Some(value) = value else {
        return Ok(Vec::new());
    };
    let object = value.as_object().ok_or(Error::EnvMustBeObject)?;
    let mut variables = Vec::with_capacity(object.len());
    for (name, value) in object {
        let value = eval_string_field(value, context, sentinels, Error::EnvValuesMustBeStrings)?;
        variables.push(EnvVar {
            name: name.clone(),
            value: value.clone(),
        });
        context.env.put(name.clone(), value);
    }
    Ok(variables)
}

fn eval_string_field(
    value: &JsonValue,
    context: &mut template_expr::EvalContext<'_>,
    sentinels: &[template_scan::Sentinel],
    type_error: Error,
) -> Result<String> {
    let raw = value.as_str().ok_or(type_error)?;
    eval_template_string(raw, context, sentinels)
}

fn eval_command(
    value: &JsonValue,
    context: &mut template_expr::EvalContext<'_>,
    sentinels: &[template_scan::Sentinel],
) -> Result<Vec<OsString>> {
    let array = value.as_array().ok_or(Error::CommandMustBeArray)?;
    if array.is_empty() {
        return Err(Error::CommandMustNotBeEmpty);
    }
    let mut command = Vec::new();
    for item in array {
        match item {
            JsonValue::Number(key) => {
                let sentinel =
                    find_sentinel_key(key, sentinels).ok_or(Error::CommandEntriesMustBeStrings)?;
                match template_expr::evaluate(&sentinel.expression, context)? {
                    template_expr::Value::List(items) => command.extend(items),
                    _ => return Err(Error::TemplateMustEvaluateToList),
                }
            }
            JsonValue::String(raw) => {
                command.push(eval_template_string(raw, context, sentinels)?.into());
            }
            _ => return Err(Error::CommandEntriesMustBeStrings),
        }
    }
    if command.is_empty() {
        Err(Error::CommandMustNotBeEmpty)
    } else {
        Ok(command)
    }
}

fn eval_template_string(
    raw: &str,
    context: &mut template_expr::EvalContext<'_>,
    sentinels: &[template_scan::Sentinel],
) -> Result<String> {
    let bytes = raw.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        if let Some((sentinel, length)) = find_spaced_sentinel_at(&bytes[index..], sentinels) {
            match template_expr::evaluate(&sentinel.expression, context)? {
                template_expr::Value::String(value) => out.extend_from_slice(value.as_bytes()),
                template_expr::Value::List(_) => return Err(Error::ListTemplateNotAllowedInString),
                template_expr::Value::Integer(_) => {
                    return Err(Error::TemplateMustEvaluateToString);
                }
            }
            index += length;
        } else {
            out.push(bytes[index]);
            index += 1;
        }
    }
    String::from_utf8(out).map_err(|_| Error::InvalidString)
}

fn find_sentinel_key<'a>(
    key: &str,
    sentinels: &'a [template_scan::Sentinel],
) -> Option<&'a template_scan::Sentinel> {
    sentinels.iter().find(|sentinel| sentinel.key == key)
}

fn find_spaced_sentinel_at<'a>(
    value: &[u8],
    sentinels: &'a [template_scan::Sentinel],
) -> Option<(&'a template_scan::Sentinel, usize)> {
    if value.len() < template_scan::SPACED_SENTINEL_LEN || !value.starts_with(b" ") {
        return None;
    }
    let key_bytes = value.get(1..1 + template_scan::SENTINEL_KEY_LEN)?;
    let key = std::str::from_utf8(key_bytes).ok()?;
    if value[1 + template_scan::SENTINEL_KEY_LEN] != b' '
        || !template_scan::is_numeric_sentinel_key(key)
    {
        return None;
    }
    Some((
        find_sentinel_key(key, sentinels)?,
        template_scan::SPACED_SENTINEL_LEN,
    ))
}

fn string_contains_sentinel(value: &str, sentinels: &[template_scan::Sentinel]) -> bool {
    let bytes = value.as_bytes();
    (0..bytes.len()).any(|index| find_spaced_sentinel_at(&bytes[index..], sentinels).is_some())
}

fn reject_template_object_keys(
    value: &JsonValue,
    sentinels: &[template_scan::Sentinel],
) -> Result<()> {
    match value {
        JsonValue::Object(object) => {
            for (key, value) in object {
                if string_contains_sentinel(key, sentinels) {
                    return Err(Error::TemplateInObjectKey);
                }
                reject_template_object_keys(value, sentinels)?;
            }
        }
        JsonValue::Array(array) => {
            for value in array {
                reject_template_object_keys(value, sentinels)?;
            }
        }
        _ => {}
    }
    Ok(())
}

struct DuplicateKeyScanner<'a> {
    input: &'a str,
    index: usize,
}

impl<'a> DuplicateKeyScanner<'a> {
    fn scan(&mut self) -> Result<()> {
        self.skip_value(0)?;
        self.skip_whitespace();
        if self.index == self.input.len() {
            Ok(())
        } else {
            Err(Error::InvalidJson)
        }
    }

    fn skip_value(&mut self, depth: usize) -> Result<()> {
        if depth > MAX_JSON_DEPTH {
            return Err(Error::InvalidJson);
        }
        self.skip_whitespace();
        let Some(&byte) = self.input.as_bytes().get(self.index) else {
            return Err(Error::InvalidJson);
        };
        match byte {
            b'{' => self.skip_object(depth),
            b'[' => self.skip_array(depth),
            b'"' => self.read_string().map(|_| ()),
            b't' => self.skip_literal("true"),
            b'f' => self.skip_literal("false"),
            b'n' => self.skip_literal("null"),
            b'-' | b'0'..=b'9' => self.skip_number(),
            _ => Err(Error::InvalidJson),
        }
    }

    fn skip_object(&mut self, depth: usize) -> Result<()> {
        self.index += 1;
        let mut seen = BTreeSet::new();
        self.skip_whitespace();
        if self.consume(b'}') {
            return Ok(());
        }
        loop {
            self.skip_whitespace();
            if self.input.as_bytes().get(self.index) != Some(&b'"') {
                return Err(Error::InvalidJson);
            }
            let key = self.read_string()?;
            if !seen.insert(key) {
                return Err(Error::DuplicateJsonKey);
            }
            self.skip_whitespace();
            if !self.consume(b':') {
                return Err(Error::InvalidJson);
            }
            self.skip_value(depth + 1)?;
            self.skip_whitespace();
            if self.consume(b'}') {
                return Ok(());
            }
            if !self.consume(b',') {
                return Err(Error::InvalidJson);
            }
        }
    }

    fn skip_array(&mut self, depth: usize) -> Result<()> {
        self.index += 1;
        self.skip_whitespace();
        if self.consume(b']') {
            return Ok(());
        }
        loop {
            self.skip_value(depth + 1)?;
            self.skip_whitespace();
            if self.consume(b']') {
                return Ok(());
            }
            if !self.consume(b',') {
                return Err(Error::InvalidJson);
            }
        }
    }

    fn read_string(&mut self) -> Result<&'a str> {
        let start = self.index;
        self.index += 1;
        while self.index < self.input.len() {
            match self.input.as_bytes()[self.index] {
                b'"' => {
                    self.index += 1;
                    return Ok(&self.input[start..self.index]);
                }
                b'\\' => {
                    self.index += 1;
                    let Some(&escaped) = self.input.as_bytes().get(self.index) else {
                        return Err(Error::InvalidJson);
                    };
                    if escaped == b'u' {
                        if self.index + 4 >= self.input.len() {
                            return Err(Error::InvalidJson);
                        }
                        self.index += 4;
                    }
                }
                0x00..=0x1f => return Err(Error::InvalidJson),
                _ => {}
            }
            self.index += 1;
        }
        Err(Error::InvalidJson)
    }

    fn skip_literal(&mut self, literal: &str) -> Result<()> {
        if self.input[self.index..].starts_with(literal) {
            self.index += literal.len();
            Ok(())
        } else {
            Err(Error::InvalidJson)
        }
    }

    fn skip_number(&mut self) -> Result<()> {
        if self.consume(b'-') && self.index >= self.input.len() {
            return Err(Error::InvalidJson);
        }
        self.skip_digits()?;
        if self.consume(b'.') {
            self.skip_digits()?;
        }
        if self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(|byte| matches!(byte, b'e' | b'E'))
        {
            self.index += 1;
            if !self.consume(b'+') {
                self.consume(b'-');
            }
            self.skip_digits()?;
        }
        Ok(())
    }

    fn skip_digits(&mut self) -> Result<()> {
        let start = self.index;
        while self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(u8::is_ascii_digit)
        {
            self.index += 1;
        }
        if self.index == start {
            Err(Error::InvalidJson)
        } else {
            Ok(())
        }
    }

    fn skip_whitespace(&mut self) {
        while self
            .input
            .as_bytes()
            .get(self.index)
            .is_some_and(|byte| matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
        {
            self.index += 1;
        }
    }

    fn consume(&mut self, byte: u8) -> bool {
        if self.input.as_bytes().get(self.index) == Some(&byte) {
            self.index += 1;
            true
        } else {
            false
        }
    }
}

fn reject_duplicate_keys(json: &str) -> Result<()> {
    DuplicateKeyScanner {
        input: json,
        index: 0,
    }
    .scan()
}

fn metadata_from_runtime(paths: &RuntimePaths, args0: &str) -> template_expr::Metadata {
    template_expr::Metadata {
        exe_path: paths.exe_path.clone(),
        exe_dir: paths.exe_dir.clone(),
        exe_filename: if paths.exe_filename.is_empty() {
            paths.exe_name.clone()
        } else {
            paths.exe_filename.clone()
        },
        exe_filename_noext: if paths.exe_filename_noext.is_empty() {
            paths.exe_stem.clone()
        } else {
            paths.exe_filename_noext.clone()
        },
        exe_ext: paths.exe_ext.clone(),
        exe_ext_dot: paths.exe_ext_dot.clone(),
        exe_drive: paths.exe_drive.clone(),
        exe_root: paths.exe_root.clone(),
        args0: args0.to_owned(),
        cwd: paths.launch_cwd.clone(),
        temp_dir: paths.temp_dir.clone(),
        home_dir: paths.home_dir.clone(),
        appdata_dir: paths.appdata_dir.clone(),
        localappdata_dir: paths.localappdata_dir.clone(),
        programdata_dir: paths.programdata_dir.clone(),
        program_files_dir: paths.program_files_dir.clone(),
        program_files_x86_dir: paths.program_files_x86_dir.clone(),
        documents_dir: paths.documents_dir.clone(),
        downloads_dir: paths.downloads_dir.clone(),
        desktop_dir: paths.desktop_dir.clone(),
        os: env::consts::OS.to_owned(),
        arch: env::consts::ARCH.to_owned(),
        dir_sep: if cfg!(windows) { "\\" } else { "/" }.to_owned(),
        path_sep: if cfg!(windows) { ";" } else { ":" }.to_owned(),
    }
}

fn get_bool(root: &[(String, JsonValue)], key: &str, type_error: Error) -> Result<Option<bool>> {
    match object_get(root, key) {
        None => Ok(None),
        Some(JsonValue::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(type_error),
    }
}

fn normalize_config_bytes(bytes: &[u8]) -> &[u8] {
    let mut output = trim_ascii_left(bytes);
    if output.starts_with(&[0xef, 0xbb, 0xbf]) {
        output = trim_ascii_left(&output[3..]);
    }
    output
}

fn trim_ascii_left(mut bytes: &[u8]) -> &[u8] {
    while bytes
        .first()
        .is_some_and(|byte| matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
    {
        bytes = &bytes[1..];
    }
    bytes
}

pub(crate) fn read_file_limited(path: &Path, limit: u64) -> Result<Vec<u8>> {
    let file = File::open(path)?;
    let metadata = file.metadata()?;
    if metadata.len() > limit {
        return Err(Error::FileTooBig);
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(limit.saturating_add(1)).read_to_end(&mut bytes)?;
    if bytes.len() as u64 > limit {
        return Err(Error::FileTooBig);
    }
    Ok(bytes)
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

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        Some(0)
    } else {
        haystack
            .windows(needle.len())
            .position(|window| window == needle)
    }
}

fn rfind_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() {
        Some(haystack.len())
    } else {
        haystack
            .windows(needle.len())
            .rposition(|window| window == needle)
    }
}

fn is_path_separator(byte: u8) -> bool {
    matches!(byte, b'\\' | b'/')
}

fn path_drive(path: &str) -> &str {
    let bytes = path.as_bytes();
    if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        &path[..2]
    } else if bytes.len() >= 2 && is_path_separator(bytes[0]) && is_path_separator(bytes[1]) {
        unc_share_end(path)
            .map(|end| path[..end].trim_end_matches(['\\', '/']))
            .unwrap_or("")
    } else {
        ""
    }
}

fn path_root(path: &str) -> &str {
    let bytes = path.as_bytes();
    let length = if bytes.len() >= 2 && is_path_separator(bytes[0]) && is_path_separator(bytes[1]) {
        unc_share_end(path).unwrap_or(2)
    } else if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && is_path_separator(bytes[2])
    {
        3
    } else if bytes.len() >= 2 && bytes[0].is_ascii_alphabetic() && bytes[1] == b':' {
        2
    } else if bytes.first().is_some_and(|byte| is_path_separator(*byte)) {
        1
    } else {
        0
    };
    &path[..length]
}

fn unc_share_end(path: &str) -> Option<usize> {
    let bytes = path.as_bytes();
    let mut index = 2;
    let mut parts = 0;
    while index < bytes.len() {
        while index < bytes.len() && is_path_separator(bytes[index]) {
            index += 1;
        }
        if index >= bytes.len() {
            break;
        }
        parts += 1;
        while index < bytes.len() && !is_path_separator(bytes[index]) {
            index += 1;
        }
        if parts == 2 {
            return Some(if index < bytes.len() {
                index + 1
            } else {
                index
            });
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_paths() -> RuntimePaths {
        RuntimePaths {
            exe_path: r"C:\bundle\bin\tool.exe".into(),
            exe_dir: r"C:\bundle\bin".into(),
            exe_filename: "tool.exe".into(),
            exe_filename_noext: "tool".into(),
            exe_name: "tool.exe".into(),
            exe_stem: "tool".into(),
            exe_ext: "exe".into(),
            exe_ext_dot: ".exe".into(),
            exe_drive: "C:".into(),
            exe_root: r"C:\".into(),
            launch_cwd: r"C:\work".into(),
            temp_dir: r"C:\Temp".into(),
            home_dir: r"C:\Users\test".into(),
            appdata_dir: String::new(),
            localappdata_dir: String::new(),
            programdata_dir: String::new(),
            program_files_dir: String::new(),
            program_files_x86_dir: String::new(),
            documents_dir: String::new(),
            downloads_dir: String::new(),
            desktop_dir: String::new(),
        }
    }

    fn minimal_pe(magic: u16, subsystem: u16) -> Vec<u8> {
        let mut bytes = vec![0u8; 512];
        bytes[..2].copy_from_slice(b"MZ");
        bytes[0x3c..0x40].copy_from_slice(&0x80u32.to_le_bytes());
        bytes[0x80..0x84].copy_from_slice(b"PE\0\0");
        bytes[0x80 + 20..0x80 + 22].copy_from_slice(&0xf0u16.to_le_bytes());
        bytes[0x80 + 24..0x80 + 26].copy_from_slice(&magic.to_le_bytes());
        bytes[0x80 + 24 + 68..0x80 + 24 + 70].copy_from_slice(&subsystem.to_le_bytes());
        bytes
    }

    fn minimal_pe_with_section(length: usize, raw_pointer: u32, raw_size: u32) -> Vec<u8> {
        let mut bytes = minimal_pe(0x20b, PE_SUBSYSTEM_CONSOLE);
        bytes.resize(length, 0);
        bytes[0x80 + 6..0x80 + 8].copy_from_slice(&1u16.to_le_bytes());
        let section = 0x80 + 24 + 0xf0;
        bytes[section + 16..section + 20].copy_from_slice(&raw_size.to_le_bytes());
        bytes[section + 20..section + 24].copy_from_slice(&raw_pointer.to_le_bytes());
        bytes
    }

    #[test]
    fn normalizes_utf8_bom_before_parsing_config() {
        let config = b" \r\n\xef\xbb\xbf \t{\"command\":[\"cmd.exe\"]}";
        assert_eq!(
            parse_config(config, &test_paths()).unwrap().command[0],
            "cmd.exe"
        );
    }

    #[test]
    fn accepts_utf8_config_strings() {
        let config = parse_config(
            "{\"command\":[\"cmd.exe\",\"/C\",\"echo café @{exe_filename_noext}\"]}".as_bytes(),
            &test_paths(),
        )
        .unwrap();
        assert_eq!(config.command[2], "echo café tool");
    }

    #[test]
    fn json_parser_decodes_escapes_and_keeps_number_text() {
        let parsed = JsonParser::parse(
            r#"{"text":"quote:\" slash:\/ emoji:\ud83d\ude03","number":-12.50e+7}"#,
        )
        .unwrap();
        let object = parsed.as_object().unwrap();
        assert_eq!(
            object_get(object, "text"),
            Some(&JsonValue::String("quote:\" slash:/ emoji:😃".into()))
        );
        assert_eq!(
            object_get(object, "number"),
            Some(&JsonValue::Number("-12.50e+7".into()))
        );
    }

    #[cfg(windows)]
    #[test]
    fn environment_names_use_windows_unicode_case_folding() {
        let mut environment = EnvMap::default();
        environment.put("ÉXÉWRAP".into(), "first".into());
        assert_eq!(environment.get("éxéwrap"), Some("first"));
        environment.put("éxéwrap".into(), "second".into());
        assert_eq!(environment.iter().count(), 1);
        assert_eq!(environment.get("ÉXÉWRAP"), Some("second"));
    }

    #[test]
    fn json_parser_rejects_invalid_grammar() {
        for invalid in [
            "",
            "01",
            "1.",
            "1e",
            r#""\ud800""#,
            r#""\udc00""#,
            r#""\uzzzz""#,
            "[1,]",
            r#"{"x":1,}"#,
            r#"{"x":"\q"}"#,
        ] {
            assert!(
                matches!(JsonParser::parse(invalid), Err(Error::SyntaxError)),
                "accepted invalid JSON: {invalid}"
            );
        }
    }

    #[test]
    fn json_parser_preserves_object_order() {
        let parsed = JsonParser::parse(r#"{"third":3,"first":1,"second":2}"#).unwrap();
        let keys: Vec<_> = parsed
            .as_object()
            .unwrap()
            .iter()
            .map(|(key, _)| key.as_str())
            .collect();
        assert_eq!(keys, ["third", "first", "second"]);
    }

    #[test]
    fn rejects_non_utf8_config() {
        assert!(matches!(
            validate_config_bytes(&[0xff, 0xfe]),
            Err(Error::ConfigMustBeUtf8)
        ));
    }

    #[test]
    fn overlay_markers_and_ranges_match_the_format() {
        assert_eq!(MARKER_UUID.len(), 36);
        assert_eq!(END_MARKER_UUID.len(), 36);
        let bytes = [b"prefix".as_slice(), CONFIG_START_MARKER, b"abc"].concat();
        assert_eq!(embedded_config_from_bytes(&bytes).unwrap(), b"abc");

        let bytes = [
            b"prefix".as_slice(),
            CONFIG_START_MARKER,
            b"abc",
            CONFIG_END_MARKER,
            b"suffix",
        ]
        .concat();
        assert_eq!(embedded_config_from_bytes(&bytes).unwrap(), b"abc");
        let range = embedded_config_range_from_bytes(&bytes).unwrap();
        assert!(range.has_end_marker);
        assert_eq!(
            &bytes[range.config_end..],
            [CONFIG_END_MARKER, b"suffix"].concat()
        );
    }

    #[test]
    fn embedded_config_uses_last_start_marker() {
        let bytes = [
            b"old".as_slice(),
            CONFIG_START_MARKER,
            b"old-config",
            CONFIG_START_MARKER,
            b"new-config",
        ]
        .concat();
        assert_eq!(embedded_config_from_bytes(&bytes).unwrap(), b"new-config");
    }

    #[test]
    fn embedded_config_ignores_pe_image_markers_and_scans_the_overlay() {
        let mut image_only = minimal_pe_with_section(0x400, 0x200, 0x100);
        image_only[0x220..0x220 + CONFIG_START_MARKER.len()].copy_from_slice(CONFIG_START_MARKER);
        assert!(embedded_config_range_from_bytes(&image_only).is_none());
        assert!(matches!(
            embedded_config_from_bytes(&image_only),
            Err(Error::NoEmbeddedConfig)
        ));

        let config = br#"{"command":["cmd.exe"]}"#;
        let mut with_overlay = minimal_pe_with_section(
            0x300 + CONFIG_START_MARKER.len() + config.len(),
            0x200,
            0x100,
        );
        with_overlay[0x220..0x220 + CONFIG_START_MARKER.len()].copy_from_slice(CONFIG_START_MARKER);
        with_overlay[0x300..0x300 + CONFIG_START_MARKER.len()].copy_from_slice(CONFIG_START_MARKER);
        with_overlay[0x300 + CONFIG_START_MARKER.len()..].copy_from_slice(config);
        let range = embedded_config_range_from_bytes(&with_overlay).unwrap();
        assert_eq!(range.marker_start, 0x300);
        assert_eq!(embedded_config_from_bytes(&with_overlay).unwrap(), config);
    }

    #[test]
    fn pe_subsystem_helper_identifies_and_patches_pe32_and_pe32_plus() {
        for magic in [0x10b, 0x20b] {
            let mut bytes = minimal_pe(magic, PE_SUBSYSTEM_CONSOLE);
            assert_eq!(
                windows_subsystem_from_pe_bytes(&bytes).unwrap(),
                WindowsSubsystem::WindowsConsole
            );
            set_windows_subsystem_in_bytes(&mut bytes, WindowsSubsystem::WindowsGui).unwrap();
            assert_eq!(
                windows_subsystem_from_pe_bytes(&bytes).unwrap(),
                WindowsSubsystem::WindowsGui
            );
        }
    }

    #[test]
    fn parse_config_expands_paths_and_argument_splices() {
        let mut environment = EnvMap::default();
        let arguments = ["one", "two"].map(OsString::from);
        let config = parse_config_with_options(
            br#"{
                "cwd":"@{exe_dir:parent:join("app")}",
                "env":{"APP":"@{exe_filename_noext}"},
                "command":["@{exe_dir}\\python.exe", @{args}]
            }"#,
            ParseConfigOptions {
                paths: &test_paths(),
                args0: "tool.exe",
                args: &arguments,
                env_map: &mut environment,
            },
        )
        .unwrap();
        assert_eq!(config.cwd, r"C:\bundle\app");
        assert_eq!(
            config.command,
            vec![r"C:\bundle\bin\python.exe", "one", "two"]
        );
        assert_eq!(environment.get("APP"), Some("tool"));
    }

    #[test]
    fn top_level_keys_are_strict_and_command_is_last() {
        let paths = test_paths();
        assert!(matches!(
            parse_config(br#"{"terminal":true,"command":["x"]}"#, &paths),
            Err(Error::TerminalConfigRemoved)
        ));
        assert!(matches!(
            parse_config(br#"{"wat":true,"command":["x"]}"#, &paths),
            Err(Error::UnknownTopLevelKey)
        ));
        assert!(matches!(
            parse_config(br#"{"command":["x"],"cwd":"."}"#, &paths),
            Err(Error::CommandMustBeLast)
        ));
        assert!(matches!(
            parse_config(br#"{"cwd":"."}"#, &paths),
            Err(Error::MissingCommand)
        ));
    }

    #[test]
    fn environment_values_mutate_in_source_order() {
        let mut environment = EnvMap::default();
        environment.put("PATH".into(), "base".into());
        let config = parse_config_with_options(
            br#"{
              "env":{
                "PATH":"@{env["PATH"]:prepend_env("first")}",
                "AFTER":"@{env["PATH"]}"
              },
              "command":["@{env["AFTER"]}"]
            }"#,
            ParseConfigOptions {
                paths: &test_paths(),
                args0: "",
                args: &[],
                env_map: &mut environment,
            },
        )
        .unwrap();
        assert_eq!(config.command, ["first;base"]);
        assert_eq!(environment.get("AFTER"), Some("first;base"));
    }

    #[test]
    fn args_as_json_populates_env_and_single_quoted_powershell_source() {
        let mut environment = EnvMap::default();
        let arguments = ["a'b", "x\"y", "dollar$backtick`", "line\r\nnext"].map(OsString::from);
        let config = parse_config_with_options(
            br#"{
              "env":{"__ARGS_AS_JSON__":"@{args_as_json}"},
              "command":["powershell.exe","-Command","$ArgsJson='@{args_as_json}'"]
            }"#,
            ParseConfigOptions {
                paths: &test_paths(),
                args0: "tool.exe",
                args: &arguments,
                env_map: &mut environment,
            },
        )
        .unwrap();
        let expected =
            r#"["a\u0027b","x\u0022y","dollar\u0024backtick\u0060","line\u000d\u000anext"]"#;
        assert_eq!(config.env[0].value, expected);
        assert_eq!(
            config.command[2].to_str(),
            Some(format!("$ArgsJson='{expected}'").as_str())
        );
    }

    #[test]
    fn strict_missing_environment_and_argument_failures_are_reported() {
        let paths = test_paths();
        let mut environment = EnvMap::default();
        assert!(matches!(
            parse_config_with_options(
                br#"{"error_on_missing_env":true,"command":["@{env["MISSING"]}"]}"#,
                ParseConfigOptions {
                    paths: &paths,
                    args0: "",
                    args: &[],
                    env_map: &mut environment,
                }
            ),
            Err(Error::MissingEnvironmentVariable)
        ));
        let arguments = [OsString::from("only-one")];
        assert!(matches!(
            parse_config_with_options(
                br#"{"error_on_arg_out_of_bounds":true,"command":["@{args[2]}"]}"#,
                ParseConfigOptions {
                    paths: &paths,
                    args0: "",
                    args: &arguments,
                    env_map: &mut environment,
                }
            ),
            Err(Error::ArgumentOutOfBounds)
        ));
    }

    #[test]
    fn strict_failures_boolean_types_duplicate_keys_and_object_templates_are_rejected() {
        let paths = test_paths();
        assert!(matches!(
            parse_config(
                br#"{"kill_children_on_exit":"true","command":["x"]}"#,
                &paths
            ),
            Err(Error::KillChildrenOnExitMustBeBoolean)
        ));
        assert!(matches!(
            parse_config(br#"{"cwd":"a","cwd":"b","command":["x"]}"#, &paths),
            Err(Error::DuplicateJsonKey)
        ));
        assert!(matches!(
            parse_config(
                br#"{"command":["first"],"\u0063ommand":["second"]}"#,
                &paths
            ),
            Err(Error::DuplicateJsonKey)
        ));
        assert!(matches!(
            parse_config(
                br#"{"env":{"PATH":"one","\u0050ATH":"two"},"command":["x"]}"#,
                &paths
            ),
            Err(Error::DuplicateJsonKey)
        ));
        assert!(matches!(
            parse_config(br#"{"env":{"@{exe_dir}":"x"},"command":["x"]}"#, &paths),
            Err(Error::TemplateInObjectKey)
        ));
    }

    #[test]
    fn raw_numeric_command_sentinels_only_accept_lists() {
        let paths = test_paths();
        let mut environment = EnvMap::default();
        let arguments = ["a", "b"].map(OsString::from);
        assert!(matches!(
            parse_config_with_options(
                br#"{"command":[@{args[1]}]}"#,
                ParseConfigOptions {
                    paths: &paths,
                    args0: "",
                    args: &arguments,
                    env_map: &mut environment,
                }
            ),
            Err(Error::TemplateMustEvaluateToList)
        ));
        assert!(matches!(
            parse_config_with_options(
                br#"{"command":["@{args}"]}"#,
                ParseConfigOptions {
                    paths: &paths,
                    args0: "",
                    args: &arguments,
                    env_map: &mut environment,
                }
            ),
            Err(Error::ListTemplateNotAllowedInString)
        ));
        assert!(matches!(
            parse_config(br#"{"command":[1]}"#, &paths),
            Err(Error::CommandEntriesMustBeStrings)
        ));
        let mut empty_environment = EnvMap::default();
        assert!(matches!(
            parse_config_with_options(
                br#"{"command":[@{args}]}"#,
                ParseConfigOptions {
                    paths: &paths,
                    args0: "",
                    args: &[],
                    env_map: &mut empty_environment,
                }
            ),
            Err(Error::CommandMustNotBeEmpty)
        ));
    }

    #[cfg(windows)]
    #[test]
    fn raw_argument_splices_preserve_unpaired_utf16() {
        use std::os::windows::ffi::{OsStrExt, OsStringExt};

        let paths = test_paths();
        let mut environment = EnvMap::default();
        let arguments = [OsString::from_wide(&[0xd800, b'A' as u16])];
        let config = parse_config_with_options(
            br#"{"command":["cmd.exe",@{args}]}"#,
            ParseConfigOptions {
                paths: &paths,
                args0: "",
                args: &arguments,
                env_map: &mut environment,
            },
        )
        .unwrap();
        assert_eq!(
            config.command[1].encode_wide().collect::<Vec<_>>(),
            [0xd800, 65]
        );
    }

    #[test]
    fn stampable_config_rejects_reserved_markers_and_invalid_structure() {
        for marker in [MARKER_UUID, END_MARKER_UUID] {
            let config = format!(r#"{{"env":{{"VALUE":"{marker}"}},"command":["x"]}}"#);
            assert!(matches!(
                validate_stampable_config(config.as_bytes()),
                Err(Error::ReservedOverlayMarkerInConfig)
            ));
        }
        assert!(matches!(
            validate_stampable_config(br#"{"command":["#),
            Err(Error::InvalidJson | Error::SyntaxError)
        ));
        validate_stampable_config(br#"{"command":["cmd.exe"]}"#).unwrap();
    }

    #[test]
    fn certificate_table_detection_rejects_signed_launcher_inputs() {
        let mut bytes = minimal_pe(0x20b, PE_SUBSYSTEM_CONSOLE);
        assert!(!pe_has_certificate_table(&bytes).unwrap());
        let security_directory = 0x80 + 24 + 112 + 4 * 8;
        bytes[security_directory..security_directory + 4].copy_from_slice(&400u32.to_le_bytes());
        bytes[security_directory + 4..security_directory + 8].copy_from_slice(&32u32.to_le_bytes());
        assert!(pe_has_certificate_table(&bytes).unwrap());
    }

    #[test]
    fn raw_sentinel_positions_and_adjacency_remain_strict() {
        let paths = test_paths();
        assert!(matches!(
            parse_config(br#"{"cwd":@{exe_dir},"command":["x"]}"#, &paths),
            Err(Error::CwdMustBeString)
        ));
        assert!(matches!(
            parse_config(br#"{"env":{"NAME":@{exe_dir}},"command":["x"]}"#, &paths),
            Err(Error::EnvValuesMustBeStrings)
        ));
        assert!(matches!(
            parse_config(br#"{"command":[1@{args}]}"#, &paths),
            Err(Error::InvalidJson)
        ));
    }

    #[test]
    fn interpolation_removes_only_generated_wrapper_spaces() {
        let mut environment = EnvMap::default();
        let arguments = ["alpha", "beta", "gamma"].map(OsString::from);
        let config = parse_config_with_options(
            br#"{"command":["pre@{args[1]}post","@{args[2]} @{args[3]}","@@{literal}"]}"#,
            ParseConfigOptions {
                paths: &test_paths(),
                args0: "",
                args: &arguments,
                env_map: &mut environment,
            },
        )
        .unwrap();
        assert_eq!(config.command, ["prealphapost", "beta gamma", "@{literal}"]);
    }

    #[test]
    fn bare_braces_are_literal() {
        let config = parse_config(
            br#"{"command":["powershell.exe","Where-Object { $_.Name }"]}"#,
            &test_paths(),
        )
        .unwrap();
        assert_eq!(config.command[1], "Where-Object { $_.Name }");
    }

    #[test]
    fn overlay_markers_are_documented_ascii_uuid_strings() {
        assert_eq!(MARKER_UUID, "8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a");
        assert_eq!(END_MARKER_UUID, "ce3beca3-7ed2-40a4-9133-f82198be1d7b");
    }

    #[test]
    fn embedded_config_range_reads_to_eof_without_end_marker() {
        let config = br#"{"command":["cmd.exe"]}"#;
        let bytes = [b"base bytes".as_slice(), CONFIG_START_MARKER, config].concat();
        let range = embedded_config_range_from_bytes(&bytes).unwrap();
        assert_eq!(range.marker_start, b"base bytes".len());
        assert_eq!(
            range.config_start,
            b"base bytes".len() + CONFIG_START_MARKER.len()
        );
        assert_eq!(range.config_end, bytes.len());
        assert_eq!(range.suffix_start, bytes.len());
        assert!(!range.has_end_marker);
    }

    #[test]
    fn embedded_config_reads_between_start_and_end_markers() {
        let config = br#"{"command":["cmd.exe"]}"#;
        let bytes = [
            b"base bytes".as_slice(),
            CONFIG_START_MARKER,
            config,
            CONFIG_END_MARKER,
            b"icon or other bytes",
        ]
        .concat();
        assert_eq!(embedded_config_from_bytes(&bytes).unwrap(), config);
    }

    #[test]
    fn embedded_config_range_reads_between_start_and_end_markers() {
        let config = br#"{"command":["cmd.exe"]}"#;
        let bytes = [
            b"base bytes".as_slice(),
            CONFIG_START_MARKER,
            config,
            CONFIG_END_MARKER,
            b"icon or other bytes",
        ]
        .concat();
        let range = embedded_config_range_from_bytes(&bytes).unwrap();
        assert_eq!(range.marker_start, b"base bytes".len());
        assert_eq!(
            range.config_end,
            b"base bytes".len() + CONFIG_START_MARKER.len() + config.len()
        );
        assert_eq!(range.suffix_start, range.config_end);
        assert!(range.has_end_marker);
    }

    #[test]
    fn embedded_config_ignores_marker_literals_inside_pe_image() {
        let mut bytes = minimal_pe_with_section(0x400, 0x200, 0x100);
        bytes[0x220..0x220 + CONFIG_START_MARKER.len()].copy_from_slice(CONFIG_START_MARKER);
        assert!(embedded_config_range_from_bytes(&bytes).is_none());
        assert!(matches!(
            embedded_config_from_bytes(&bytes),
            Err(Error::NoEmbeddedConfig)
        ));
    }

    #[test]
    fn windows_pe_subsystem_helper_patches_files() {
        let path = env::temp_dir().join(format!(
            "exewrap-pe-test-{}-{}.exe",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, minimal_pe(0x20b, PE_SUBSYSTEM_WINDOWED)).unwrap();
        set_windows_subsystem(&path, WindowsSubsystem::WindowsConsole).unwrap();
        let patched = fs::read(&path).unwrap();
        fs::remove_file(path).unwrap();
        assert_eq!(
            windows_subsystem_from_pe_bytes(&patched).unwrap(),
            WindowsSubsystem::WindowsConsole
        );
    }

    #[test]
    fn runtime_paths_keep_resolved_known_user_folders() {
        let paths = RuntimePaths::init_with_known_user_dirs(
            r#"C:\apps\demo\demo.exe"#.into(),
            KnownUserDirs {
                documents: r#"D:\Moved Documents"#.into(),
                downloads: r#"E:\Downloads Here"#.into(),
                desktop: r#"F:\Desktop Elsewhere"#.into(),
            },
        )
        .unwrap();
        assert_eq!(paths.documents_dir, r#"D:\Moved Documents"#);
        assert_eq!(paths.downloads_dir, r#"E:\Downloads Here"#);
        assert_eq!(paths.desktop_dir, r#"F:\Desktop Elsewhere"#);
    }

    #[test]
    fn known_user_folder_lookup_returns_absolute_windows_paths_when_available() {
        if !cfg!(windows) {
            return;
        }
        let dirs = KnownUserDirs::init().unwrap();
        for value in [dirs.documents, dirs.downloads, dirs.desktop] {
            assert!(value.is_empty() || Path::new(&value).is_absolute());
        }
    }

    #[test]
    fn parse_config_expands_paths() {
        let config = parse_config(
            br#"{
              "cwd":"@{exe_dir}",
              "env":{"SCRIPT_HOME":"@{exe_dir}"},
              "command":["cmd.exe","/C","@{exe_dir}\\run.cmd"]
            }"#,
            &test_paths(),
        )
        .unwrap();
        assert!(!config.kill_children_on_exit);
        assert_eq!(config.cwd, r#"C:\bundle\bin"#);
        assert_eq!(config.command[2], r#"C:\bundle\bin\run.cmd"#);
        assert_eq!(config.env[0].name, "SCRIPT_HOME");
        assert_eq!(config.env[0].value, r#"C:\bundle\bin"#);
    }

    #[test]
    fn parse_config_accepts_kill_children_on_exit_option() {
        let config = parse_config(
            br#"{"kill_children_on_exit":true,"command":["cmd.exe"]}"#,
            &test_paths(),
        )
        .unwrap();
        assert!(config.kill_children_on_exit);
    }

    #[test]
    fn commandline_alias_is_not_accepted() {
        assert!(matches!(
            parse_config(br#"{"commandline":["cmd.exe"]}"#, &test_paths()),
            Err(Error::UnknownTopLevelKey)
        ));
    }

    #[test]
    fn env_must_be_an_ordered_object() {
        assert!(matches!(
            parse_config(
                br#"{"env":[{"name":"PATH","value":"x"}],"command":["cmd.exe"]}"#,
                &test_paths()
            ),
            Err(Error::EnvMustBeObject)
        ));
    }

    #[test]
    fn unknown_brace_groups_remain_literal_for_shell_scriptblocks() {
        let config = parse_config(
            br#"{"command":["powershell.exe","-Command","Get-Process | Where-Object { $_.Name -eq 'demo' }; & '@{exe_dir}\\run.ps1'"]}"#,
            &test_paths(),
        )
        .unwrap();
        assert_eq!(
            config.command[2],
            r#"Get-Process | Where-Object { $_.Name -eq 'demo' }; & 'C:\bundle\bin\run.ps1'"#
        );
    }

    #[test]
    fn all_boolean_config_fields_reject_non_boolean_values() {
        let paths = test_paths();
        assert!(matches!(
            parse_config(
                br#"{"kill_children_on_exit":"true","command":["cmd.exe"]}"#,
                &paths
            ),
            Err(Error::KillChildrenOnExitMustBeBoolean)
        ));
        assert!(matches!(
            parse_config(
                br#"{"error_on_missing_env":"true","command":["cmd.exe"]}"#,
                &paths
            ),
            Err(Error::ErrorOnMissingEnvMustBeBoolean)
        ));
        assert!(matches!(
            parse_config(
                br#"{"error_on_arg_out_of_bounds":"true","command":["cmd.exe"]}"#,
                &paths
            ),
            Err(Error::ErrorOnArgOutOfBoundsMustBeBoolean)
        ));
    }

    #[test]
    fn malformed_adjacency_around_raw_templates_remains_invalid_json() {
        let mut environment = EnvMap::default();
        let arguments = ["a", "b"].map(OsString::from);
        assert!(matches!(
            parse_config_with_options(
                br#"{"command":[1@{args}]}"#,
                ParseConfigOptions {
                    paths: &test_paths(),
                    args0: "",
                    args: &arguments,
                    env_map: &mut environment,
                }
            ),
            Err(Error::InvalidJson)
        ));
    }

    #[test]
    fn duplicate_key_scanner_handles_nested_objects_and_arrays() {
        reject_duplicate_keys(r#"{"a":1,"b":{"c":2,"d":3},"e":[{"f":4},{"g":5}]}"#).unwrap();
    }

    #[test]
    fn deeply_nested_json_is_rejected_without_exhausting_the_stack() {
        let nested = format!(
            "{}0{}",
            "[".repeat(MAX_JSON_DEPTH + 2),
            "]".repeat(MAX_JSON_DEPTH + 2)
        );
        assert!(matches!(
            reject_duplicate_keys(&nested),
            Err(Error::InvalidJson)
        ));
        assert!(matches!(
            JsonParser::parse(&nested),
            Err(Error::SyntaxError)
        ));
    }

    #[test]
    fn bounded_file_reads_enforce_the_limit_during_the_read() {
        let path = env::temp_dir().join(format!(
            "exewrap-bounded-read-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, b"123456789").unwrap();
        assert_eq!(read_file_limited(&path, 9).unwrap(), b"123456789");
        assert!(matches!(
            read_file_limited(&path, 8),
            Err(Error::FileTooBig)
        ));
        fs::remove_file(path).unwrap();
    }

    #[test]
    fn windows_loader_errors_keep_the_invalid_exe_tag() {
        for code in [191, 193, 216] {
            assert_eq!(
                Error::Io(io::Error::from_raw_os_error(code)).tag(),
                "InvalidExe"
            );
        }
    }
}
