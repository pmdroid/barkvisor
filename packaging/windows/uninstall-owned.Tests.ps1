$owned = @(42)
$processes = @(
    [pscustomobject]@{ Id = 42; ProcessName = "qemu-system-x86_64" },
    [pscustomobject]@{ Id = 99; ProcessName = "qemu-system-x86_64" }
)
$selected = $processes | Where-Object { $_.ProcessName -like "qemu-system*" -and $owned -contains $_.Id }
if ($selected.Id -ne 42 -or @($selected).Count -ne 1) { throw "selected unrelated QEMU" }
Write-Output "owned-only"
