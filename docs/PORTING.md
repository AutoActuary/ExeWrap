# Archived Zig-to-Rust port record

The ExeWrap Rust rewrite is complete. This document records the methodology and
source mapping used during the port. It is not a description of the current
implementation language. The historical Zig implementation at tag `v2.1.0`
and its tests defined the observable-behavior baseline.

All remaining Zig names in this document and in `LIFETIMES.tsv` are deliberate
historical references. Current build, usage, and implementation documentation
contains no Zig instructions.

The structure follows Bun's whole-port method: a mechanical all-at-once rewrite,
an explicit [porting map](https://github.com/oven-sh/bun/blob/46d3bc29f270fa881dd5730ef1549e88407701a5/docs/PORTING.md),
a lifetime inventory, compiler errors as the work queue, and unchanged tests as
the behavioral contract. Bun describes the completed process in
["Bun's Zig-to-Rust Rewrite"](https://bun.com/blog/bun-in-rust).

## Port ground rules

- Port the whole program in one branch. Do not add a mixed Zig/Rust runtime or
  compatibility layer.
- Keep module boundaries and control flow recognizable. Use Rust naming, but
  keep source functions close enough for a side-by-side audit.
- Preserve the config format, overlay markers, PE parsing, template grammar,
  error cases, process behavior, exit codes, launcher subsystems, stamper CLI,
  and output filenames.
- Preserve all existing tests. Translate each Zig test to Rust and keep the
  Windows smoke suite language-independent.
- Do not make intentional behavior changes while porting. Record tempting
  cleanups for later.
- Prefer owned `String`, `Vec<T>`, and ordered maps over allocator-backed
  slices. Let `Drop` replace Zig `defer` and `errdefer` cleanup.
- Keep unsafe code at Windows FFI boundaries. Every unsafe block needs a
  `SAFETY` comment that states the API or pointer invariant.
- Treat every length and PE offset from a file as hostile. Check the complete
  range before reading, slicing, multiplying, or adding.
- Keep path and template operations byte-for-byte compatible. Do not replace
  the custom Windows-aware path helpers with `std::path` behavior.
- Compile first, then use compiler errors as the work queue. Do not weaken a
  test to make the port pass.
- Build release binaries with aborting panics, size optimization, whole-program
  LTO, one codegen unit, and stripped symbols.

## File map

| Zig source | Rust target | Rule |
| --- | --- | --- |
| `src/template_scan.zig` | `src/template_scan.rs` | Same scanner states, escapes, numeric sentinels, and source ranges. |
| `src/template_expr.zig` | `src/template_expr.rs` | Same tokenizer, parser, 1-based indexing, inclusive slices, transforms, and JSON escaping. |
| `src/root.zig` | `src/lib.rs` | Same ordered config walk, duplicate rejection, PE overlay handling, and runtime metadata. |
| `src/main.zig` | `src/launcher.rs` plus two thin binaries | One implementation, compiled with console and GUI PE subsystems. |
| `src/stamp.zig` | `src/stamp.rs` plus the thin `src/bin/exewrap-stamper.rs` entry point | Same CLI grammar, restamping, subsystem patching, and icon resources. |
| `build.zig*` | `Cargo.toml`, `rust-toolchain.toml` | Preserve three binary names and all Windows targets. |

## Type and idiom map

| Zig | Rust |
| --- | --- |
| `[]const u8` text | `&str` while borrowed, `String` when stored or returned |
| `[]const T` | `&[T]` while borrowed, `Vec<T>` when owned |
| `?T` | `Option<T>` |
| `!T` / `anyerror!T` | `Result<T, Error>` with stable Zig error-tag names |
| `union(enum)` | payload `enum` |
| `extern struct` | `#[repr(C)] struct` |
| `std.ArrayList(T)` | `Vec<T>` |
| `std.StringHashMap` | `BTreeSet` for bounded membership checks; ordered JSON objects use `Vec<(String, JsonValue)>` |
| `defer` / `errdefer` for memory | lexical ownership and `Drop` |
| `@intCast` | checked conversion at file/input boundaries |
| `std.mem.readInt` | checked slice followed by `from_le_bytes` |
| Windows `extern` calls | narrow FFI wrappers with owned handle guards |

## JSON contract

The template scanner runs before JSON parsing. It replaces templates with
39-digit numeric sentinels wrapped in spaces. The JSON parser must preserve
object insertion order and expose numbers without converting the sentinel to a
floating-point value. A separate recursive scan rejects duplicate keys before
normal parsing, matching the Zig implementation.

`command` must remain the last top-level key. `env` values are evaluated and
written into the child environment in source order. Later values and the
command see earlier edits.

## Windows process contract

- Console launchers inherit standard handles and return the child's exit code.
- Windowed launchers use the GUI subsystem, hide child console windows, and do
  not inherit standard handles.
- `kill_children_on_exit` creates a job with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, starts the child suspended, assigns it
  to the job, resumes it, and waits.
- All Win32 handles have one owner and close on every return path.

## Verification performed

1. `cargo check --all-targets`
2. `cargo test`
3. `cargo build --release` for x64
4. unchanged `tests/smoke-windows.ps1`
5. release builds for x86 and ARM64
6. compare subsystem fields, filenames, behavior, and byte sizes with the Zig
   baseline
7. run `cargo clippy --all-targets -- -D warnings` and `cargo fmt --check`

## Baseline

The clean v2.1.0 Zig 0.15.2 baseline on Windows x64 passes all unit and smoke
tests. ReleaseSmall sizes are:

| Binary | Bytes |
| --- | ---: |
| `ExeWrap-console.exe` | 352,768 |
| `ExeWrap-windowed.exe` | 352,768 |
| `ExeWrap-stamper.exe` | 235,520 |

## Rust result in v3.0.0

The Rust port keeps every one of the 62 baseline test cases as a distinct test
and adds eight tests for Rust-owned parser, bounded I/O, depth limits, loader
errors, Unicode environment names, and resource code. All 70 tests pass. The
expanded Windows smoke suite checks PATHEXT resolution and order, parent-PATH
lookup, relative commands,
secure batch arguments, exact argument forwarding, malformed executables,
subsystems, icons, restamping, and Job Object cleanup.

The final audit also corrected bounded-read TOCTOU gaps, a resource-update
handle double-finalization path, quadratic membership checks, low-entropy
template sentinels, and Windows command-resolution and error-tag differences.

The final audit used Rust 1.98.0. Published v3.0.0 static-runtime release sizes
are:

| Binary | Rust x64 bytes | Rust x86 bytes | Rust ARM64 bytes |
| --- | ---: | ---: | ---: |
| `ExeWrap-console.exe` | 374,784 | 326,656 | 353,792 |
| `ExeWrap-windowed.exe` | 374,784 | 326,656 | 353,792 |
| `ExeWrap-stamper.exe` | 232,960 | 207,872 | 229,376 |
