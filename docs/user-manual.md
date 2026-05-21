# overlay-launcher User Manual

`overlay-launcher` turns one generic launcher executable into a renamed, configured
launcher by appending JSON to the end of the `.exe`.

The stamped launcher reads its own config, evaluates template expressions such as
`@{exe_dir}`, applies environment variables, sets the child working directory,
and runs the configured argv list.

## Mental Model

Think of the config as a direct `CreateProcess` argv list:

```json
"command": ["program.exe", "arg1", "arg2"]
```

Each JSON string is one argument. Do not quote and join the whole command unless
you intentionally want to run through `cmd.exe /C`.

Good:

```json
"command": ["python.exe", "-m", "my_module", "--flag", "value with spaces"]
```

Avoid:

```json
"command": ["python.exe -m my_module --flag \"value with spaces\""]
```

## Directory Layout

A common portable layout is:

```text
bundle/
  bin/
    my-tool.exe
  python/
    python.exe
  app/
    my_module/
      __main__.py
```

For `bundle/bin/my-tool.exe`, the template expression `@{exe_dir}` is `bundle/bin`.
That means the sibling Python runtime is:

```text
@{exe_dir}\..\python\python.exe
```

## Run A Python Module

This is the direct equivalent of:

```powershell
<this-dir>\..\python\python.exe -m <modname> <args...>
```

Use this config:

```json
{
  "terminal": true,
  "cwd": "@{exe_dir}\\..\\app",
  "env": {
    "PYTHONHOME": "@{exe_dir}\\..\\python",
    "PYTHONPATH": "@{exe_dir}\\..\\app"
  },
  "command": [
    "@{exe_dir}\\..\\python\\python.exe",
    "-m",
    "my_module",
    "--input",
    "@{exe_dir}\\..\\data\\input.json",
    @{args}
  ]
}
```

Important details:

- `"@{exe_dir}\\..\\python\\python.exe"` is the executable path.
- `"-m"` and `"my_module"` are separate arguments.
- Any later values are normal module arguments.
- `@{args}` splices all arguments passed to the launcher into the child argv list.
- `cwd` controls where relative paths inside the Python process resolve.
- Backslashes in JSON strings must be doubled as `\\`.

For a silent background run, switch to:

```json
{
  "silent": true,
  "cwd": "@{exe_dir}\\..\\app",
  "command": [
    "@{exe_dir}\\..\\python\\python.exe",
    "-m",
    "my_module"
  ]
}
```

## Stamp The Exe

Build the launcher:

```powershell
zig build
```

The default build optimizes for small release binaries. Use
`zig build -Doptimize=Debug` for a debug build.

Create `my-tool.config.json`, then stamp it:

```powershell
zig-out\bin\overlay-launcher-stamp.exe `
  zig-out\bin\overlay-launcher.exe `
  my-tool.config.json `
  bundle\bin\my-tool.exe
```

Now `bundle\bin\my-tool.exe` contains both the launcher and the config.

Config files are UTF-8 JSON. A UTF-8 BOM is accepted, but non-UTF-8 config
bytes are rejected before JSON parsing.

## Template Expressions

Use `@{...}` template expressions anywhere inside `cwd`, `env` values, and
`command` entries. Bare braces are ordinary text, so PowerShell script blocks
such as `Where-Object { $_.Name -eq "python" }` do not need escaping.

| Expression | Meaning |
| --- | --- |
| `@{exe_path}` | Full path to the stamped executable |
| `@{exe_dir}` | Directory containing the stamped executable |
| `@{exe_filename}` | File name of the stamped executable |
| `@{exe_filename_noext}` | File name without extension |
| `@{cwd}` | Directory the launcher was started from |
| `@{args}` | All user arguments, spliced into a command array |
| `@{env:"PATH"}` | Current environment value, including earlier config edits |

The launcher also sets these environment variables for the child process:

| Variable | Meaning |
| --- | --- |
| `OVERLAY_LAUNCHER_EXE` | Full path to the stamped executable |
| `OVERLAY_LAUNCHER_DIR` | Directory containing the stamped executable |
| `OVERLAY_LAUNCHER_NAME` | File name of the stamped executable |
| `OVERLAY_LAUNCHER_STEM` | File name without extension |
| `OVERLAY_LAUNCHER_LAUNCH_CWD` | Directory the launcher was started from |

## Terminal Or Silent

Use `terminal` when you want the child process to be visible:

```json
{
  "terminal": true,
  "command": ["cmd.exe", "/C", "echo hello && pause"]
}
```

Use `silent` when you do not want a console window:

```json
{
  "silent": true,
  "command": ["cmd.exe", "/C", "some-background-task.cmd"]
}
```

If neither field is present, the launcher defaults to silent.
If both are present, `silent` wins.

## Kill Child Processes With The Launcher

On Windows, set `kill_children_on_exit` when the launcher should own the whole
process tree:

```json
{
  "silent": true,
  "kill_children_on_exit": true,
  "command": ["powershell.exe", "-NoProfile", "-Command", "python.exe -m my_worker"]
}
```

This puts the immediate child process in a Windows Job Object configured with
kill-on-close. If the launcher process is killed, Windows closes the job handle
and terminates the child process tree. Leave this option unset or `false` when
you intentionally want a launched process to survive after the launcher exits.

## Running Through cmd.exe

Prefer a direct argv list for normal programs. Use `cmd.exe /C` only when you
need shell features such as `&&`, redirection, `set`, `%VARIABLE%` expansion, or
built-in commands.

```json
{
  "terminal": true,
  "cwd": "@{exe_dir}",
  "command": [
    "cmd.exe",
    "/C",
    "echo Launcher: %OVERLAY_LAUNCHER_NAME% && dir && pause"
  ]
}
```

## Environment Variables

`env` can be an object:

```json
{
  "env": {
    "APP_HOME": "@{exe_dir}\\..\\app",
    "PYTHONPATH": "@{exe_dir}\\..\\app"
  },
  "command": ["cmd.exe", "/C", "echo %APP_HOME%"]
}
```

Or an array:

```json
{
  "env": [
    { "name": "APP_HOME", "value": "@{exe_dir}\\..\\app" },
    { "name": "PYTHONPATH", "value": "@{exe_dir}\\..\\app" }
  ],
  "command": ["cmd.exe", "/C", "echo %APP_HOME%"]
}
```

## Troubleshooting

If a path contains backslashes, write them as `\\` in JSON.

If a Python module cannot be found, check `cwd` and `PYTHONPATH`. A good default
for a bundled app is usually:

```json
"cwd": "@{exe_dir}\\..\\app",
"env": {
  "PYTHONPATH": "@{exe_dir}\\..\\app"
}
```

If a command works in PowerShell but not in the launcher, split it into argv
entries. PowerShell parsing is not involved unless you explicitly run
`powershell.exe`.

If you need shell syntax, run through `cmd.exe /C` or `powershell.exe` and put
the shell command as the final argument.

