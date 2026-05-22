param(
    [string] $Launcher = (Join-Path $PSScriptRoot '..\zig-out\bin\ExeWrap.exe'),
    [string] $Stamper = (Join-Path $PSScriptRoot '..\zig-out\bin\ExeWrap-stamper.exe')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not [Environment]::Is64BitOperatingSystem) {
    Write-Host 'Skipping Windows smoke tests on non-64-bit Windows.'
    exit 0
}

$Launcher = (Resolve-Path $Launcher).Path
$Stamper = (Resolve-Path $Stamper).Path
$Root = Join-Path ([System.IO.Path]::GetTempPath()) ('exewrap-smoke-' + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $Root | Out-Null

function Write-Utf8NoBom([string] $Path, [string] $Text) {
    $Utf8 = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($Path, $Text, $Utf8)
}

function New-SmokeCase([string] $Name, [string] $ConfigText) {
    $Dir = Join-Path $Root $Name
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $Config = Join-Path $Dir 'config.json'
    Write-Utf8NoBom $Config $ConfigText
    $Output = Join-Path $Dir "$Name.exe"
    & $Stamper --launcher $Launcher --config $Config $Output
    if ($LASTEXITCODE -ne 0) {
        throw "Stamper failed for $Name with exit code $LASTEXITCODE."
    }
    return @{ Dir = $Dir; Exe = $Output }
}

function Invoke-SmokeCase([string] $Name, [string] $Exe) {
    $Dir = Split-Path -Parent $Exe
    $Stdout = Join-Path $Dir 'stdout.txt'
    $Stderr = Join-Path $Dir 'stderr.txt'
    $Process = Start-Process -FilePath $Exe -WorkingDirectory $Dir -Wait -PassThru -RedirectStandardOutput $Stdout -RedirectStandardError $Stderr
    return @{
        Name = $Name
        Dir = $Dir
        ExitCode = $Process.ExitCode
        Stdout = if (Test-Path $Stdout) { [System.IO.File]::ReadAllText($Stdout).Trim() } else { '' }
        Stderr = if (Test-Path $Stderr) { [System.IO.File]::ReadAllText($Stderr).Trim() } else { '' }
    }
}

function Assert-ExitCode($Result, [int] $Expected) {
    if ($Result.ExitCode -ne $Expected) {
        throw "$($Result.Name) exited $($Result.ExitCode), expected $Expected. Stdout: $($Result.Stdout) Stderr: $($Result.Stderr)"
    }
}

function Assert-Marker([string] $Dir, [string] $Name, [string] $Expected) {
    $Path = Join-Path $Dir $Name
    if (-not (Test-Path $Path)) {
        throw "Expected marker file missing: $Path"
    }
    $Actual = [System.IO.File]::ReadAllText($Path).Trim()
    if ($Actual -ne $Expected) {
        throw "Marker $Name was '$Actual', expected '$Expected'."
    }
}

try {
    $CmdDirect = @'
@echo off
echo cmd-direct-ok>"%~dp0cmd.out"
exit /b 7
'@
    $BatDirect = @'
@echo off
echo bat-direct-ok>"%~dp0bat.out"
exit /b 8
'@
    $CmdPathext = @'
@echo off
echo cmd-pathext-ok>"%~dp0cmd_pathext.out"
exit /b 15
'@
    $GuiVbs = @'
Set fso = CreateObject("Scripting.FileSystemObject")
Set f = fso.CreateTextFile(fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "gui.out"), True)
f.WriteLine "gui-wscript-ok"
f.Close
WScript.Quit 14
'@
    $DirectVbs = @'
Set fso = CreateObject("Scripting.FileSystemObject")
Set f = fso.CreateTextFile(fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "vbs_direct.out"), True)
f.WriteLine "vbs-direct-ok"
f.Close
WScript.Quit 16
'@

    $Case = New-SmokeCase 'cmd_direct' '{"cwd":"@{exe_dir}","command":["@{exe_dir}\\probe.cmd"]}'
    Write-Utf8NoBom (Join-Path $Case.Dir 'probe.cmd') $CmdDirect
    $Result = Invoke-SmokeCase 'cmd_direct' $Case.Exe
    Assert-ExitCode $Result 7
    Assert-Marker $Case.Dir 'cmd.out' 'cmd-direct-ok'

    $Case = New-SmokeCase 'bat_direct' '{"cwd":"@{exe_dir}","command":["@{exe_dir}\\probe.bat"]}'
    Write-Utf8NoBom (Join-Path $Case.Dir 'probe.bat') $BatDirect
    $Result = Invoke-SmokeCase 'bat_direct' $Case.Exe
    Assert-ExitCode $Result 8
    Assert-Marker $Case.Dir 'bat.out' 'bat-direct-ok'

    $Case = New-SmokeCase 'cmd_pathext' '{"cwd":"@{exe_dir}","command":["probe_cmd"]}'
    Write-Utf8NoBom (Join-Path $Case.Dir 'probe_cmd.cmd') $CmdPathext
    $Result = Invoke-SmokeCase 'cmd_pathext' $Case.Exe
    Assert-ExitCode $Result 15
    Assert-Marker $Case.Dir 'cmd_pathext.out' 'cmd-pathext-ok'

    $Case = New-SmokeCase 'console_cmd' '{"cwd":"@{exe_dir}","command":["C:\\Windows\\System32\\cmd.exe","/C","echo console-cmd-ok>console_cmd.out & exit /b 9"]}'
    $Result = Invoke-SmokeCase 'console_cmd' $Case.Exe
    Assert-ExitCode $Result 9
    Assert-Marker $Case.Dir 'console_cmd.out' 'console-cmd-ok'

    $Case = New-SmokeCase 'gui_wscript' '{"cwd":"@{exe_dir}","command":["C:\\Windows\\System32\\wscript.exe","//B","//Nologo","@{exe_dir}\\gui.vbs"]}'
    Write-Utf8NoBom (Join-Path $Case.Dir 'gui.vbs') $GuiVbs
    $Result = Invoke-SmokeCase 'gui_wscript' $Case.Exe
    Assert-ExitCode $Result 14
    Assert-Marker $Case.Dir 'gui.out' 'gui-wscript-ok'

    $Case = New-SmokeCase 'vbs_direct_arg0' '{"cwd":"@{exe_dir}","command":["@{exe_dir}\\direct.vbs"]}'
    Write-Utf8NoBom (Join-Path $Case.Dir 'direct.vbs') $DirectVbs
    $Result = Invoke-SmokeCase 'vbs_direct_arg0' $Case.Exe
    if ($Result.ExitCode -eq 16 -or (Test-Path (Join-Path $Case.Dir 'vbs_direct.out'))) {
        throw 'Unexpected direct VBS argv[0] support; launch scripts through wscript.exe or cscript.exe explicitly.'
    }

    Write-Host "Windows smoke tests passed in $Root"
} finally {
    if ($env:EXEWRAP_KEEP_SMOKE_DIR -ne '1') {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "Kept smoke directory: $Root"
    }
}
