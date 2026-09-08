param(
    [switch]$PurgeData
)

$ErrorActionPreference = "Stop"

$service = Get-Service -Name "BarkVisor" -ErrorAction SilentlyContinue
if ($service) {
    & sc.exe stop BarkVisor | Out-Null
}

Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like "qemu-system*"
} | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
}

if ($service) {
    & sc.exe delete BarkVisor | Out-Null
}

$prefix = Join-Path $env:ProgramFiles "BarkVisor"
if (Test-Path -LiteralPath $prefix) {
    Remove-Item -LiteralPath $prefix -Recurse -Force -ErrorAction SilentlyContinue
}

if ($PurgeData) {
    $data = Join-Path $env:ProgramData "BarkVisor"
    if (Test-Path -LiteralPath $data) {
        Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
    }
}
