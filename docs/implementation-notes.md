# ExeWrap Implementation Notes

This document records the design rationale behind the templated JSON launcher.
It is for maintainers who need to change the format or explain why the
implementation is shaped the way it is. The user-facing config guide lives in
the README; this file focuses on parser, evaluator, overlay, and process
behavior.

## Code Map

| Area | File |
| --- | --- |
| Launcher entry point, child process setup, Windows Job Object support | [`src/main.zig`](../src/main.zig) |
| Overlay marker, config parsing, environment application, duplicate-key checks | [`src/root.zig`](../src/root.zig) |
| Template-aware preprocessing scan and random sentinels | [`src/template_scan.zig`](../src/template_scan.zig) |
| Template tokenizer, parser, evaluator, bases, and transforms | [`src/template_expr.zig`](../src/template_expr.zig) |
| Stamping helper | [`src/stamp.zig`](../src/stamp.zig) |
| Build graph and executable settings | [`build.zig`](../build.zig) |

## Why Use A PE Overlay

Windows PE executables can carry extra bytes after the mapped image. The launcher
uses that overlay area as the config carrier:

```text
base launcher exe + ASCII start marker + config bytes
```

This keeps the runtime executable normal and avoids editing Windows resources,
generating per-app source files, or requiring a packaging format. A stamped
launcher is still just an `.exe` that can be copied, renamed, and launched by
Explorer or another process.

The launcher searches for the last start marker in its own bytes. Config runs
from after that marker to the first following end marker, or to EOF if no end
marker is present. The stamper uses the same range detection when restamping:
it replaces the active config bytes and preserves the marker/suffix layout
instead of appending another overlay.

The start marker is the ASCII UUID string:

```text
8c0e8d4c-32af-4fd8-9c68-6a0f97efeb6a
```

The optional end marker is the ASCII UUID string:

```text
ce3beca3-7ed2-40a4-9133-f82198be1d7b
```

The default stamp helper omits the end marker because the config is written at
EOF. Other stampers can write the end marker when they need to append unrelated
data after the config.

The stamp helper applies optional Windows resources, such as icons, before it
patches a requested PE subsystem override and appends the overlay. Resource
updates can rewrite the PE file, so subsystem patching happens after resource
updates. The overlay is always the final write.

## Why Templated JSON Instead Of A Script

The original spec deliberately keeps the config declarative:

- JSON keeps the top-level shape familiar for launch configuration.
- `@{...}` expressions cover executable-relative paths, environment edits, and
  argument forwarding without adding a general scripting language.
- The expression language has no loops, conditionals, file probing, registry
  probing, or arbitrary code execution.

This keeps launch behavior deterministic and keeps failures close to malformed
configuration rather than runtime script behavior.

Lua or another embedded language can remain a future escape hatch if users need
discovery, fallback chains, or conditionals. It should not be added until real
configs prove that the declarative model is insufficient.

## Why The `@{...}` Delimiter

Bare braces are common in shell snippets, especially PowerShell script blocks:

```powershell
Where-Object { $_.Name -eq "demo" }
```

The launcher only treats `@{...}` as a template, so ordinary braces stay literal.
The escape `@@{` emits a literal `@{`.

Inside a template expression, quoted strings use JSON string escaping rules. The
scanner keeps reading until it finds a `}` outside template strings and outside
parenthesized transform arguments. This lets expressions contain values such as:

```text
@{env:"PATH":prepend_env(exe_parent:join("python"))}
```

## Three Processing Passes

The implementation follows the processing model from the spec.

### Pass 1: Template-Aware Scan

`src/template_scan.zig` scans raw UTF-8 bytes before JSON parsing. It replaces
each template expression with a random UUID-shaped sentinel and records:

- The sentinel UUID.
- The raw expression text.
- The original byte range.
- Whether the expression appeared as a raw JSON value, a whole string, or part
  of a string.

The random UUID strategy avoids predictable placeholders such as
`__EXPR_0001__`, which could collide with user text. The scanner retries when a
generated UUID appears in the original input or duplicates a previous sentinel.

Raw array splices such as `@{args}` become quoted sentinel strings during this
pass, so the next pass receives strict JSON.

### Pass 2: JSON Parse And Structural Validation

`src/root.zig` rejects duplicate keys before parsing. Duplicate keys are valid in
some loose JSON readers but would make source-order environment semantics
ambiguous, so they are a config error here.

After duplicate-key rejection, the transformed bytes are parsed with Zig's JSON
parser. Object keys are checked for sentinels and rejected if a template appeared
inside a key. Keys stay literal to keep config shape predictable.

### Pass 3: Config Walk And Evaluation

The config walker evaluates sentinels in values:

- A string expression can replace a whole string or part of a string.
- A list expression can replace a full command-array item.
- A list expression inside a larger string is rejected because one string cannot
  expand into multiple argv entries.

Environment entries are evaluated and immediately written back into the mutable
environment map. Later environment entries and the command array can read the
updated values.

## Expression Parser And Typed Values

`src/template_expr.zig` uses a tokenizer and recursive-descent parser instead of
ad hoc string splitting. That is necessary because transform arguments can be
quoted strings or nested expressions:

