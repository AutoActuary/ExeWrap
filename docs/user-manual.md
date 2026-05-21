# overlay-launcher User Manual

`overlay-launcher` creates small configured Windows launchers. You build one
generic launcher, write a templated JSON config, and stamp the config onto a copy
of the launcher executable.

The stamped executable then:

1. Reads the config appended to itself.
2. Evaluates templates such as `@{exe_dir}` and `@{args}`.
3. Applies environment edits.
4. Sets the child working directory.
5. Starts the configured argv array.

## Install Prerequisites

Install Zig 0.15.2 or a compatible Zig version available on `PATH`.

Check that Zig is available:

```powershell
zig version
```

Build the launcher tools from the repository root:

```powershell
zig build
```

The build writes:

```text
zig-out\bin\overlay-launcher.exe
zig-out\bin\overlay-launcher-stamp.exe
```

## Stamp A Launcher

Create a config file, then stamp it onto the base executable:

```powershell
zig-out\bin\overlay-launcher-stamp.exe `
  zig-out\bin\overlay-launcher.exe `
  my-tool.config.json `
  bundle\bin\my-tool.exe
```

Arguments are:

```text
overlay-launcher-stamp <base-exe> <config.json> <output-exe>
```

Use the base `overlay-launcher.exe` as input when practical. If you stamp an
already stamped executable, the launcher uses the last embedded start marker and
config, but the output keeps the earlier overlay bytes and grows unnecessarily.

Run the stamped output:

```powershell
bundle\bin\my-tool.exe --some-user-arg value
```

## Config Format

Config files are UTF-8 templated JSON. A leading UTF-8 BOM is accepted. UTF-16,
Windows code pages, and other non-UTF-8 byte sequences are rejected.

Minimal config:

```json
{
  "terminal": true,
  "cwd": "@{exe_dir}",
  "command": ["cmd.exe", "/C", "echo hello && pause"]
}
```

### Top-Level Fields

| Field | Required | Type | Behavior |
| --- | --- | --- | --- |
| `command` | Yes | array of strings/splices | Child argv. Each entry is one argument. |
| `cwd` | No | string | Child working directory. Defaults to `@{exe_dir}`. |
| `env` | No | ordered object | Environment edits applied before starting the child. Later values can read earlier edits. |
| `terminal` | No | boolean | When omitted or `true`, allows a console child to show/use a terminal. When `false`, starts the child with no window and ignored stdio. |
| `kill_children_on_exit` | No | boolean | Kills the child process tree if the launcher exits or is killed. |
| `error_on_missing_env` | No | boolean | Makes missing `@{env:"NAME"}` lookups fail. Otherwise missing env values resolve to an empty string. |
| `error_on_arg_out_of_bounds` | No | boolean | Makes missing `@{args:N}` lookups fail. Otherwise missing args resolve to an empty string. |

If `terminal` is omitted, it defaults to `true`.

The launcher rejects duplicate JSON keys before parsing the config. Object keys
are literal names and cannot contain templates.

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
  "terminal": true,
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
  "terminal": true,
  "command": [
    "powershell.exe",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    "@{exe_parent:join("scripts"):join("start.ps1")}"
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
    @{args:take(1)}
  ]
}
```

The source file above is templated JSON. It becomes strict JSON after the
launcher replaces template expressions with internal sentinel strings. That is
why raw array entries such as `@{args}` and normal quotes in expressions such as
`join("python")` are allowed.

### Base Values

| Base | Meaning |
| --- | --- |
| `exe_path` | Full path to the stamped executable. |
| `exe_dir` | Directory containing the stamped executable. |
| `exe_parent` | Parent of `exe_dir`. |
| `exe_filename` | Stamped executable file name. |
| `exe_filename_noext` | File name without extension. |
| `exe_ext` | Extension without the dot. |
| `exe_ext_dot` | Extension with the dot. |
| `exe_drive` | Windows drive or UNC share prefix for the executable path. |
| `exe_root` | Root portion of the executable path. |
| `args0` | Original launcher invocation argument when available. |
| `cwd` | Directory from which the launcher was started. |
| `temp_dir` | Operating system temp directory. |
| `home_dir` | User profile directory. |
| `appdata_dir` | Roaming AppData directory. |
| `localappdata_dir` | Local AppData directory. |
| `programdata_dir` | ProgramData directory. |
| `program_files_dir` | Program Files directory. |
| `program_files_x86_dir` | Program Files (x86) directory. |
| `documents_dir` | `Documents` under the user profile directory, when a profile is available. |
| `downloads_dir` | `Downloads` under the user profile directory, when a profile is available. |
| `desktop_dir` | `Desktop` under the user profile directory, when a profile is available. |
| `os` | Zig OS tag, for example `windows`. |
| `arch` | Zig CPU architecture tag, for example `x86_64`. |
| `dir_sep` | Directory separator. |
| `path_sep` | Environment path-list separator. |

### Lookups

Environment lookup:

