# overlay-launcher

`overlay-launcher` turns one generic executable into many tiny app launchers by
stamping a templated JSON config onto the end of the `.exe`.

Think of it as a symlink with arguments, environment setup, portable paths, and
Windows `.exe` behavior. That matters because `.exe` files are first-class on
Windows: users can double-click them, pin them, rename them, assign icons, and
hand them to tools that do not treat `.cmd`, PowerShell scripts, or shortcuts as
real applications.

The stamped launcher reads its own overlay, evaluates template expressions such
as `@{exe_dir}`, and starts the configured child process. It is meant for
portable bundles where a launcher in `bin\` needs to run a Python module, script,
or tool stored next to it without hard-coded install paths.

## Quick Start

Build the launcher and stamp helper:

```powershell
zig build
```

Create a launcher from the included example config:

```powershell
zig-out\bin\overlay-launcher-stamp.exe `
  zig-out\bin\overlay-launcher.exe `
  examples\config.json `
  examples\demo-launcher.exe
```

Run the stamped launcher:

```powershell
examples\demo-launcher.exe
```

The output executable contains both the normal launcher and the appended config.
You can copy or rename the stamped `.exe`; templates such as `@{exe_dir}` are
resolved from the final executable path at launch time.

That means one base launcher can produce `my-tool.exe`, `admin-tool.exe`, or
`report-viewer.exe` simply by stamping different configs.

## What Gets Stamped

The overlay format is:

```text
overlay-launcher.exe + ASCII start marker + UTF-8 templated JSON config
```

Start marker:

```text
8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a
```

Optional end marker:

```text
ce3beca3-7ed2-40a4-9133-f82198be1d7b
```

At runtime the launcher searches from the end of its own file for the last start
marker. Config bytes run from after that marker to the following end marker, or
to the end of the file when no end marker is present. The stamp helper validates
that the config bytes are UTF-8 before writing the output file.

## Build Outputs

`zig build` installs two tools under `zig-out\bin`:

- `overlay-launcher.exe`: the self-reading launcher.
- `overlay-launcher-stamp.exe`: a helper that appends config to a launcher.

The default build is size-oriented: `ReleaseSmall`, stripped, single-threaded,
and built with the Windows GUI subsystem so the launcher itself does not flash a
console window.

Use a debug build when diagnosing launcher behavior:

```powershell
zig build -Doptimize=Debug
```

## Config File

Config files are UTF-8 templated JSON. A leading UTF-8 BOM is accepted, but
non-UTF-8 bytes are rejected before JSON parsing.

Minimal config:

```json
{
  "terminal": true,
  "cwd": "@{exe_dir}",
  "env": {
    "SCRIPT_HOME": "@{exe_dir}"
  },
  "command": ["cmd.exe", "/C", "echo dir=%SCRIPT_HOME% && pause"]
}
```

Top-level fields:

| Field | Meaning |
| --- | --- |
| `command` | Required argv array to run. Each array item is one child-process argument. |
| `cwd` | Child working directory. Defaults to the stamped executable directory. |
| `env` | Ordered object of environment edits. Later values can read earlier edits. |
| `terminal` | When omitted or `true`, the child can inherit/use a visible console. When `false`, the child is started with no window and ignored stdio. |
| `kill_children_on_exit` | When `true`, Windows kills the child process tree if the launcher dies. |
| `error_on_missing_env` | When `true`, `@{env:"NAME"}` fails if `NAME` is not set. When omitted or `false`, missing env values resolve to an empty string. |
| `error_on_arg_out_of_bounds` | When `true`, `@{args:N}` fails if that user argument is missing. When omitted or `false`, missing args resolve to an empty string. |

If `terminal` is omitted, it defaults to `true`.

## Command Arguments

Write `command` as an argv array. Do not quote and join a whole shell command
unless you intentionally want to run through a shell.

Good:

```json
{
  "command": ["python.exe", "-m", "my_module", "--flag", "value with spaces"]
}
```

Avoid:

```json
{
  "command": ["python.exe -m my_module --flag \"value with spaces\""]
}
```

Use `cmd.exe /C` or `powershell.exe` only when you need shell behavior such as
redirection, `&&`, `%VARIABLE%` expansion, PowerShell pipelines, or built-in
commands.

## Template Expressions

Template expressions use `@{...}` and are evaluated in `cwd`, `env` values, and
`command` entries:

```json
{
  "cwd": "@{exe_dir:parent:join("app")}",
  "command": [
    "@{exe_dir:parent:join("python"):join("python.exe")}",
    "-m",
    "my_module",
    @{args}
  ]
}
```

The source file is templated JSON, not strict JSON. Raw array splices such as
`@{args}` and normal quotes inside template expressions are made valid by the
launcher's preprocessing pass before the JSON parser runs.

