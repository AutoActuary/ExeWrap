Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$bin = Join-Path $repoRoot "zig-out\bin"
$consoleLauncher = Join-Path $bin "ExeWrap-console.exe"
$windowedLauncher = Join-Path $bin "ExeWrap-windowed.exe"
$stamper = Join-Path $bin "ExeWrap-stamper.exe"

function Assert-Equal($Expected, $Actual, $Message) {
  if ($Expected -ne $Actual) {
    throw "$Message Expected '$Expected', got '$Actual'."
  }
}

function Write-Utf8NoBom($Path, $Text) {
  [System.IO.File]::WriteAllText($Path, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Get-PeSubsystem($Path) {
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -lt 0x40 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
    throw "Not a PE file: $Path"
  }
  $peOffset = [System.BitConverter]::ToUInt32($bytes, 0x3c)
  if ($peOffset + 24 -gt $bytes.Length) {
    throw "Invalid PE header: $Path"
  }
  if ($bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45 -or $bytes[$peOffset + 2] -ne 0 -or $bytes[$peOffset + 3] -ne 0) {
    throw "Invalid PE signature: $Path"
  }
  $optionalHeaderOffset = $peOffset + 24
  $subsystemOffset = $optionalHeaderOffset + 68
  if ($subsystemOffset + 2 -gt $bytes.Length) {
    throw "Missing PE subsystem field: $Path"
  }
  [System.BitConverter]::ToUInt16($bytes, $subsystemOffset)
}

foreach ($path in @($consoleLauncher, $windowedLauncher, $stamper)) {
  if (-not (Test-Path -LiteralPath $path)) {
    throw "Missing built executable: $path"
  }
}

Assert-Equal 3 (Get-PeSubsystem $consoleLauncher) "Base console launcher subsystem mismatch."
Assert-Equal 2 (Get-PeSubsystem $windowedLauncher) "Base windowed launcher subsystem mismatch."

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("exewrap-smoke-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
  $okConfig = Join-Path $tmp "ok.config.json"
  Write-Utf8NoBom $okConfig '{"command":["cmd.exe","/C","exit /b 0"]}'

  $inheritConsole = Join-Path $tmp "inherit-console.exe"
  & $stamper --launcher $consoleLauncher --config $okConfig $inheritConsole
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for inherited console launcher." }
  Assert-Equal 3 (Get-PeSubsystem $inheritConsole) "Inherited console subsystem mismatch."

  $inheritWindowed = Join-Path $tmp "inherit-windowed.exe"
  & $stamper --launcher $windowedLauncher --config $okConfig $inheritWindowed
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for inherited windowed launcher." }
  Assert-Equal 2 (Get-PeSubsystem $inheritWindowed) "Inherited windowed subsystem mismatch."

  $overrideConsole = Join-Path $tmp "override-console.exe"
  & $stamper --launcher $windowedLauncher --config $okConfig --subsystem console $overrideConsole
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for windowed-to-console override." }
  Assert-Equal 3 (Get-PeSubsystem $overrideConsole) "Windowed-to-console override subsystem mismatch."

  $overrideWindowed = Join-Path $tmp "override-windowed.exe"
  & $stamper --launcher $consoleLauncher --config $okConfig --subsystem windowed $overrideWindowed
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for console-to-windowed override." }
  Assert-Equal 2 (Get-PeSubsystem $overrideWindowed) "Console-to-windowed override subsystem mismatch."

  $waitConfig = Join-Path $tmp "wait.config.json"
  Write-Utf8NoBom $waitConfig '{"command":["powershell.exe","-NoProfile","-Command","Start-Sleep -Seconds 1; exit 37"]}'
  $waitExe = Join-Path $tmp "wait-console.exe"
  & $stamper --launcher $consoleLauncher --config $waitConfig $waitExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for wait test." }
  & $waitExe
  Assert-Equal 37 $LASTEXITCODE "Console launcher did not propagate child exit code."

  $cwdConfig = Join-Path $tmp "cwd.config.json"
  Write-Utf8NoBom $cwdConfig '{"command":["powershell.exe","-NoProfile","-Command","[System.IO.File]::WriteAllText(''cwd.txt'', (Get-Location).Path); exit 0"]}'
  $cwdExe = Join-Path $tmp "cwd-console.exe"
  & $stamper --launcher $consoleLauncher --config $cwdConfig $cwdExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for cwd test." }
  $workDir = Join-Path $tmp "work"
  New-Item -ItemType Directory -Force -Path $workDir | Out-Null
  Push-Location $workDir
  try {
    & $cwdExe
    if ($LASTEXITCODE -ne 0) { throw "Cwd smoke executable failed." }
  } finally {
    Pop-Location
  }
  Assert-Equal $workDir ([System.IO.File]::ReadAllText((Join-Path $workDir "cwd.txt"))) "Omitted cwd did not inherit launch cwd."

  $terminalConfig = Join-Path $tmp "terminal.config.json"
  Write-Utf8NoBom $terminalConfig '{"terminal":true,"command":["cmd.exe","/C","exit /b 0"]}'
  $terminalExe = Join-Path $tmp "terminal-removed.exe"
  & $stamper --launcher $consoleLauncher --config $terminalConfig $terminalExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper should allow syntactically valid config bytes before runtime parsing." }
  $terminalStdout = Join-Path $tmp "terminal.stdout.txt"
  $terminalStderr = Join-Path $tmp "terminal.stderr.txt"
  $terminalProcess = Start-Process -FilePath $terminalExe -NoNewWindow -Wait -PassThru -RedirectStandardOutput $terminalStdout -RedirectStandardError $terminalStderr
  $terminalOutput = ((Get-Content -Raw -ErrorAction SilentlyContinue $terminalStdout) + (Get-Content -Raw -ErrorAction SilentlyContinue $terminalStderr))
  if ($terminalProcess.ExitCode -eq 0) { throw "Config containing terminal unexpectedly succeeded." }
  if ($terminalOutput -notmatch 'terminal.*removed') {
    throw "Removed terminal migration message was not reported. Output: $terminalOutput"
  }

  $badBoolConfig = Join-Path $tmp "bad-bool.config.json"
  Write-Utf8NoBom $badBoolConfig '{"kill_children_on_exit":"true","command":["cmd.exe","/C","exit /b 0"]}'
  $badBoolExe = Join-Path $tmp "bad-bool.exe"
  & $stamper --launcher $consoleLauncher --config $badBoolConfig $badBoolExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper should allow syntactically valid config bytes before runtime parsing." }
  $badBoolStdout = Join-Path $tmp "bad-bool.stdout.txt"
  $badBoolStderr = Join-Path $tmp "bad-bool.stderr.txt"
  $badBoolProcess = Start-Process -FilePath $badBoolExe -NoNewWindow -Wait -PassThru -RedirectStandardOutput $badBoolStdout -RedirectStandardError $badBoolStderr
  $badBoolOutput = ((Get-Content -Raw -ErrorAction SilentlyContinue $badBoolStdout) + (Get-Content -Raw -ErrorAction SilentlyContinue $badBoolStderr))
  if ($badBoolProcess.ExitCode -eq 0) { throw "Config containing non-boolean kill_children_on_exit unexpectedly succeeded." }
  if ($badBoolOutput -notmatch 'kill_children_on_exit.*boolean') {
    throw "Non-boolean kill_children_on_exit message was not reported. Output: $badBoolOutput"
  }
} finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
