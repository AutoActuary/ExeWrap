$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$root = Split-Path -Parent $PSScriptRoot
$out = Join-Path $root "diagnostics-out"
$tools = Join-Path $out "arm64-tools"
$release = Join-Path $out "x64-release"
$debug = Join-Path $out "x64-debug"
$x86 = Join-Path $out "x86-release"
$exact = Join-Path $out "exact-autory"
$dumps = Join-Path $out "dumps"
$results = Join-Path $out "results.txt"

Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $tools, $release, $debug, $x86, $exact, $dumps | Out-Null

function Copy-BuildOutput([string] $destination) {
    Copy-Item -Path (Join-Path $root "zig-out\bin\*") -Destination $destination -Force
}

function Build-ExeWrap([string] $target, [string] $mode, [string] $destination) {
    Push-Location $root
    try {
        & zig build "-Dtarget=$target" "-Doptimize=$mode"
        if ($LASTEXITCODE -ne 0) { throw "ExeWrap build failed: $target $mode" }
        Copy-BuildOutput $destination
    }
    finally {
        Pop-Location
    }
}

function Invoke-Probe([string] $name, [string] $file, [string[]] $arguments) {
    $stdout = Join-Path $out "$name.stdout.txt"
    $stderr = Join-Path $out "$name.stderr.txt"
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction SilentlyContinue

    $process = Start-Process -FilePath $file -ArgumentList $arguments -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $signed = [int32] $process.ExitCode
    $hex = "0x{0:X8}" -f ($signed -band 0xffffffff)
    "$name`t$signed`t$hex`t$file $($arguments -join ' ')" | Tee-Object -FilePath $results -Append
    if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout | Tee-Object -FilePath $results -Append }
    if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr | Tee-Object -FilePath $results -Append }
    return $signed
}

function Stamp([string] $launcher, [string] $output) {
    $stamper = Join-Path $tools "ExeWrap-stamper.exe"
    & $stamper --launcher $launcher --config (Join-Path $PSScriptRoot "repro.config.json") --subsystem console $output
    if ($LASTEXITCODE -ne 0) { throw "Stamp failed: $launcher" }
}

"Windows ARM ExeWrap diagnostic run" | Set-Content -LiteralPath $results -Encoding ascii
Get-ComputerInfo -Property WindowsProductName, WindowsVersion, OsBuildNumber, OsArchitecture | Format-List | Out-String | Add-Content -LiteralPath $results
"PROCESSOR_ARCHITECTURE=$env:PROCESSOR_ARCHITECTURE" | Add-Content -LiteralPath $results

Push-Location $root
try {
    & zig build-exe diagnostics/fake_python.zig -target x86_64-windows -O ReleaseSafe "-femit-bin=$out\fake-python-x64.exe"
    if ($LASTEXITCODE -ne 0) { throw "x64 fake Python build failed" }
    & zig build-exe diagnostics/fake_python.zig -target aarch64-windows -O ReleaseSafe "-femit-bin=$out\fake-python-arm64.exe"
    if ($LASTEXITCODE -ne 0) { throw "ARM64 fake Python build failed" }
}
finally {
    Pop-Location
}

Build-ExeWrap "aarch64-windows" "ReleaseSafe" $tools
Build-ExeWrap "x86_64-windows" "ReleaseSmall" $release
Build-ExeWrap "x86_64-windows" "Debug" $debug
Build-ExeWrap "x86-windows" "ReleaseSmall" $x86

Copy-Item -LiteralPath (Join-Path $out "fake-python-x64.exe") -Destination $release
Copy-Item -LiteralPath (Join-Path $out "fake-python-x64.exe") -Destination $debug
Copy-Item -LiteralPath (Join-Path $out "fake-python-x64.exe") -Destination $x86
Copy-Item -LiteralPath (Join-Path $out "fake-python-x64.exe") -Destination $tools

Stamp (Join-Path $release "ExeWrap-console.exe") (Join-Path $release "probe.exe")
Stamp (Join-Path $debug "ExeWrap-console.exe") (Join-Path $debug "probe-debug.exe")
Stamp (Join-Path $x86 "ExeWrap-console.exe") (Join-Path $x86 "probe-x86.exe")
Stamp (Join-Path $tools "ExeWrap-console.exe") (Join-Path $tools "probe-arm64.exe")

$autoryPath = Join-Path $exact "cli\autory.exe"
$fakePythonPath = Join-Path $exact "bin\python\python\python.exe"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $autoryPath), (Split-Path -Parent $fakePythonPath) | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "autory-v1.1.0.exe") -Destination $autoryPath
Copy-Item -LiteralPath (Join-Path $out "fake-python-x64.exe") -Destination $fakePythonPath

$expectedHash = "D9F3854557ECDEF52BB6A67FD544D605A0A7BE59CA1FCD2EE9CD86F77CED8E58"
$actualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $autoryPath).Hash
if ($actualHash -ne $expectedHash) { throw "Unexpected Autory launcher hash: $actualHash" }

Invoke-Probe "fake-x64-direct" (Join-Path $out "fake-python-x64.exe") @()
Invoke-Probe "fake-arm64-direct" (Join-Path $out "fake-python-arm64.exe") @()
Invoke-Probe "base-x64-unstamped" (Join-Path $release "ExeWrap-console.exe") @()
Invoke-Probe "generic-x64-release" (Join-Path $release "probe.exe") @("--version")
Invoke-Probe "generic-x64-debug" (Join-Path $debug "probe-debug.exe") @("--version")
Invoke-Probe "generic-x86-release" (Join-Path $x86 "probe-x86.exe") @("--version")
Invoke-Probe "generic-arm64" (Join-Path $tools "probe-arm64.exe") @("--version")
Invoke-Probe "exact-autory-v1.1" $autoryPath @("--version")

$procDumpZip = Join-Path $out "procdump.zip"
$procDumpDir = Join-Path $out "procdump"
Invoke-WebRequest -Uri "https://download.sysinternals.com/files/Procdump.zip" -OutFile $procDumpZip
Expand-Archive -LiteralPath $procDumpZip -DestinationPath $procDumpDir
$procDump = Join-Path $procDumpDir "procdump64a.exe"
if (Test-Path -LiteralPath $procDump) {
    & $procDump -accepteula -ma -e -x $dumps $autoryPath --version
    & $procDump -accepteula -ma -e -x $dumps (Join-Path $debug "probe-debug.exe") --version
}

Get-ChildItem -LiteralPath $out -Recurse | Select-Object FullName, Length | Format-Table -AutoSize | Out-String | Add-Content -LiteralPath $results
Get-Content -LiteralPath $results
