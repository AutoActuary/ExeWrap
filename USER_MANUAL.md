# zig-launcher User Manual

`zig-launcher` turns one generic launcher executable into a renamed, configured
launcher by appending JSON to the end of the `.exe`.

The stamped launcher reads its own config, expands placeholders such as
`{exe_dir}`, applies environment variables, sets the child working directory,
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

For `bundle/bin/my-tool.exe`, the placeholder `{exe_dir}` is `bundle/bin`.
That means the sibling Python runtime is:

```text
{exe_dir}\..\python\python.exe
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
  "cwd": "{exe_dir}\\..\\app",
  "env": {
    "PYTHONHOME": "{exe_dir}\\..\\python",
    "PYTHONPATH": "{exe_dir}\\..\\app"
  },
  "command": [
    "{exe_dir}\\..\\python\\python.exe",
    "-m",
    "my_module",
    "--input",
    "{exe_dir}\\..\\data\\input.json"
  ]
}
```

Important details:

- `"{exe_dir}\\..\\python\\python.exe"` is the executable path.
- `"-m"` and `"my_module"` are separate arguments.
- Any later values are normal module arguments.
- `cwd` controls where relative paths inside the Python process resolve.
- Backslashes in JSON strings must be doubled as `\\`.

For a silent background run, switch to:

```json
{
  "silent": true,
  "cwd": "{exe_dir}\\..\\app",
  "command": [
    "{exe_dir}\\..\\python\\python.exe",
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
zig-out\bin\zig-launcher-stamp.exe `
  zig-out\bin\zig-launcher.exe `
  my-tool.config.json `
  bundle\bin\my-tool.exe
```

Now `bundle\bin\my-tool.exe` contains both the launcher and the config.

Config files are UTF-8 JSON. A UTF-8 BOM is accepted, but non-UTF-8 config
bytes are rejected before JSON parsing.

## Placeholders

Use placeholders anywhere inside `cwd`, `env` values, and `command` entries.

| Placeholder | Meaning |
| --- | --- |
| `{exe_path}` | Full path to the stamped executable |
| `{exe}` | Alias for `{exe_path}` |
| `{exe_dir}` | Directory containing the stamped executable |
| `{exe_name}` | File name of the stamped executable |
| `{exe_stem}` | File name without extension |
| `{cwd}` | Directory the launcher was started from |
| `{launch_cwd}` | Alias for `{cwd}` |

The launcher also sets these environment variables for the child process:

| Variable | Meaning |
| --- | --- |
| `zig_launcher_EXE` | Full path to the stamped executable |
| `zig_launcher_DIR` | Directory containing the stamped executable |
| `zig_launcher_NAME` | File name of the stamped executable |
| `zig_launcher_STEM` | File name without extension |
| `zig_launcher_LAUNCH_CWD` | Directory the launcher was started from |

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

## Running Through cmd.exe

Prefer a direct argv list for normal programs. Use `cmd.exe /C` only when you
need shell features such as `&&`, redirection, `set`, `%VARIABLE%` expansion, or
built-in commands.

```json
{
  "terminal": true,
  "cwd": "{exe_dir}",
  "command": [
    "cmd.exe",
    "/C",
    "echo Launcher: %zig_launcher_NAME% && dir && pause"
  ]
}
```

## Environment Variables

`env` can be an object:

```json
{
  "env": {
    "APP_HOME": "{exe_dir}\\..\\app",
    "PYTHONPATH": "{exe_dir}\\..\\app"
  },
  "command": ["cmd.exe", "/C", "echo %APP_HOME%"]
}
```

Or an array:

```json
{
  "env": [
    { "name": "APP_HOME", "value": "{exe_dir}\\..\\app" },
    { "name": "PYTHONPATH", "value": "{exe_dir}\\..\\app" }
  ],
  "command": ["cmd.exe", "/C", "echo %APP_HOME%"]
}
```

## Troubleshooting

If a path contains backslashes, write them as `\\` in JSON.

If a Python module cannot be found, check `cwd` and `PYTHONPATH`. A good default
for a bundled app is usually:

```json
"cwd": "{exe_dir}\\..\\app",
"env": {
  "PYTHONPATH": "{exe_dir}\\..\\app"
}
```

If a command works in PowerShell but not in the launcher, split it into argv
entries. PowerShell parsing is not involved unless you explicitly run
`powershell.exe`.

If you need shell syntax, run through `cmd.exe /C` or `powershell.exe` and put
the shell command as the final argument.

