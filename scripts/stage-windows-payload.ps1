param(
    [Parameter(Mandatory = $true)][string]$SourceDir,
    [Parameter(Mandatory = $true)][string]$FrontendDir,
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = "Stop"

$exe = Get-ChildItem -LiteralPath $SourceDir -Filter "BarkVisorApp.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $exe) {
    $exe = Get-ChildItem -LiteralPath $SourceDir -Filter "BarkVisor.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1
}
if (-not $exe) {
    Write-Error "BarkVisorApp.exe not found under $SourceDir"
    exit 1
}

$index = Join-Path $FrontendDir "index.html"
if (-not (Test-Path -LiteralPath $index)) {
    Write-Error "frontend index.html missing at $index"
    exit 1
}

if (Test-Path -LiteralPath $OutDir) {
    Remove-Item -LiteralPath $OutDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Copy-Item -LiteralPath $exe.FullName -Destination (Join-Path $OutDir "BarkVisor.exe") -Force

function Copy-DllsFromDir {
    param([string]$Dir)
    if (-not $Dir) { return }
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    Get-ChildItem -LiteralPath $Dir -Filter "*.dll" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $dest = Join-Path $OutDir $_.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        }
    }
}

Copy-DllsFromDir $SourceDir

$runtimeDirs = New-Object System.Collections.Generic.List[string]
function Add-RuntimeDir {
    param([string]$Dir)
    if (-not $Dir) { return }
    if (-not (Test-Path -LiteralPath $Dir)) { return }
    $core = Join-Path $Dir "swiftCore.dll"
    if (-not (Test-Path -LiteralPath $core)) { return }
    if (-not $runtimeDirs.Contains($Dir)) {
        $runtimeDirs.Add($Dir) | Out-Null
    }
}

foreach ($entry in (($env:PATH -split ';') | Where-Object { $_ })) {
    Add-RuntimeDir $entry.Trim('"')
}

$swiftRoots = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Swift"),
    (Join-Path $env:ProgramFiles "Swift")
)
$swiftCmd = Get-Command swift -ErrorAction SilentlyContinue
if ($swiftCmd) {
    $p = Split-Path -Parent $swiftCmd.Source
    for ($i = 0; $i -lt 6; $i++) {
        $p = Split-Path -Parent $p
        if (-not $p) { break }
        if ((Split-Path -Leaf $p) -eq "Swift") {
            $swiftRoots += $p
            break
        }
    }
    Add-RuntimeDir (Split-Path -Parent $swiftCmd.Source)
}
if ($env:SDKROOT) {
    Add-RuntimeDir (Join-Path $env:SDKROOT "usr\bin")
}
foreach ($root in ($swiftRoots | Select-Object -Unique)) {
    $runtimes = Join-Path $root "Runtimes"
    if (-not (Test-Path -LiteralPath $runtimes)) { continue }
    Get-ChildItem -LiteralPath $runtimes -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Add-RuntimeDir (Join-Path $_.FullName "usr\bin")
    }
}
foreach ($dir in $runtimeDirs) {
    Copy-DllsFromDir $dir
}

$crtNames = @(
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
    "concrt140.dll"
)
$crtDirs = New-Object System.Collections.Generic.List[string]
$crtDirs.Add((Join-Path $env:SystemRoot "System32")) | Out-Null
if ($env:VCToolsRedistDir) {
    $arch = "x64"
    if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq "Arm64") {
        $arch = "arm64"
    }
    $crtGlob = Join-Path $env:VCToolsRedistDir "$arch\Microsoft.VC*.CRT"
    Get-Item -Path $crtGlob -ErrorAction SilentlyContinue | ForEach-Object {
        $crtDirs.Add($_.FullName) | Out-Null
    }
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path -LiteralPath $vswhere) {
    $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Redist.14.Latest -property installationPath 2>$null
    if (-not $vs) {
        $vs = & $vswhere -latest -products * -property installationPath 2>$null
    }
    if ($vs) {
        $arch = "x64"
        if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -eq "Arm64") {
            $arch = "arm64"
        }
        $redistRoot = Join-Path $vs "VC\Redist\MSVC"
        if (Test-Path -LiteralPath $redistRoot) {
            Get-ChildItem -LiteralPath $redistRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $crt = Join-Path $_.FullName "$arch\Microsoft.VC143.CRT"
                if (Test-Path -LiteralPath $crt) {
                    $crtDirs.Add($crt) | Out-Null
                }
            }
        }
    }
}
foreach ($dir in ($crtDirs | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($name in $crtNames) {
        $src = Join-Path $dir $name
        $dest = Join-Path $OutDir $name
        if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $src -Destination $dest -Force
        }
    }
}

$required = @("swiftCore.dll", "msvcp140.dll", "vcruntime140.dll")
foreach ($name in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $OutDir $name))) {
        Write-Error "missing runtime DLL $name in $OutDir"
        exit 1
    }
}
$concurrency = Get-ChildItem -LiteralPath $OutDir -Filter "*Concurrency*.dll" -File -ErrorAction SilentlyContinue
if (-not $concurrency) {
    Write-Error "missing Swift concurrency DLL in $OutDir"
    exit 1
}

$spa = Join-Path $OutDir "share\barkvisor\frontend\dist"
New-Item -ItemType Directory -Force -Path $spa | Out-Null
Copy-Item -Path (Join-Path $FrontendDir "*") -Destination $spa -Recurse -Force
if (-not (Test-Path -LiteralPath (Join-Path $spa "index.html"))) {
    Write-Error "failed to stage share\barkvisor\frontend\dist\index.html"
    exit 1
}

Write-Host "Staged $OutDir"
Get-ChildItem -LiteralPath $OutDir -File | Select-Object -ExpandProperty Name
