# ExeWrap

`ExeWrap` is a portable executable wrapper.

It turns a folder of runtime files, dependencies, and entry scripts into a
normal Windows `.exe` launcher with its own icon, working directory, environment
edits, and argument forwarding. Use it for portable app bundles and
pinned/renamed tools where shortcuts, `.cmd` files, PowerShell scripts, or
symlinks are too limited.

The stamped executable:

1. Reads the config appended to itself.
2. Evaluates templates such as `@{exe_dir}` and `@{args}`.
3. Applies environment edits.
4. Sets the child working directory.
5. Starts the configured argv array.

## Get The Tools

Published GitHub releases provide builds for:

- `windows-x64`
- `windows-x86`
- `windows-arm64`

Each release build contains:

```text
ExeWrap-console.exe
ExeWrap-windowed.exe
ExeWrap-stamper.exe
```

Use `ExeWrap-console.exe` for PATH commands, CI tools, and scripts where the
parent shell should wait and receive the child exit code. Use
`ExeWrap-windowed.exe` for Explorer shortcuts, file associations, protocol
handlers, and background GUI launches that should not present a console window.
Use `ExeWrap-stamper.exe` to make your app-specific executable.

## Stamp A Launcher

Create a config file, then stamp it onto the base executable:

```powershell
ExeWrap-stamper.exe `
  --launcher ExeWrap-console.exe `
  --config my-tool.config.json `
  --icon logo.ico `
  --subsystem console `
  bundle\bin\my-tool.exe
