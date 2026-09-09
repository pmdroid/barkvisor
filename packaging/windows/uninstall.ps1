param(
    [switch]$PurgeData
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

Wait-BarkVisorServiceRemoved

Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like "qemu-system*"
} | ForEach-Object {
    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
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
