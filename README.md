# zig-launcher

`zig-launcher` is a tiny Windows launcher written in Zig. The built launcher can
read configuration appended to its own executable and then run a command near the
launcher file.

The overlay format is:

```text
zig-launcher.exe + 16-byte marker UUID + UTF-8 JSON config
```

Marker UUID: `8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a`

The marker is the binary UUID bytes, not the ASCII UUID string. The launcher
searches from the end of the file, so a stamped executable can be copied or
renamed without changing the config.

## Build

```powershell
zig build
```

This installs two tools under `zig-out/bin`:

- `zig-launcher.exe`: the self-reading launcher
- `zig-launcher-stamp.exe`: helper that appends a JSON config to a launcher

## Stamp A Launcher

```powershell
zig-out\bin\zig-launcher-stamp.exe `
  zig-out\bin\zig-launcher.exe `
  examples\config.json `
  examples\demo-launcher.exe
```

Run `examples\demo-launcher.exe` to execute the stamped command.

For packaging recipes and copy/paste examples, see the
[user manual](USER_MANUAL.md).

## Config

```json
{
  "terminal": true,
  "cwd": "{exe_dir}",
  "env": {
    "SCRIPT_HOME": "{exe_dir}"
  },
  "command": ["cmd.exe", "/C", "{exe_dir}\\run.cmd"]
}
```

Fields:

- `terminal`: when `true`, lets a console child show a terminal window.
- `silent`: when `true`, runs the child with `CREATE_NO_WINDOW` and ignored stdio.
- `cwd`: child working directory. Defaults to `{exe_dir}`.
- `env`: environment variables as either an object or an array of `{ "name", "value" }` entries.
- `command` or `commandline`: argv list to run.

If both `terminal` and `silent` are omitted, the launcher defaults to silent.
If both are present, `silent` wins.

Placeholders:

- `{exe}` or `{exe_path}`: full path to the stamped executable
- `{exe_dir}`: directory containing the stamped executable
- `{exe_name}`: file name of the stamped executable
- `{exe_stem}`: file name without extension
- `{cwd}` or `{launch_cwd}`: directory the launcher was started from

The launcher also injects these environment variables for the child:

- `zig_launcher_EXE`
- `zig_launcher_DIR`
- `zig_launcher_NAME`
- `zig_launcher_STEM`
- `zig_launcher_LAUNCH_CWD`

## Notes And Prior Art

Windows PE files tolerate overlay bytes after the mapped executable image. This
is the same general technique used by self-extracting archives and one-file
packagers: keep the runtime executable normal, append payload data, then locate
the payload at runtime by marker or trailer.

For path behavior, this follows AppImage/AppDir-style launchers and installer
systems that expose the executable directory as the stable base for bundled
files. The default `cwd` is therefore `{exe_dir}`, which makes scripts next to
the launcher work even when the launcher is started from Explorer, another
process, or a different shell directory.

The launcher is built with the Windows GUI subsystem. That avoids an unavoidable
console flash from the launcher itself. A visible child terminal is requested by
allowing the child console process to create/use a console when `terminal` is
true; silent mode uses `CREATE_NO_WINDOW`.

References:

- Zig 0.15.2 was selected from the official Windows x86_64 release:
  https://ziglang.org/download/
- AppImage/AppDir influenced the `{exe_dir}`-as-app-root model:
  https://docs.appimage.org/reference/appdir.html
- PE overlay behavior is the same family of approach used by self-extracting
  archives and packagers:
  https://stackoverflow.com/questions/5795446/appending-data-to-an-exe

