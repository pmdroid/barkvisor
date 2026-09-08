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
            $vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
            $vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"
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

& swift package resolve
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$nioSsl = Get-ChildItem -Path ".build\checkouts" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -like "swift-nio-ssl*" } |
    Select-Object -First 1
if ($nioSsl) {
    $windowsImport = @"
#elseif canImport(ucrt)
import ucrt
import WinSDK
#else
#error("unsupported os")
#endif
"@
    Get-ChildItem -LiteralPath (Join-Path $nioSsl.FullName "Sources\NIOSSL") -Filter *.swift | ForEach-Object {
        $text = [System.IO.File]::ReadAllText($_.FullName)
        $next = [regex]::Replace(
            $text,
            '#else\r?\n#error\("unsupported os"\)\r?\n#endif',
            $windowsImport.TrimEnd()
        )
        if ($_.Name -eq "PosixPort.swift" -and $next.IndexOf("private func mlock(") -lt 0) {
            $stubs = @"
#if os(Windows)
private func mlock(_ addr: UnsafeRawPointer?, _ len: Int) -> CInt { 0 }
private func munlock(_ addr: UnsafeRawPointer?, _ len: Int) -> CInt { 0 }
private func lstat(_ path: UnsafePointer<CChar>?, _ buf: UnsafeMutablePointer<stat>?) -> CInt {
    stat(path, buf)
}
private func readlink(_ path: UnsafePointer<CChar>?, _ buf: UnsafeMutablePointer<CChar>?, _ bufsiz: Int) -> Int { -1 }
#endif

"@
            $needle = "private let sysFopen = fopen"
            $idx = $next.IndexOf($needle)
            if ($idx -ge 0) {
                $next = $next.Insert($idx, $stubs)
            }
        }
        if ($next -ne $text) {
            Set-ItemProperty -LiteralPath $_.FullName -Name IsReadOnly -Value $false
            [System.IO.File]::WriteAllText($_.FullName, $next)
        }
    }
}

& swift @all
exit $LASTEXITCODE
