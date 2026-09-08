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

Get-ChildItem -LiteralPath $SourceDir -Filter "*.dll" -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $OutDir $_.Name) -Force
}

$dllDirs = @()
$swiftCmd = Get-Command swift -ErrorAction SilentlyContinue
if ($swiftCmd) {
    $dllDirs += Split-Path -Parent $swiftCmd.Source
}
if ($env:SDKROOT) {
    $sdkBin = Join-Path $env:SDKROOT "usr\bin"
    if (Test-Path -LiteralPath $sdkBin) {
        $dllDirs += $sdkBin
    }
}
foreach ($dir in ($dllDirs | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    Get-ChildItem -LiteralPath $dir -Filter "*.dll" -File -ErrorAction SilentlyContinue | ForEach-Object {
        $dest = Join-Path $OutDir $_.Name
        if (-not (Test-Path -LiteralPath $dest)) {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force
        }
    }
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
