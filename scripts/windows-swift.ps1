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

$windowsOsImport = @"
#elseif canImport(ucrt)
import ucrt
import WinSDK
#else
#error("unsupported os")
#endif
"@.TrimEnd()
$windowsGlibcImport = @"
#elseif canImport(ucrt)
import ucrt
import WinSDK
#else
import Glibc
#endif
"@.TrimEnd()

Get-ChildItem -Path ".build\checkouts" -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $sources = Join-Path $_.FullName "Sources"
    if (-not (Test-Path -LiteralPath $sources)) { return }
    Get-ChildItem -LiteralPath $sources -Recurse -Filter *.swift | ForEach-Object {
        $text = [System.IO.File]::ReadAllText($_.FullName)
        $next = [regex]::Replace($text, '#else\r?\n#error\("unsupported os"\)\r?\n#endif', $windowsOsImport)
        $next = [regex]::Replace($next, '#else\r?\nimport Glibc\r?\n#endif', $windowsGlibcImport)
        $next = [regex]::Replace(
            $next,
            '#else\r?\n@preconcurrency import Glibc\r?\n#endif',
            $windowsGlibcImport
        )
        $next = $next.Replace("count: length)", "count: Int(length))")
        $next = $next.Replace("count: INET_ADDRSTRLEN", "count: Int(INET_ADDRSTRLEN)")
        $next = $next.Replace("count: INET6_ADDRSTRLEN", "count: Int(INET6_ADDRSTRLEN)")
        $next = $next.Replace("socklen_t(pointer.count)", "numericCast(pointer.count)")
        $next = $next.Replace("fflush(stdout)", "fflush(nil)")
        if ($_.Name -eq "WritePCAPHandler.swift") {
            $next = $next.Replace(".sin_addr.s_addr", ".sin_addr.S_un.S_addr")
            $next = $next.Replace("let fd = open(pathPtr, O_WRONLY | oflag, 0o600)", "let fd = pcap_open(pathPtr, O_WRONLY | oflag, 0o600)")
            $next = $next.Replace("let fd = _open(pathPtr, O_WRONLY | oflag, 0o600)", "let fd = pcap_open(pathPtr, O_WRONLY | oflag, 0o600)")
            $next = $next.Replace("let fd = pcappcap_open(pathPtr, O_WRONLY | oflag, 0o600)", "let fd = pcap_open(pathPtr, O_WRONLY | oflag, 0o600)")
            $next = $next.Replace("let sysWrite = write", "let sysWrite = pcap_write")
            if ($next.IndexOf("func pcap_open(") -lt 0) {
                $gtod = @"
#if os(Windows)
@_silgen_name("_open")
private func pcap_open(_ path: UnsafePointer<CChar>?, _ oflag: CInt, _ pmode: CInt) -> CInt
private func pcap_write(_ fd: CInt, _ buf: UnsafeRawPointer?, _ nbyte: Int) -> Int {
    Int(_write(fd, buf, UInt32(nbyte)))
}
private func gettimeofday(_ tv: UnsafeMutablePointer<timeval>?, _ tz: UnsafeMutableRawPointer?) -> CInt {
    var now = timeval()
    now.tv_sec = numericCast(time(nil) & 0x7fffffff)
    now.tv_usec = 0
    tv?.pointee = now
    return 0
}
#else
private let pcap_open = open
private let pcap_write = write
#endif

"@
                $next = $gtod + $next
            }
        }
        $next = $next.Replace(
            "cnioextras_z_deflateBound(&stream, UInt(inputBuffer.readableBytes))",
            "cnioextras_z_deflateBound(&stream, cnioextras_z_uLong(inputBuffer.readableBytes))"
        )
        $next = $next.Replace("statObj.st_mode & S_IFDIR", "CInt(statObj.st_mode) & CInt(S_IFDIR)")
        $next = $next.Replace("buffer.st_mode & S_IFMT) != S_IFLNK", "CInt(buffer.st_mode) & CInt(S_IFMT)) != 0")
        if ($_.Name -eq "PosixPort.swift" -and $next.IndexOf("private func mlock(") -lt 0) {
            $stubs = @"
#if os(Windows)
private var errno: CInt { ucrt._errno().pointee }
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
        if ($_.Name -eq "SSLContext.swift" -and $next.IndexOf("func opendir(") -lt 0) {
            $dirStubs = @"
#if os(Windows)
private let S_IFLNK: CInt = 0
private func opendir(_ path: String) -> OpaquePointer? { OpaquePointer(bitPattern: 1) }
private func readdir(_ dir: OpaquePointer) -> UnsafeMutablePointer<dirent>? { nil }
private func closedir(_ dir: OpaquePointer) {}
private struct dirent {
    var d_name: (CChar, CChar)
}
#endif

"@
            $next = $dirStubs + $next
        }
        if ($next -ne $text) {
            Set-ItemProperty -LiteralPath $_.FullName -Name IsReadOnly -Value $false
            [System.IO.File]::WriteAllText($_.FullName, $next)
        }
    }
}

& swift @all
exit $LASTEXITCODE
