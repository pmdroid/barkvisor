param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SwiftArgs
)

$ErrorActionPreference = "Stop"

$inc = Join-Path ([System.IO.Path]::GetTempPath()) "barkvisor-win-unistd"
New-Item -ItemType Directory -Force -Path $inc | Out-Null
$header = @"
#ifndef BARKVISOR_WIN_UNISTD_H
#define BARKVISOR_WIN_UNISTD_H
#include <io.h>
#include <stdio.h>
#endif
"@
Set-Content -LiteralPath (Join-Path $inc "unistd.h") -Value $header -Encoding ascii

$all = @()
if ($SwiftArgs) { $all += $SwiftArgs }
$all += @(
    "-Xcc", "-I$inc",
    "-Xcc", "-DWIN32_LEAN_AND_MEAN",
    "-Xcc", "-D_WINSOCKAPI_",
    "-Xcxx", "-I$inc",
    "-Xcxx", "-DWIN32_LEAN_AND_MEAN",
    "-Xcxx", "-D_WINSOCKAPI_"
)
& swift @all
exit $LASTEXITCODE
