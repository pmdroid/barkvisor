param(
    [string]$Source,
    [string]$PayloadDir,
    [string]$OutDir
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $PSCommandPath
$repo = (Resolve-Path (Join-Path $scriptDir "..\..")).Path
if (-not $PayloadDir) {
    $PayloadDir = Join-Path $scriptDir "payload"
}
if (-not $OutDir) {
    $OutDir = Join-Path $scriptDir "generated"
}

if (-not $Source) {
    $candidate = Join-Path $repo ".build\release\BarkVisorApp.exe"
    if (Test-Path -LiteralPath $candidate) {
        $Source = Split-Path -Parent $candidate
    } else {
        Write-Error "BarkVisorApp.exe not found. Build release or pass -Source."
        exit 1
    }
}

$frontend = $null
foreach ($cand in @(
        (Join-Path $repo "frontend\dist"),
        (Join-Path $repo "Sources\BarkVisor\Resources\frontend\dist"),
        (Join-Path $Source "share\barkvisor\frontend\dist")
    )) {
    if (Test-Path -LiteralPath (Join-Path $cand "index.html")) {
        $frontend = $cand
        break
    }
}
if (-not $frontend) {
    Write-Error "frontend/dist/index.html is missing. Build the SPA before harvesting the MSI payload."
    exit 1
}

$exeSource = Join-Path $Source "BarkVisor.exe"
if (-not (Test-Path -LiteralPath $exeSource)) {
    $exeSource = Join-Path $Source "BarkVisorApp.exe"
}
if (-not (Test-Path -LiteralPath $exeSource)) {
    Write-Error "BarkVisor.exe not found under $Source"
    exit 1
}

if (Test-Path -LiteralPath $PayloadDir) {
    Remove-Item -LiteralPath $PayloadDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $PayloadDir | Out-Null
Copy-Item -LiteralPath $exeSource -Destination (Join-Path $PayloadDir "BarkVisor.exe") -Force
Get-ChildItem -LiteralPath $Source -Filter *.dll -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $PayloadDir $_.Name) -Force
}
$spaDest = Join-Path $PayloadDir "share\barkvisor\frontend\dist"
New-Item -ItemType Directory -Force -Path $spaDest | Out-Null
Copy-Item -Path (Join-Path $frontend "*") -Destination $spaDest -Recurse -Force

& (Join-Path $scriptDir "harvest-wxs.ps1") -PayloadDir $PayloadDir -OutDir $OutDir

$candle = Get-Command candle.exe -ErrorAction SilentlyContinue
$light = Get-Command light.exe -ErrorAction SilentlyContinue
if ($candle -and $light) {
    $wxs = @(
        (Join-Path $scriptDir "barkvisor.wxs"),
        (Join-Path $OutDir "barkvisor-runtime.wxs"),
        (Join-Path $OutDir "barkvisor-spa.wxs")
    )
    & $candle.Source $wxs -out (Join-Path $OutDir "\")
    if ($LASTEXITCODE -ne 0) {
        Write-Error "candle.exe failed"
        exit 1
    }
    $wixobj = Get-ChildItem -LiteralPath $OutDir -Filter *.wixobj | ForEach-Object { $_.FullName }
    & $light.Source $wixobj -out (Join-Path $OutDir "BarkVisor.msi")
    if ($LASTEXITCODE -ne 0) {
        Write-Error "light.exe failed"
        exit 1
    }
}
