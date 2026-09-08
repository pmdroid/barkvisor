param(
    [string]$Prefix = $(Join-Path $env:ProgramFiles "BarkVisor"),
    [string]$DataDir = $(Join-Path $env:ProgramData "BarkVisor"),
    [string]$Source
)

$ErrorActionPreference = "Stop"

$qemu = Join-Path $env:ProgramFiles "qemu\qemu-system-x86_64.exe"
if (-not (Test-Path -LiteralPath $qemu)) {
    Write-Error "QEMU is missing at $qemu. Install QEMU (winget install qemu) before BarkVisor. QEMU is not bundled."
    exit 1
}

if (-not $Source) {
    $Source = Split-Path -Parent $PSCommandPath
    $repo = Resolve-Path (Join-Path $Source "..\..")
    $candidate = Join-Path $repo ".build\release\BarkVisorApp.exe"
    if (Test-Path -LiteralPath $candidate) {
        $Source = Split-Path -Parent $candidate
    }
}

New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Prefix "share\barkvisor\frontend\dist") | Out-Null
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

$shareSource = Join-Path $Source "share\barkvisor"
if (Test-Path -LiteralPath $shareSource) {
    Copy-Item -LiteralPath $shareSource -Destination (Join-Path $Prefix "share\barkvisor") -Recurse -Force
}

icacls $DataDir /inheritance:r | Out-Null
icacls $DataDir /grant:r "NT AUTHORITY\SYSTEM:(OI)(CI)F" | Out-Null
icacls $DataDir /grant:r "BUILTIN\Administrators:(OI)(CI)F" | Out-Null

$bin = Join-Path $Prefix "BarkVisor.exe"
$existing = Get-Service -Name "BarkVisor" -ErrorAction SilentlyContinue
if ($existing) {
    & sc.exe stop BarkVisor | Out-Null
    & sc.exe delete BarkVisor | Out-Null
}
& sc.exe create BarkVisor binPath= "`"$bin`"" start= auto obj= LocalSystem DisplayName= "BarkVisor"
if ($LASTEXITCODE -ne 0) {
    Write-Error "sc.exe create BarkVisor failed"
    exit 1
}
& sc.exe start BarkVisor