```

Arguments are:

```text
ExeWrap-stamper.exe --launcher <base-launcher.exe> --config <config.json> [--icon <logo.ico>] [--subsystem inherit|console|windowed] <output.exe>
```

`--icon` is optional. When present, the stamp helper writes the icon into the
output executable before appending the config overlay.

`--subsystem` is optional and defaults to `inherit`, which preserves the
subsystem of the `--launcher` input. Use `console` for command-line shims and
`windowed` for GUI/background launchers.

You can stamp either a base launcher or an already stamped executable. When
restamping, the stamper replaces the existing embedded config instead of
appending another copy.

Run the stamped output:

```powershell
bundle\bin\my-tool.exe --some-user-arg value
```

The stamped exe can be copied or renamed. Runtime paths are resolved from the
final exe location, so `@{exe_dir}` follows the stamped file.

## Minimal Config

Config files are JSON with a small overlay template syntax. Use `@{name}` to
insert launcher values, and chain transforms such as
`@{exe_dir:parent:join("python"):join("python.exe")}` for paths, strings,
environment values, and arguments. See "Template Expressions" for base values,
lookups, and transforms.

Config files must be utf-8. A leading utf-8 BOM is accepted. UTF-16, Windows
code pages, and other non-utf-8 byte sequences are rejected.

```json
{
  "command": ["cmd.exe", "/C", "echo hello && pause"]
}
```

### Top-Level Fields

| Field | Required | Type | Behavior |
| --- | --- | --- | --- |
| `command` | Yes | array of strings/splices | Child argv. Each entry is one argument. |
| `cwd` | No | string | Child working directory. Defaults to `@{cwd}`, the directory where the launcher was started. |
| `env` | No | ordered object | Environment edits applied before starting the child. Later values can read earlier edits. |
| `kill_children_on_exit` | No | boolean | Kills the child process tree if the launcher exits or is killed. |
| `error_on_missing_env` | No | boolean | Makes missing `@{env["NAME"]}` lookups fail. Otherwise missing env values resolve to an empty string. |
| `error_on_arg_out_of_bounds` | No | boolean | Makes missing `@{args[N]}` lookups fail. Otherwise missing args resolve to an empty string. |

On Windows, a bare `command[0]` is resolved from the configured `cwd` first and
then from the launcher's parent-process `PATH`. Supported `PATHEXT` entries are
`.BAT`, `.CMD`, `.COM`, and `.EXE`, in the parent's configured order. This
lookup happens before the config's `env` edits are passed to the child. Relative
command paths containing a directory component are resolved from `cwd` and do
not search `PATH`.

The launcher rejects unknown top-level keys, duplicate JSON keys, and templated
object keys. ExeWrap config is order-aware templated JSON-like input, not
arbitrary JSON where object order is irrelevant. `command` is required and must
be the final top-level key, because all setup fields are resolved before the
child argv is built. `env` object insertion order is also part of the contract:
later environment values can read earlier edits.

If a portable app should run relative to the stamped executable instead of the
caller's directory, set `cwd` explicitly:

```json
{
  "cwd": "@{exe_dir}",
  "command": ["@{exe_dir}\\app.exe"]
}
```

## Command Arrays

The launcher starts the child process from an argv array. Each item is one
argument:

```json
{
  "command": [
    "python.exe",
    "-m",
    "my_module",
    "--input",
    "file with spaces.json"
  ]
}
```

Do not combine everything into one string unless the program you are launching
really expects one string argument.

Use `cmd.exe /C` only when you need shell features:

```json
{
  "command": [
    "cmd.exe",
    "/C",
    "echo Launcher=@{exe_filename} && dir && pause"
  ]
}
```

Use PowerShell explicitly when you need PowerShell syntax:

```json
{
  "command": [
    "powershell.exe",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "@{exe_dir:parent:join("scripts"):join("start.ps1")}"
  ]
}
```

Bare braces are ordinary text. A PowerShell script block such as
`Where-Object { $_.Name -eq "demo" }` does not trigger the template scanner.

## Template Expressions

Templates use:

```text
@{expression}
```

Escape a literal `@{` as:

```text
@@{
```

Template expressions can appear inside `cwd`, `env` values, and `command`
entries. A list expression such as `@{args}` can appear as a raw array item:

```json
{
  "command": [
    "cmd.exe",
    "/C",
    "echo first arg:",
    @{args[1:1]}
  ]
}
```

The source file above is templated JSON. It becomes strict JSON after the
launcher replaces template expressions with internal numeric sentinels. That is
why raw array entries such as `@{args}` and normal quotes in expressions such as
`join("python")` are allowed.

### Base Values

| Base | Meaning |
| --- | --- |
| `exe_path` | Full path to the stamped executable. |
| `exe_dir` | Directory containing the stamped executable. |
| `exe_filename` | Stamped executable file name. |
| `exe_filename_noext` | File name without extension. |
| `exe_ext` | Extension without the dot. |
| `exe_ext_dot` | Extension with the dot. |
| `exe_drive` | Windows drive or UNC share prefix for the executable path. |
| `exe_root` | Root portion of the executable path. |
| `args0` | Original launcher invocation argument when available. |
| `args_as_json` | User arguments as one minified JSON array string. |
| `cwd` | Directory from which the launcher was started. |
| `temp_dir` | Operating system temp directory. |
| `home_dir` | User profile directory. |
| `appdata_dir` | Roaming AppData directory. |
| `localappdata_dir` | Local AppData directory. |
| `programdata_dir` | ProgramData directory. |
| `program_files_dir` | Program Files directory. |
| `program_files_x86_dir` | Program Files (x86) directory. |
| `documents_dir` | Current user's Documents known folder, when available. |
| `downloads_dir` | Current user's Downloads known folder, when available. |
| `desktop_dir` | Current user's Desktop known folder, when available. |
| `os` | Operating system tag, for example `windows`. |
| `arch` | CPU architecture tag, for example `x86_64`. |
| `dir_sep` | Directory separator. |
| `path_sep` | Environment path-list separator. |

### Lookups

Environment lookup:

```text
@{env["PATH"]}
@{env["LOCALAPPDATA"]}
```

Missing environment variables resolve to an empty string unless
`error_on_missing_env` is `true`.

User argument lookup:

```text
@{args}
@{args[1]}
@{args[2]:filename}
```

`args` are the arguments passed to the stamped launcher, excluding the launcher
itself. Indexes are 1-based. `@{args[0]}` is invalid; use `@{args0}` for the
launcher invocation string.

Missing single-argument lookups resolve to an empty string unless
`error_on_arg_out_of_bounds` is `true`. List slices clamp to the available
arguments.

Use `@{args_as_json}` when a child process needs to receive the whole argument
list through one string, for example an environment variable:

```json
{
  "env": {
    "__ARGS_AS_JSON__": "@{args_as_json}"
  },
  "command": [
    "powershell.exe",
    "-NoProfile",
    "-Command",
    "$ArgsList=$env:__ARGS_AS_JSON__ | ConvertFrom-Json; ..."
  ]
}
```

`args_as_json` is valid JSON text, not a list splice. Inside argument values it
emits fixed `\uXXXX` escapes for JSON-required characters, apostrophes,
backslashes, PowerShell `$` and backtick characters, control characters, and
non-ASCII text. Ordinary spaces and printable metacharacters such as `%`, `!`,
`^`, `&`, `|`, `<`, `>`, `(`, and `)` remain raw.

That makes `$ArgsJson='@{args_as_json}'` safe from argument-data apostrophes in
direct PowerShell source. It still cannot be pasted raw into a PowerShell
double-quoted string because a JSON string array necessarily contains literal
double quote delimiters. Prefer the `env` handoff above for nested shells.

### Path Transforms

| Transform | Example |
| --- | --- |
| `parent` | `@{exe_dir:parent}` |
| `filename` | `@{exe_path:filename}` |
| `filename_noext` | `@{exe_path:filename_noext}` |
| `ext` / `ext_dot` | `@{exe_path:ext_dot}` |
| `drive` / `root` | `@{exe_path:drive}` |
| `join("part")` | `@{exe_dir:parent:join("python"):join("python.exe")}` |
| `normalize` | `@{exe_dir:join("..\\app"):normalize}` |
| `slash` / `backslash` | `@{exe_path:slash}` |

Inside template expressions, string arguments use normal quotes:
`join("python")`. In ordinary JSON strings outside template expressions,
backslashes still need to be doubled as `\\`.

### String Transforms

| Transform | Example |
| --- | --- |
| `lower` | `@{exe_filename_noext:lower}` |
| `upper` | `@{exe_filename_noext:upper}` |
| `trim` | `@{env["NAME"]:trim}` |
| `prefix("text")` | `@{exe_filename_noext:prefix("tool-")}` |
| `suffix("text")` | `@{exe_filename_noext:suffix(".log")}` |
| `json` | `@{env["TEXT"]:json}` |

`lower` and `upper` are ASCII transforms.

### Environment Path-List Transforms

These transforms operate on a path-list string using the platform path separator
from `@{path_sep}`.

| Transform | Meaning |
| --- | --- |
| `prepend_env(value)` | Prepends one entry. |
| `append_env(value)` | Appends one entry. |
| `remove_env(value)` | Removes matching entries. |
| `unique_env` | Removes duplicate entries while preserving first occurrence. |

Example:

```json
{
  "env": {
    "PATH": "@{env["PATH"]:prepend_env(exe_dir:parent:join("python")):unique_env}"
  },
  "command": ["cmd.exe", "/C", "where python && pause"]
}
```

### Argument Indexing And Slicing

Argument indexing uses a Julia-style bracket subset on list-valued expressions.
Indexes are 1-based. `end` means the last item, and `end-N` or `end+N` can be
used for offsets. Slice ranges are inclusive.

| Syntax | Meaning |
| --- | --- |
| `args[N]` | Select item N as a string. |
| `args[end]` | Select the last item as a string. |
| `args[start:stop]` | Keep items from start through stop. |
| `args[start:step:stop]` | Keep items from start through stop using step. |

Examples:

```text
@{args}                    all user args as a list
@{args[1]}                 first user arg as a string
@{args[end]}               last user arg as a string
@{args[end-1]}             second-last user arg as a string
@{args[1:3]}               first three user args
@{args[3:end]}             from the third user arg onward
@{args[1:end-1]}           all except the last user arg
@{args[1:2:end]}           every second user arg from the first
@{args[end:-1:1]}          all user args in reverse order
```

List-valued expressions can only be inserted as complete command-array entries.
This is valid:

```json
{
  "command": ["python.exe", "-m", "my_module", @{args}]
}
```

This is invalid because one string cannot expand into several argv entries:

```json
{
  "command": ["prefix @{args} suffix"]
}
```

## Environment Edits

The launcher starts with the inherited process environment, then applies config
`env` entries in object source order. Use template bases such as `@{exe_dir}`
and `@{exe_path}` when launcher metadata needs to be copied into environment
variables.

```json
{
  "env": {
    "APP_HOME": "@{exe_dir:parent:join("app")}",
    "PYTHONPATH": "@{exe_dir:parent:join("app")}"
  },
  "command": ["cmd.exe", "/C", "echo %APP_HOME%"]
}
```

```json
{
  "env": {
    "PATH": "@{env["PATH"]:prepend_env(exe_dir:parent:join("python"))}",
    "PATH_AFTER": "@{env["PATH"]}"
  },
  "command": ["cmd.exe", "/C", "echo %PATH_AFTER%"]
}
```

Object order is part of the `env` contract. The implementation preserves parser
insertion order and rejects duplicate keys.

## Recipes

### Run A Python Module From A Portable Bundle

Layout:

```text
bundle\
  bin\
    my-tool.exe
  python\
    python.exe
  app\
    my_module\
      __main__.py
  data\
    input.json
```

Config for `bundle\bin\my-tool.exe`:

```json
{
  "cwd": "@{exe_dir:parent:join("app")}",
  "env": {
    "PYTHONHOME": "@{exe_dir:parent:join("python")}",
    "PYTHONPATH": "@{exe_dir:parent:join("app")}"
  },
  "command": [
    "@{exe_dir:parent:join("python"):join("python.exe")}",
    "-m",
    "my_module",
    "--input",
    "@{exe_dir:parent:join("data"):join("input.json")}",
    @{args}
  ]
}
```

### Run A Batch File Next To The Launcher

```json
{
  "cwd": "@{exe_dir}",
  "command": ["cmd.exe", "/C", "@{exe_dir}\\run.cmd"]
}
```

### Run A Background Worker

Stamp background workers with `ExeWrap-windowed.exe` or
`ExeWrap-stamper.exe --subsystem windowed` when they should not present a
console window.

```json
{
  "kill_children_on_exit": true,
  "cwd": "@{exe_dir:parent:join("app")}",
  "command": [
    "@{exe_dir:parent:join("python"):join("python.exe")}",
    "-m",
    "my_worker"
  ]
}
```

`kill_children_on_exit` uses a Windows Job Object. If the launcher process is
killed, Windows closes the job handle and terminates the child process tree.

### Create A Name-Based Log Path

```json
{
  "env": {
    "LOG_FILE": "@{temp_dir:join(exe_filename_noext:suffix(".log"))}"
  },
  "command": ["cmd.exe", "/C", "echo log=%LOG_FILE% && pause"]
}
```

## Stamp Without The Helper

`ExeWrap-stamper.exe` is not required by the file format. Other tools can
produce the same output by doing the same byte-level steps:

1. Copy `ExeWrap-console.exe`, `ExeWrap-windowed.exe`, or another stamped
   launcher to the desired output path.
2. Optionally update the copied executable's Windows resources, such as its icon.
3. Optionally patch the Windows PE optional-header subsystem field to console
   value `3` or windowed value `2`.
4. Append the ASCII start marker
   `8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a`.
5. Append the utf-8 templated JSON config bytes.
6. If unrelated bytes must be appended after the config, append the ASCII end
   marker `ce3beca3-7ed2-40a4-9133-f82198be1d7b` after the config first.

When the config is the final thing in the file, the end marker is not needed.

For PE launchers, the runtime searches the PE overlay for the last start marker
so marker-like bytes inside the executable image are ignored. Config bytes run
from after that marker to the following end marker, or to the end of the file
when no end marker is present.

## Build From Source

Most users should start from the release binaries. Build from source when you
are changing the launcher or need a local debug build.

Install the Rust toolchain listed in `rust-toolchain.toml`. Rustup installs the
three supported Windows targets automatically.

```powershell
rustc --version
cargo build --release
```

The build writes:

```text
target\release\ExeWrap-console.exe
target\release\ExeWrap-windowed.exe
target\release\ExeWrap-stamper.exe
```

The release profile is size-oriented: `opt-level = "z"`, aborting panics,
whole-program LTO, one codegen unit, and stripped symbols. It emits both
console-subsystem and windowed-subsystem launcher bases. Windows targets link
the MSVC runtime statically so the executables do not need a separately
installed Visual C++ runtime.

Use a debug build when diagnosing launcher behavior:

```powershell
cargo build
```

## Troubleshooting

### The launcher reports that no embedded config was found

You are probably running `ExeWrap-console.exe` or `ExeWrap-windowed.exe` instead
of a stamped output file. Re-run `ExeWrap-stamper.exe` and launch the output
path.

### The launcher reports that `terminal` was removed

Choose the launcher subsystem at stamp time instead. Use `ExeWrap-console.exe`
or `--subsystem console` for CLI shims, and `ExeWrap-windowed.exe` or
`--subsystem windowed` for GUI/background launchers.

### Stamping fails with `ConfigMustBeUtf8`

Save the config as utf-8. A utf-8 BOM is fine, but UTF-16 and legacy ANSI code
pages are not.

### JSON parsing fails near a template

Remember that the file is templated JSON:

- Use normal quotes inside template expressions: `join("python")`.
- Use doubled JSON backslashes outside template expressions: `"@{exe_dir}\\run.cmd"`.
- Put raw list splices such as `@{args}` only in array positions.
- Escape literal launcher-template starts as `@@{`.

### The child command cannot find a file

Check the child `cwd` and the executable-relative paths. A reliable portable
default is:

```json
{
  "cwd": "@{exe_dir:parent:join("app")}",
  "command": ["@{exe_dir:parent:join("python"):join("python.exe")}", "-m", "my_module"]
}
```

### A command works in PowerShell but not from the launcher

The launcher does not use PowerShell parsing by default. Split the command into
argv entries, or explicitly launch `powershell.exe` and pass the script as
PowerShell arguments.

### A forwarded argument is missing

Argument lookup is 1-based and excludes the launcher executable itself:

```text
my-tool.exe alpha beta
```

In that invocation:

- `@{args[1]}` is `alpha`.
- `@{args[2]}` is `beta`.
- `@{args0}` is the launcher invocation string.

Set `error_on_arg_out_of_bounds` to `true` when missing arguments should fail
instead of resolving to an empty string.

### An environment variable is missing

Missing `@{env["NAME"]}` values resolve to an empty string by default. Set
`error_on_missing_env` to `true` when that should be a launch error.

### Child processes survive after closing the launcher

Use:

```json
{
  "kill_children_on_exit": true
}
```

Leave it unset when the child process is intentionally long-lived.

## Related Documents

- [Implementation notes](docs/implementation-notes.md): design rationale and
  implementation tradeoffs.

## License

ExeWrap is licensed under the MIT License. See [LICENSE](LICENSE).

## Prior Art

Similar projects and use cases:

- PortableApps.com-style launchers: for example, `FirefoxPortable.exe` sits at
  the portable app root and starts Firefox from the app's internal `App`
  directory while keeping profile/data paths portable.
- Python packaging launchers: `pip`/`distlib` create small native Windows
  `.exe` wrappers for console and GUI entry points; the wrapper carries launcher
  data and a small zip payload after the executable stub.
- Windows App Execution Aliases: Store apps can expose command names such as
  `python.exe` or Sysinternals tools through one directory that is already on
  `PATH`, instead of editing `PATH` for every tool.
- Chocolatey shims: Chocolatey places small `.exe` shims in
  `C:\ProgramData\chocolatey\bin`, which is on `PATH`, and those shims redirect
  to the real package executable in its installed location.
- Self-extracting archives and one-file packagers: a normal executable carries
  extra bytes after the mapped image, then finds and interprets that overlay at
  runtime.