Common base values:

| Expression | Meaning |
| --- | --- |
| `@{exe_path}` | Full path to the stamped executable. |
| `@{exe_dir}` | Directory containing the stamped executable. |
| `@{exe_parent}` | Parent directory of `exe_dir`. |
| `@{exe_filename}` | Stamped executable file name. |
| `@{exe_filename_noext}` | Stamped executable file name without extension. |
| `@{args0}` | Original launcher invocation argument, if available. |
| `@{cwd}` | Directory from which the launcher was started. |
| `@{args}` | All user arguments, spliced into a command array. |
| `@{args:1}` | First user argument. Argument indexes are 1-based. |
| `@{env:"PATH"}` | Current environment value, including earlier config edits. |
| `@{temp_dir}` | Operating system temp directory. |
| `@{home_dir}` | User profile directory. |
| `@{appdata_dir}` / `@{localappdata_dir}` | Roaming and local AppData directories. |
| `@{program_files_dir}` / `@{program_files_x86_dir}` | Program Files directories. |
| `@{documents_dir}` / `@{downloads_dir}` / `@{desktop_dir}` | Common user directories derived from the profile directory. |
| `@{os}` / `@{arch}` | Zig target OS and CPU architecture tags. |
| `@{dir_sep}` / `@{path_sep}` | Directory separator and environment path-list separator. |

Common transforms:

| Transform | Example |
| --- | --- |
| Path parts | `@{exe_path:filename}`, `@{exe_path:ext}`, `@{exe_path:drive}` |
| Path joining | `@{exe_dir:parent:join("app"):normalize}` |
| Path separators | `@{exe_path:slash}`, `@{exe_path:backslash}` |
| String edits | `@{exe_filename_noext:upper}`, `@{env:"NAME":trim:lower}` |
| JSON escaping | `@{env:"TEXT":json}` |
| Env path lists | `@{env:"PATH":prepend_env(exe_parent:join("python")):unique_env}` |
| User args | `@{args:from(2)}`, `@{args:take(3)}`, `@{args:last}`, `@{args:drop_last(1)}` |

Write `@@{` when you need a literal `@{`. Bare braces are ordinary text, so
PowerShell script blocks such as `Where-Object { $_.Name -eq "python" }` do not
need escaping.

## Environment Edits

Use template bases such as `@{exe_dir}` and `@{exe_path}` when launcher metadata
needs to be copied into environment variables.

```json
{
  "env": {
    "PATH": "@{env:"PATH":prepend_env(exe_parent:join("python"))}",
    "PATH_AFTER": "@{env:"PATH"}"
  },
  "command": ["cmd.exe", "/C", "echo %PATH_AFTER%"]
}
```

## Python Module Example

A common portable layout:

```text
bundle\
  bin\
    my-tool.exe
  python\
    python.exe
  app\
    my_module\
      __main__.py
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
    @{args}
  ]
}
```

The repository also includes ready-to-copy examples:

- [examples/config.json](examples/config.json)
- [examples/python-module.config.json](examples/python-module.config.json)

## Troubleshooting

If the launcher reports `NoEmbeddedConfig`, run the stamp helper and make sure
you are launching the stamped output file, not the base `overlay-launcher.exe`.

If stamping fails with `ConfigMustBeUtf8`, save the config as UTF-8. A UTF-8 BOM
is tolerated; UTF-16 and legacy code pages are not.

If JSON parsing fails near a template, remember that `@{...}` template syntax is
handled before JSON parsing. Use normal quotes inside template expressions, such
as `join("python")`, and double ordinary JSON backslashes outside expressions.

If a command works in PowerShell but not from the launcher, split it into argv
array entries or explicitly run `powershell.exe`/`cmd.exe`. The launcher does not
run commands through a shell by default.

If `@{args}` fails inside a string, move it to its own command-array item. List
expressions can splice multiple array entries only when they are the entire array
item.

If an environment value appears stale, check the order of keys in `env`. The
launcher treats object order as significant for environment edits.

If a background tool leaves child processes behind, set `kill_children_on_exit`
to `true`. Leave it unset when the child should survive after the launcher exits.

## More Documentation

- [User manual](docs/user-manual.md): detailed usage recipes and config reference.
- [Templated JSON spec](docs/template-spec.html): full expression language and
  scanner/evaluator rules.
- [Implementation notes](docs/implementation-notes.md): why the launcher uses PE
  overlays, sentinel preprocessing, strict validation, and Windows process
  choices.

## Prior Art

The core idea is the same broad pattern used by self-extracting archives and
portable app launchers: keep the executable normal, append data after it, and
anchor runtime paths at the executable location.
