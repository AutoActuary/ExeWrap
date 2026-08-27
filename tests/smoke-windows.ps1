Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$bin = if ($env:EXEWRAP_BIN_DIR) {
  $env:EXEWRAP_BIN_DIR
} else {
  Join-Path $repoRoot "target\release"
}
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

  $lookupDir = Join-Path $tmp "lookup"
  New-Item -ItemType Directory -Force -Path $lookupDir | Out-Null
  Write-Utf8NoBom (Join-Path $lookupDir "fixture.cmd") '@exit /b 29'
  $fixtureExeConfig = Join-Path $tmp "fixture-exe.config.json"
  Write-Utf8NoBom $fixtureExeConfig '{"command":["cmd.exe","/C","exit /b 31"]}'
  & $stamper --launcher $consoleLauncher --config $fixtureExeConfig (Join-Path $lookupDir "fixture.exe")
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for PATHEXT order fixture." }

  $lookupDirJson = $lookupDir | ConvertTo-Json -Compress
  $lookupConfig = Join-Path $tmp "lookup.config.json"
  Write-Utf8NoBom $lookupConfig ('{"cwd":' + $lookupDirJson + ',"command":["fixture",@{args}]}')
  $lookupExe = Join-Path $tmp "lookup-console.exe"
  & $stamper --launcher $consoleLauncher --config $lookupConfig $lookupExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for PATHEXT lookup test." }
  $savedPathExt = $env:PATHEXT
  try {
    $env:PATHEXT = ".CMD;.EXE;.COM;.BAT"
    & $lookupExe 'x & exit /b 77'
    Assert-Equal 29 $LASTEXITCODE "PATHEXT order or secure batch argument forwarding regressed."
    $batchError = (& $lookupExe "line`nbreak" 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0 -or $batchError -notmatch 'InvalidBatchScriptArg') {
      throw "Invalid batch arguments did not preserve the InvalidBatchScriptArg error tag. Output: $batchError"
    }
  } finally {
    $env:PATHEXT = $savedPathExt
  }

  $pathLookupDir = Join-Path $tmp "path-lookup"
  New-Item -ItemType Directory -Force -Path $pathLookupDir | Out-Null
  Write-Utf8NoBom (Join-Path $pathLookupDir "path-fixture.cmd") '@exit /b 30'
  $pathConfig = Join-Path $tmp "path-lookup.config.json"
  Write-Utf8NoBom $pathConfig ('{"cwd":' + ($tmp | ConvertTo-Json -Compress) + ',"env":{"PATH":""},"command":["path-fixture"]}')
  $pathExe = Join-Path $tmp "path-lookup-console.exe"
  & $stamper --launcher $consoleLauncher --config $pathConfig $pathExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for parent PATH lookup test." }
  $savedPath = $env:PATH
  try {
    $env:PATH = "$pathLookupDir;$savedPath"
    & $pathExe
    Assert-Equal 30 $LASTEXITCODE "Command lookup did not use the launcher's parent PATH."
  } finally {
    $env:PATH = $savedPath
  }

  $relativeDir = Join-Path $tmp "tools"
  New-Item -ItemType Directory -Force -Path $relativeDir | Out-Null
  Write-Utf8NoBom (Join-Path $relativeDir "relative.cmd") '@exit /b 32'
  $relativeConfig = Join-Path $tmp "relative.config.json"
  Write-Utf8NoBom $relativeConfig ('{"cwd":' + ($tmp | ConvertTo-Json -Compress) + ',"command":["tools\\relative"]}')
  $relativeExe = Join-Path $tmp "relative-console.exe"
  & $stamper --launcher $consoleLauncher --config $relativeConfig $relativeExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for relative command lookup test." }
  & $relativeExe
  Assert-Equal 32 $LASTEXITCODE "Relative command lookup did not honor cwd and PATHEXT."

  $captureScript = Join-Path $tmp "capture-args.ps1"
  Write-Utf8NoBom $captureScript @'
