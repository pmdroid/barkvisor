param(
    [string]$Prefix = $(Join-Path $env:ProgramFiles "BarkVisor"),
    [string]$DataDir = $(Join-Path $env:ProgramData "BarkVisor"),
    [string]$Source
)

$ErrorActionPreference = "Stop"

function Wait-BarkVisorServiceRemoved {
    param([int]$Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $svc = Get-Service -Name "BarkVisor" -ErrorAction SilentlyContinue
        if (-not $svc) {
            return
        }
        if ($svc.Status -ne "Stopped") {
            & sc.exe stop BarkVisor | Out-Null
        } else {
            & sc.exe delete BarkVisor | Out-Null
        }
        Start-Sleep -Milliseconds 250
    }
    if (Get-Service -Name "BarkVisor" -ErrorAction SilentlyContinue) {
        Write-Error "BarkVisor service did not stop or delete in time"
        exit 1
    }
}

$scriptDir = Split-Path -Parent $PSCommandPath
$repo = (Resolve-Path (Join-Path $scriptDir "..\..")).Path

$qemu = Join-Path $env:ProgramFiles "qemu\qemu-system-x86_64.exe"
if (-not (Test-Path -LiteralPath $qemu)) {
    Write-Error "QEMU is missing at $qemu. Install QEMU (winget install qemu) before BarkVisor. QEMU is not bundled."
    exit 1
}

if (-not $Source) {
    $candidate = Join-Path $repo ".build\release\BarkVisorApp.exe"
    if (Test-Path -LiteralPath $candidate) {
        $Source = Split-Path -Parent $candidate
    } else {
        $Source = $scriptDir
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
    Write-Error "frontend/dist/index.html is missing. Build the SPA so $Prefix\share\barkvisor\frontend\dist\index.html exists."
    exit 1
}

New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
$destShare = Join-Path $Prefix "share\barkvisor\frontend\dist"
New-Item -ItemType Directory -Force -Path $destShare | Out-Null
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $DataDir "run") | Out-Null

$exeSource = Join-Path $Source "BarkVisor.exe"
if (-not (Test-Path -LiteralPath $exeSource)) {
    $exeSource = Join-Path $Source "BarkVisorApp.exe"
}
if (-not (Test-Path -LiteralPath $exeSource)) {
    Write-Error "BarkVisor.exe not found under $Source"
    exit 1
}

Copy-Item -LiteralPath $exeSource -Destination (Join-Path $Prefix "BarkVisor.exe") -Force
Get-ChildItem -LiteralPath (Split-Path -Parent $exeSource) -Filter *.dll -File -ErrorAction SilentlyContinue | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $Prefix $_.Name) -Force
}
Copy-Item -Path (Join-Path $frontend "*") -Destination $destShare -Recurse -Force
if (-not (Test-Path -LiteralPath (Join-Path $destShare "index.html"))) {
    Write-Error "failed to install share\barkvisor\frontend\dist\index.html"
    exit 1
}

icacls $DataDir /inheritance:r | Out-Null
icacls $DataDir /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)F" | Out-Null
icacls $DataDir /grant:r "BUILTIN\Administrators:(OI)(CI)F" | Out-Null

$bin = Join-Path $Prefix "BarkVisor.exe"
Wait-BarkVisorServiceRemoved
& sc.exe create BarkVisor binPath= "`"$bin`"" start= auto obj= LocalSystem DisplayName= "BarkVisor"
if ($LASTEXITCODE -ne 0) {
    Write-Error "sc.exe create BarkVisor failed"
    exit 1
}
& sc.exe start BarkVisor
