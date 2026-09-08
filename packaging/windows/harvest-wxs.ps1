param(
    [Parameter(Mandatory = $true)][string]$PayloadDir,
    [Parameter(Mandatory = $true)][string]$OutDir
)

$ErrorActionPreference = "Stop"

function XmlEscape([string]$Value) {
    return $Value.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;")
}

function New-WixId([string]$Prefix, [string]$Text) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        $hex = -join ($bytes | ForEach-Object { $_.ToString("X2") })
        return "$Prefix$($hex.Substring(0, 16))"
    } finally {
        $sha.Dispose()
    }
}

function New-WixGuid([string]$Text) {
    $md5 = [System.Security.Cryptography.MD5]::Create()
    try {
        $bytes = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("barkvisor.wix|$Text"))
        $hex = -join ($bytes | ForEach-Object { $_.ToString("x2") })
        return ($hex.Substring(0, 8) + "-" + $hex.Substring(8, 4) + "-" + $hex.Substring(12, 4) + "-" + $hex.Substring(16, 4) + "-" + $hex.Substring(20, 12)).ToUpper()
    } finally {
        $md5.Dispose()
    }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$PayloadDir = (Resolve-Path -LiteralPath $PayloadDir).Path

$runtime = New-Object System.Text.StringBuilder
[void]$runtime.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$runtime.AppendLine('<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">')
[void]$runtime.AppendLine('  <Fragment>')
[void]$runtime.AppendLine('    <ComponentGroup Id="BarkVisorRuntimeDlls" Directory="INSTALLDIR">')
Get-ChildItem -LiteralPath $PayloadDir -Filter *.dll -File -ErrorAction SilentlyContinue | ForEach-Object {
    $cid = New-WixId "Cdll" $_.Name
    $fid = New-WixId "Fdll" $_.Name
    $guid = New-WixGuid $_.Name
    $src = XmlEscape $_.FullName
    [void]$runtime.AppendLine("      <Component Id=`"$cid`" Guid=`"$guid`" Win64=`"yes`">")
    [void]$runtime.AppendLine("        <File Id=`"$fid`" Name=`"$(XmlEscape $_.Name)`" Source=`"$src`" KeyPath=`"yes`" />")
    [void]$runtime.AppendLine("      </Component>")
}
[void]$runtime.AppendLine("    </ComponentGroup>")
[void]$runtime.AppendLine("  </Fragment>")
[void]$runtime.AppendLine("</Wix>")
[System.IO.File]::WriteAllText((Join-Path $OutDir "barkvisor-runtime.wxs"), $runtime.ToString())

$spaRoot = Join-Path $PayloadDir "share\barkvisor\frontend\dist"
if (-not (Test-Path -LiteralPath (Join-Path $spaRoot "index.html"))) {
    Write-Error "payload share\barkvisor\frontend\dist\index.html is missing"
    exit 1
}

$spaComponents = New-Object System.Collections.Generic.List[string]
$spaBody = New-Object System.Text.StringBuilder

function Append-SpaDirectory {
    param(
        [string]$FsPath,
        [string]$Rel,
        [int]$Depth
    )
    $pad = "    " + ("  " * $Depth)
    Get-ChildItem -LiteralPath $FsPath -File | ForEach-Object {
        $key = Join-Path $Rel $_.Name
        $cid = New-WixId "Cspa" $key
        $fid = New-WixId "Fspa" $key
        $guid = New-WixGuid $key
        $src = XmlEscape $_.FullName
        $spaComponents.Add($cid)
        [void]$spaBody.AppendLine("$pad<Component Id=`"$cid`" Guid=`"$guid`" Win64=`"yes`">")
        [void]$spaBody.AppendLine("$pad  <File Id=`"$fid`" Name=`"$(XmlEscape $_.Name)`" Source=`"$src`" KeyPath=`"yes`" />")
        [void]$spaBody.AppendLine("$pad</Component>")
    }
    Get-ChildItem -LiteralPath $FsPath -Directory | ForEach-Object {
        $childRel = Join-Path $Rel $_.Name
        $did = New-WixId "Dspa" $childRel
        [void]$spaBody.AppendLine("$pad<Directory Id=`"$did`" Name=`"$(XmlEscape $_.Name)`">")
        Append-SpaDirectory -FsPath $_.FullName -Rel $childRel -Depth ($Depth + 1)
        [void]$spaBody.AppendLine("$pad</Directory>")
    }
}

Append-SpaDirectory -FsPath $spaRoot -Rel "." -Depth 0

$spa = New-Object System.Text.StringBuilder
[void]$spa.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$spa.AppendLine('<Wix xmlns="http://schemas.microsoft.com/wix/2006/wi">')
[void]$spa.AppendLine('  <Fragment>')
[void]$spa.AppendLine('    <DirectoryRef Id="SHAREDIST">')
[void]$spa.Append($spaBody.ToString())
[void]$spa.AppendLine('    </DirectoryRef>')
[void]$spa.AppendLine('    <ComponentGroup Id="BarkVisorSpaFiles">')
foreach ($cid in $spaComponents) {
    [void]$spa.AppendLine("      <ComponentRef Id=`"$cid`" />")
}
[void]$spa.AppendLine("    </ComponentGroup>")
[void]$spa.AppendLine("  </Fragment>")
[void]$spa.AppendLine("</Wix>")
[System.IO.File]::WriteAllText((Join-Path $OutDir "barkvisor-spa.wxs"), $spa.ToString())
