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
#ifndef __ASSEMBLER__
#include <stdlib.h>
#include <io.h>
#include <stdio.h>
#endif
#endif
"@
Set-Content -LiteralPath (Join-Path $inc "unistd.h") -Value $unistd -Encoding ascii

$prefixPath = Join-Path $inc "barkvisor-win-prefix.h"
$prefix = @"
#ifndef BARKVISOR_WIN_PREFIX_H
#define BARKVISOR_WIN_PREFIX_H
#ifndef __ASSEMBLER__
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <stdlib.h>
#ifdef __cplusplus
extern "C" {
#endif
#ifndef locale_t
typedef void *locale_t;
#endif
struct tm;
char *strptime(const char *s, const char *f, struct tm *tm);
char *strptime_l(const char *s, const char *f, struct tm *tm, locale_t loc);
#ifdef __cplusplus
}
#endif
#endif
#endif
"@
Set-Content -LiteralPath $prefixPath -Value $prefix -Encoding ascii

$sqliteRoot = Join-Path ([System.IO.Path]::GetTempPath()) "barkvisor-win-sqlite"
$sqliteInc = Join-Path $sqliteRoot "include"
$sqliteLibDir = Join-Path $sqliteRoot "lib"
$sqliteHdr = Join-Path $sqliteInc "sqlite3.h"
$sqliteLib = Join-Path $sqliteLibDir "sqlite3.lib"
if (-not ((Test-Path -LiteralPath $sqliteHdr) -and (Test-Path -LiteralPath $sqliteLib))) {
    New-Item -ItemType Directory -Force -Path $sqliteInc | Out-Null
    New-Item -ItemType Directory -Force -Path $sqliteLibDir | Out-Null
    $work = Join-Path $sqliteRoot "src"
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $zip = Join-Path $work "sqlite.zip"
    $uri = "https://www.sqlite.org/2026/sqlite-amalgamation-3530400.zip"
    Invoke-WebRequest -Uri $uri -OutFile $zip -UseBasicParsing
    Expand-Archive -LiteralPath $zip -DestinationPath $work -Force
    $amal = Get-ChildItem -LiteralPath $work -Directory | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName "sqlite3.c")
    } | Select-Object -First 1
    if (-not $amal) { throw "sqlite amalgamation sqlite3.c missing" }
    Copy-Item -LiteralPath (Join-Path $amal.FullName "sqlite3.h") -Destination $sqliteHdr
    if (-not (Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
        if (Test-Path -LiteralPath $vswhere) {
            $arm64 = $env:PROCESSOR_ARCHITECTURE -eq "ARM64"
            $vsReq = if ($arm64) {
                "Microsoft.VisualStudio.Component.VC.Tools.ARM64"
            } else {
                "Microsoft.VisualStudio.Component.VC.Tools.x86.x64"
            }
            $vcvarsName = if ($arm64) { "vcvarsarm64.bat" } else { "vcvars64.bat" }
            $vs = & $vswhere -latest -products * -requires $vsReq -property installationPath
            $vcvars = Join-Path $vs "VC\Auxiliary\Build\$vcvarsName"
            if (Test-Path -LiteralPath $vcvars) {
                cmd.exe /c "`"$vcvars`" >nul && set" | ForEach-Object {
                    if ($_ -match '^([^=]+)=(.*)$') {
                        Set-Item -Path "Env:$($matches[1])" -Value $matches[2]
                    }
                }
            }
        }
    }
    $c = Join-Path $amal.FullName "sqlite3.c"
    $obj = Join-Path $work "sqlite3.obj"
    & cl.exe /nologo /c /O2 /Fo$obj /DSQLITE_ENABLE_FTS5 /DSQLITE_ENABLE_JSON1 /DSQLITE_ENABLE_SNAPSHOT /DSQLITE_THREADSAFE=1 /DSQLITE_OMIT_LOAD_EXTENSION $c
    if ($LASTEXITCODE -ne 0) { throw "cl sqlite3.c failed" }
    & lib.exe /nologo /out:$sqliteLib $obj
    if ($LASTEXITCODE -ne 0) { throw "lib sqlite3.lib failed" }
}

$all = @()
if ($SwiftArgs) { $all += $SwiftArgs }
$all += @(
    "--force-resolved-versions",
    "-Xcc", "-I$inc",
    "-Xcc", "-I$sqliteInc",
    "-Xcc", "-include",
    "-Xcc", $prefixPath,
    "-Xcxx", "-I$inc",
    "-Xcxx", "-I$sqliteInc",
    "-Xcxx", "-include",
    "-Xcxx", $prefixPath,
    "-Xlinker", "/LIBPATH:$sqliteLibDir"
)

& swift package config set-mirror --original-url https://github.com/apple/swift-nio-extras.git --mirror-url https://github.com/pmdroid/swift-nio-extras.git
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& swift package config set-mirror --original-url https://github.com/apple/swift-nio-ssl.git --mirror-url https://github.com/pmdroid/swift-nio-ssl.git
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& swift package config set-mirror --original-url https://github.com/vapor/websocket-kit.git --mirror-url https://github.com/pmdroid/websocket-kit.git
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& swift package config set-mirror --original-url https://github.com/swift-server/async-http-client.git --mirror-url https://github.com/pmdroid/async-http-client.git
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& swift package config set-mirror --original-url https://github.com/vapor/vapor.git --mirror-url https://github.com/pmdroid/vapor.git
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$resolvedPath = Join-Path (Get-Location) "Package.resolved"
if (Test-Path -LiteralPath $resolvedPath) {
    $resolved = [System.IO.File]::ReadAllText($resolvedPath)
    $resolved = $resolved.Replace("abcf5312eb8ed2fb11916078aef7c46b06f20813", "962499a2c269657f425fdab711e4d06f6ad6aaf1")
    $resolved = $resolved.Replace("df9c3406028e3297246e6e7081977a167318b692", "04510a23b581cd8111ddeccd3f6bdf236cfd1878")
    $resolved = $resolved.Replace("8666c92dbbb3c8eefc8008c9c8dcf50bfd302167", "3aaa8ccffd696b2109ed74a2608d3c58913daa0d")
    $resolved = $resolved.Replace("c5784ca81535cc6a92d900f84abd070dfb0e9392", "25e948d9bfa7cf0a135a7469cc730f34c00b01c6")
    $resolved = $resolved.Replace("a8db2dbda8b3cdc8a61bd35128590bd296e85563", "25532789b15adeb93098a5793bb06a3d39edce55")
    [System.IO.File]::WriteAllText($resolvedPath, $resolved)
}

& swift @all
exit $LASTEXITCODE
