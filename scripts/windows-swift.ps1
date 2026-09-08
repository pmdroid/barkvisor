param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$SwiftArgs
)

$ErrorActionPreference = "Stop"

$inc = Join-Path ([System.IO.Path]::GetTempPath()) "barkvisor-win-unistd"
New-Item -ItemType Directory -Force -Path $inc | Out-Null

$unistd = @"
#ifndef BARKVISOR_WIN_UNISTD_H
#define BARKVISOR_WIN_UNISTD_H
#include <stdlib.h>
#include <io.h>
#include <stdio.h>
#endif
"@
Set-Content -LiteralPath (Join-Path $inc "unistd.h") -Value $unistd -Encoding ascii

$prefixPath = Join-Path $inc "barkvisor-win-prefix.h"
$prefix = @"
#ifndef BARKVISOR_WIN_PREFIX_H
#define BARKVISOR_WIN_PREFIX_H
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#include <time.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef locale_t
typedef void *locale_t;
#endif
char *strptime(const char *s, const char *f, struct tm *tm);
char *strptime_l(const char *s, const char *f, struct tm *tm, locale_t loc);
#ifdef __cplusplus
}
#endif
#endif
"@
Set-Content -LiteralPath $prefixPath -Value $prefix -Encoding ascii

$all = @()
if ($SwiftArgs) { $all += $SwiftArgs }
$all += @(
    "-Xcc", "-I$inc",
    "-Xcc", "-include",
    "-Xcc", $prefixPath,
    "-Xcxx", "-I$inc",
    "-Xcxx", "-include",
    "-Xcxx", $prefixPath
)
& swift @all
exit $LASTEXITCODE