param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest)
[IO.File]::WriteAllText($env:EXEWRAP_CAPTURE_PATH, ($Rest | ConvertTo-Json -Compress))
'@
  $captureOutput = Join-Path $tmp "captured-args.json"
  $captureConfig = Join-Path $tmp "capture-args.config.json"
  $captureText = '{"env":{"EXEWRAP_CAPTURE_PATH":' + ($captureOutput | ConvertTo-Json -Compress) +
    '},"command":["powershell.exe","-NoProfile","-File",' + ($captureScript | ConvertTo-Json -Compress) + ',@{args}]}'
  Write-Utf8NoBom $captureConfig $captureText
  $captureExe = Join-Path $tmp "capture-args-console.exe"
  & $stamper --launcher $consoleLauncher --config $captureConfig $captureExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for argument fidelity test." }
  $forwardedArgs = @("", "two words", 'a"b', 'trailing\', "é😀", 'meta&|<>^%!')
  & $captureExe $forwardedArgs
  if ($LASTEXITCODE -ne 0) { throw "Argument fidelity launcher failed." }
  $capturedArgs = @([IO.File]::ReadAllText($captureOutput) | ConvertFrom-Json)
  Assert-Equal $forwardedArgs.Count $capturedArgs.Count "Argument forwarding changed the argument count."
  for ($argumentIndex = 0; $argumentIndex -lt $forwardedArgs.Count; $argumentIndex++) {
    Assert-Equal $forwardedArgs[$argumentIndex] $capturedArgs[$argumentIndex] "Argument forwarding changed argument $argumentIndex."
  }

  $invalidExePath = Join-Path $tmp "invalid-child.exe"
  Write-Utf8NoBom $invalidExePath "not a portable executable"
  $invalidExeConfig = Join-Path $tmp "invalid-exe.config.json"
  Write-Utf8NoBom $invalidExeConfig ('{"command":[' + ($invalidExePath | ConvertTo-Json -Compress) + ']}')
  $invalidExeWrapper = Join-Path $tmp "invalid-exe-console.exe"
  & $stamper --launcher $consoleLauncher --config $invalidExeConfig $invalidExeWrapper
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for invalid executable reporting test." }
  $invalidStdout = Join-Path $tmp "invalid-exe.stdout.txt"
  $invalidStderr = Join-Path $tmp "invalid-exe.stderr.txt"
  $invalidProcess = Start-Process -FilePath $invalidExeWrapper -NoNewWindow -Wait -PassThru -RedirectStandardOutput $invalidStdout -RedirectStandardError $invalidStderr
  $invalidOutput = ((Get-Content -Raw -ErrorAction SilentlyContinue $invalidStdout) + (Get-Content -Raw -ErrorAction SilentlyContinue $invalidStderr))
  if ($invalidProcess.ExitCode -eq 0) { throw "Invalid executable unexpectedly launched." }
  if ($invalidOutput -notmatch 'InvalidExe') {
    throw "Invalid executable did not preserve the InvalidExe error tag. Output: $invalidOutput"
  }

  $iconPath = Join-Path $tmp "tiny.ico"
  [byte[]]$iconBytes = @(
    0, 0, 1, 0, 1, 0,
    16, 16, 0, 0, 1, 0, 32, 0, 4, 0, 0, 0, 22, 0, 0, 0,
    0, 0, 0, 0
  )
  [System.IO.File]::WriteAllBytes($iconPath, $iconBytes)
  $iconExe = Join-Path $tmp "icon-console.exe"
  & $stamper --launcher $consoleLauncher --config $okConfig --icon $iconPath $iconExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed while adding an icon resource." }
  & $iconExe
  if ($LASTEXITCODE -ne 0) { throw "Icon-stamped launcher failed." }

  $firstConfig = Join-Path $tmp "first.config.json"
  $secondConfig = Join-Path $tmp "second.config.json"
  Write-Utf8NoBom $firstConfig '{"command":["cmd.exe","/C","exit /b 11"]}'
  Write-Utf8NoBom $secondConfig '{"command":["cmd.exe","/C","exit /b 12"]}'
  $firstStamped = Join-Path $tmp "first-stamped.exe"
  $restamped = Join-Path $tmp "restamped.exe"
  & $stamper --launcher $consoleLauncher --config $firstConfig $firstStamped
  if ($LASTEXITCODE -ne 0) { throw "Initial stamp failed for restamp test." }
  & $stamper --launcher $firstStamped --config $secondConfig $restamped
  if ($LASTEXITCODE -ne 0) { throw "Restamping an existing launcher failed." }
  & $restamped
  Assert-Equal 12 $LASTEXITCODE "Restamped launcher did not replace the prior config."

  $jobConfig = Join-Path $tmp "job.config.json"
  Write-Utf8NoBom $jobConfig '{"kill_children_on_exit":true,"command":["powershell.exe","-NoProfile","-Command","Start-Sleep -Seconds 2; [System.IO.File]::WriteAllText(''job-survived.txt'', ''alive'')"]}'
  $jobExe = Join-Path $tmp "job-console.exe"
  & $stamper --launcher $consoleLauncher --config $jobConfig $jobExe
  if ($LASTEXITCODE -ne 0) { throw "Stamper failed for Job Object test." }
  $jobProcess = Start-Process -FilePath $jobExe -WorkingDirectory $tmp -PassThru
  Start-Sleep -Milliseconds 500
  Stop-Process -Id $jobProcess.Id -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  if (Test-Path -LiteralPath (Join-Path $tmp "job-survived.txt")) {
    throw "kill_children_on_exit did not terminate the child process tree."
  }

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