```text
@{env:"PATH"}
@{env:"LOCALAPPDATA"}
```

Missing environment variables resolve to an empty string unless
`error_on_missing_env` is `true`.

User argument lookup:

```text
@{args}
@{args:1}
@{args:2:filename}
```

`args` are the arguments passed to the stamped launcher, excluding the launcher
itself. Indexes are 1-based. `@{args:0}` is invalid; use `@{args0}` for the
launcher invocation string.

Missing single-argument lookups resolve to an empty string unless
`error_on_arg_out_of_bounds` is `true`. List slices clamp to the available
arguments.

### Path Transforms

| Transform | Example |
| --- | --- |
| `parent` | `@{exe_dir:parent}` |
| `filename` | `@{exe_path:filename}` |
| `filename_noext` | `@{exe_path:filename_noext}` |
| `ext` / `ext_dot` | `@{exe_path:ext_dot}` |
| `drive` / `root` | `@{exe_path:drive}` |
| `join("part")` | `@{exe_parent:join("python"):join("python.exe")}` |
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
| `trim` | `@{env:"NAME":trim}` |
| `prefix("text")` | `@{exe_filename_noext:prefix("tool-")}` |
| `suffix("text")` | `@{exe_filename_noext:suffix(".log")}` |
| `json` | `@{env:"TEXT":json}` |

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
    "PATH": "@{env:"PATH":prepend_env(exe_parent:join("python")):unique_env}"
  },
  "command": ["cmd.exe", "/C", "where python && pause"]
}
```

### Argument List Transforms

| Transform | Meaning |
| --- | --- |
| `:N` | Select the Nth item from the current list. |
| `from(N)` | Keep from item N onward. |
| `take(N)` | Keep at most the first N items. |
| `drop(N)` | Drop the first N items. |
| `last` | Select the last item as a string. |
| `last(N)` | Keep the last N items. |
| `drop_last(N)` | Drop the last N items. |

Examples:

```text
@{args}                    all user args as a list
@{args:1}                  first user arg as a string
@{args:from(2)}            all except the first user arg
@{args:take(3)}            first three user args
@{args:last}               last user arg as a string
@{args:last(3):1}          third-last user arg
@{args:drop_last(1)}       all except the last user arg
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
    "APP_HOME": "@{exe_parent:join("app")}",
    "PYTHONPATH": "@{exe_parent:join("app")}"
  },
  "command": ["cmd.exe", "/C", "echo %APP_HOME%"]
}
```

```json
{
  "env": {
    "PATH": "@{env:"PATH":prepend_env(exe_parent:join("python"))}",
    "PATH_AFTER": "@{env:"PATH"}"
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
  "terminal": true,
  "cwd": "@{exe_parent:join("app")}",
  "env": {
    "PYTHONHOME": "@{exe_parent:join("python")}",
    "PYTHONPATH": "@{exe_parent:join("app")}"
  },
  "command": [
    "@{exe_parent:join("python"):join("python.exe")}",
    "-m",
    "my_module",
    "--input",
    "@{exe_parent:join("data"):join("input.json")}",
    @{args}
  ]
}
```

### Run A Batch File Next To The Launcher

```json
{
  "terminal": true,
  "cwd": "@{exe_dir}",
  "command": ["cmd.exe", "/C", "@{exe_dir}\\run.cmd"]
}
```

### Run A Background Worker

```json
{
  "terminal": false,
  "kill_children_on_exit": true,
  "cwd": "@{exe_parent:join("app")}",
  "command": [
    "@{exe_parent:join("python"):join("python.exe")}",
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
  "terminal": true,
  "env": {
    "LOG_FILE": "@{temp_dir:join(exe_filename_noext:suffix(".log"))}"
  },
  "command": ["cmd.exe", "/C", "echo log=%LOG_FILE% && pause"]
}
```

## Troubleshooting

### The launcher reports `NoEmbeddedConfig`

You are probably running the base `overlay-launcher.exe` instead of a stamped
output file. Re-run `overlay-launcher-stamp.exe` and launch the output path.

### Stamping fails with `ConfigMustBeUtf8`

Save the config as UTF-8. A UTF-8 BOM is fine, but UTF-16 and legacy ANSI code
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
  "cwd": "@{exe_parent:join("app")}",
  "command": ["@{exe_parent:join("python"):join("python.exe")}", "-m", "my_module"]
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

- `@{args:1}` is `alpha`.
- `@{args:2}` is `beta`.
- `@{args0}` is the launcher invocation string.

Set `error_on_arg_out_of_bounds` to `true` when missing arguments should fail
instead of resolving to an empty string.

### An environment variable is missing

Missing `@{env:"NAME"}` values resolve to an empty string by default. Set
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

- [README](../README.md): concise build, stamp, and config overview.
- [Templated JSON spec](template-spec.html): full language and processing-pass
  details.
- [Implementation notes](implementation-notes.md): design rationale and
  implementation tradeoffs.