```text
@{env:"PATH":prepend_env(exe_parent:join("python"))}
```

The evaluator uses explicit value types:

```text
string
integer
list of strings
```

Typed values make these cases straightforward:

- `@{args}` returns a list and can splice command-array entries.
- `@{args:1}` returns one string.
- `@{args:from(2):1}` first slices a list, then indexes the sliced list.
- `@{args:parent}` fails with a wrong-transform-type error.
- `@{exe_dir:join(args)}` fails because `join` needs a string argument, not a
  list.

Transforms intentionally take zero or one argument. There is no comma syntax,
which keeps the grammar small and avoids hidden argument-order rules.

## Environment Evaluation Order

The spec calls for source-order environment mutation so users can write:

```json
{
  "env": {
    "PATH": "@{env:"PATH":prepend_env(exe_parent:join("python"))}",
    "PATH_AFTER": "@{env:"PATH"}"
  },
  "command": ["@{env:"PATH_AFTER"}"]
}
```

The implementation supports that behavior by updating the environment map as
each entry is evaluated. The command array is evaluated after `env`, so command
templates see the final edited environment.

`env` is an ordered object. Object source order currently follows Zig's parsed
object iteration behavior and is tested; maintainers should preserve this
deliberately if the parser representation changes. Duplicate object keys are
rejected so ordered evaluation cannot become ambiguous.

## Strictness Defaults

The default behavior favors portable optional values:

- Missing `@{env:"NAME"}` resolves to an empty string.
- Missing `@{args:N}` resolves to an empty string.
- Argument list slices clamp to available args.

The config can opt into errors with:

```json
{
  "error_on_missing_env": true,
  "error_on_arg_out_of_bounds": true
}
```

These flags are intentionally top-level, not per-expression, to keep the first
version of the language small.

## Windows Process Choices

Windows decides whether a parent shell waits for a process from the launched
executable's PE subsystem before ExeWrap can read its embedded config. That
means console-vs-windowed launcher behavior must be a build/stamp-time choice,
not a runtime JSON field.

The build emits two base launchers from the same `src/main.zig` source:

- `ExeWrap-console.exe` uses the Windows CUI subsystem. It is suitable for PATH
  command shims, CI, scripts, and tools where parent shells should wait and
  receive the child exit code.
- `ExeWrap-windowed.exe` uses the Windows GUI subsystem. It is suitable for
  Explorer shortcuts, protocol handlers, file associations, and background GUI
  launchers.

The stamper can preserve the input launcher's subsystem or patch the stamped
output to console or windowed with `--subsystem console|windowed`. The patcher
validates PE32 and PE32+ headers and writes only the optional-header
`Subsystem` field.

The runtime config schema deliberately does not support `terminal`. Child
stdio/window policy follows the stamped launcher's subsystem:

- Console launchers inherit stdin/stdout/stderr and do not set
  `CREATE_NO_WINDOW`.
- Windowed launchers ignore stdin/stdout/stderr and set `CREATE_NO_WINDOW`.

`kill_children_on_exit` uses a Windows Job Object with
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`. The child is spawned suspended, assigned to
the job, then resumed. If the launcher dies, Windows closes the job handle and
terminates the child process tree. This is opt-in because some launchers are
intended to start a process that outlives the launcher.

## UTF-8 And BOM Policy

The stamp helper validates config bytes before writing the output file. The
runtime validates again after reading the embedded overlay.

The implementation accepts a leading UTF-8 BOM after leading whitespace and then
parses the remaining bytes. Non-UTF-8 config bytes are rejected before JSON
parsing so malformed text cannot be interpreted differently by later layers.

## Current Limits And Known Spec Adjustments

The implementation intentionally keeps several items small or explicit:

- Common user directories are currently derived from `USERPROFILE` plus the
  conventional child name (`Documents`, `Downloads`, `Desktop`). The current
  implementation does not call a platform known-folder API.
- The scanner records source byte ranges for templates, but JSON parse errors
  are not yet remapped back to original template-source offsets.
- Object-order environment evaluation depends on the current Zig JSON object
  representation preserving iteration order. If the parser representation
  changes, ordered `env` object evaluation must remain deliberate and tested.
- Boolean options are read only when the JSON value is a boolean. Non-boolean
  values are treated as absent by the current helper rather than producing a
  dedicated type error.
- The launcher is Windows-focused. Some path transforms handle drive and UNC
  roots, while cross-platform semantics should be reviewed before promising
  Linux or macOS behavior.

## Test Coverage Intent

The tests are split by layer:

- `src/template_scan.zig`: literal escapes, raw-value sentinels, string
  sentinels, nested quotes/parentheses, sentinel collision retries, and malformed
  templates.
- `src/template_expr.zig`: tokenizer/parser behavior, base values, path/string
  transforms, environment lookup strictness, argument slicing, env-list
  transforms, and wrong-type failures.
- `src/root.zig`: UTF-8/BOM handling, overlay markers, config parsing, command
  splicing, environment mutation order, strict failures, duplicate keys, object
  key templates, and unsafe list contexts.

When extending the language, add tests at the lowest layer that owns the behavior
and at least one integration test in `src/root.zig` if the feature changes config
walking or child-command output.
