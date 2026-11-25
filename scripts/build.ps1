# build.ps1 - Validate POSIX sh, UNIX LF, and package KernelSU module ZIP
param (
    [switch]$VerifyOnDevice,
    [string]$AdbPath = "C:\platform-tools\adb.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RootDir = Split-Path -Parent $PSScriptRoot
$ModuleDir = Join-Path $RootDir "module"
$DistDir = Join-Path $RootDir "dist"

if (-not (Test-Path $ModuleDir)) {
    Write-Output "[X] Module directory not found: $ModuleDir"
    exit 1
}

# Read module.prop metadata
$PropPath = Join-Path $ModuleDir "module.prop"
if (-not (Test-Path $PropPath)) {
    Write-Output "[X] Missing module.prop at $PropPath"
    exit 1
}

$ModuleId = ""
$ModuleVer = ""
foreach ($line in (Get-Content -Path $PropPath -Encoding UTF8)) {
    if ($line -match '^id=(.+)$') { $ModuleId = $Matches[1].Trim() }
    if ($line -match '^version=(.+)$') { $ModuleVer = $Matches[1].Trim() }
}
if ((-not $ModuleId) -or (-not $ModuleVer)) {
    Write-Output "[X] Invalid module.prop: missing id or version"
    exit 1
}

Write-Output "[*] Building module: $ModuleId ($ModuleVer)"

# 1. Check UNIX LF line endings on all .sh and .prop files
$TextFiles = Get-ChildItem -Path $ModuleDir -Recurse -File | Where-Object {
    ($_.Extension -eq ".sh") -or ($_.Extension -eq ".prop")
}

$CrLfErrors = 0
foreach ($f in $TextFiles) {
    $raw = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    if ($raw.Contains("`r")) {
        Write-Output "[X] CRLF detected in: $($f.FullName)"
        $CrLfErrors++
    }
}
if ($CrLfErrors -gt 0) {
    Write-Output "[!] Found $CrLfErrors file(s) with CRLF. Convert to UNIX LF before packaging."
    exit 1
}
Write-Output "[OK] All .sh and .prop files use UNIX LF ($($TextFiles.Count) files checked)"

# 2. Check for forbidden GNU Bashisms in .sh files
$ShFiles = Get-ChildItem -Path $ModuleDir -Recurse -File -Filter "*.sh"
$BashismPatterns = @(
    @{ Name = "set -o pipefail"; Regex = 'set\s+.*pipefail' },
    @{ Name = "double brackets [[ ]]"; Regex = '\[\[|\]\]' },
    @{ Name = "source keyword"; Regex = '(^|[;&|]\s*)source\s+' },
    @{ Name = "BASH_SOURCE"; Regex = 'BASH_SOURCE' },
    @{ Name = "combined redirect &>"; Regex = '(^|[^0-9])&>' },
    @{ Name = "function keyword"; Regex = '^\s*function\s+[A-Za-z_]' },
    @{ Name = "declare keyword"; Regex = '\bdeclare\s+' },
    @{ Name = "bash array assignment"; Regex = '[A-Za-z_][A-Za-z0-9_]*=\(' }
)

$BashismErrors = 0
foreach ($f in $ShFiles) {
    $lines = [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $ln = $lines[$i]
        $trimmed = $ln.TrimStart()
        if ($trimmed.StartsWith("#")) { continue }
        foreach ($pat in $BashismPatterns) {
            if ($ln -match $pat.Regex) {
                $lineNum = $i + 1
                Write-Output "[X] Bashism ($($pat.Name)) in $($f.Name):$lineNum -> $trimmed"
                $BashismErrors++
            }
        }
    }
}
if ($BashismErrors -gt 0) {
    Write-Output "[!] Found $BashismErrors bashism violation(s)."
    exit 1
}
Write-Output "[OK] Zero bashisms found across $($ShFiles.Count) shell scripts"

# 3. Verify WebUI required files exist
$WebRoot = Join-Path $ModuleDir "webroot"
$RequiredWeb = @("index.html", "styles.css", "app.js", "ksu-bridge.js")
foreach ($wf in $RequiredWeb) {
    $wp = Join-Path $WebRoot $wf
    if ((-not (Test-Path $wp)) -or ((Get-Item $wp).Length -eq 0)) {
        Write-Output "[X] Missing or empty WebUI asset: $wp"
        exit 1
    }
}
Write-Output "[OK] WebUI assets verified ($($RequiredWeb.Count) files)"

# 4. Optional Android /system/bin/sh -n check via ADB
if ($VerifyOnDevice) {
    if (-not (Test-Path $AdbPath)) {
        $adbLookup = Get-Command adb -ErrorAction SilentlyContinue
        if ($adbLookup) { $AdbPath = $adbLookup.Source }
    }
    if (-not (Test-Path $AdbPath)) {
        Write-Output "[WARN] ADB not found; skipping on-device sh -n check"
    } else {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & $AdbPath start-server 2>$null | Out-Null
        $devs = & $AdbPath devices 2>$null
        $ErrorActionPreference = $prevEap
        $hasDevice = ($devs -match '\tdevice\b').Count -gt 0
        if (-not $hasDevice) {
            Write-Output "[WARN] No authorized device connected; skipping on-device sh -n check"
        } else {
            $ShErrors = 0
            foreach ($f in $ShFiles) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $AdbPath
                $psi.Arguments = 'shell "sh -n"'
                $psi.UseShellExecute = $false
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                $sw = New-Object System.IO.StreamWriter($proc.StandardInput.BaseStream, $utf8NoBom)
                $content = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
                $sw.Write($content)
                $sw.Flush()
                $sw.Close()
                $errOut = $proc.StandardError.ReadToEnd()
                $proc.WaitForExit()
                if ($proc.ExitCode -ne 0) {
                    Write-Output "[X] Android sh -n failed for $($f.Name): $errOut"
                    $ShErrors++
                }
            }
            if ($ShErrors -gt 0) {
                Write-Output "[!] Android sh -n reported $ShErrors error(s)."
                exit 1
            }
            Write-Output "[OK] All $($ShFiles.Count) scripts passed Android /system/bin/sh -n"
        }
    }
}

# 5. Package ZIP with UNIX forward slashes
if (-not (Test-Path $DistDir)) {
    New-Item -ItemType Directory -Path $DistDir -Force | Out-Null
}
$ZipName = "${ModuleId}-${ModuleVer}.zip"
$ZipPath = Join-Path $DistDir $ZipName
if (Test-Path $ZipPath) {
    Remove-Item -Path $ZipPath -Force
}

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$Archive = [System.IO.Compression.ZipFile]::Open($ZipPath, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $AllFiles = Get-ChildItem -Path $ModuleDir -Recurse -File | Sort-Object FullName
    foreach ($file in $AllFiles) {
        $rel = $file.FullName.Substring($ModuleDir.Length + 1).Replace('\', '/')
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $Archive,
            $file.FullName,
            $rel,
            [System.IO.Compression.CompressionLevel]::Optimal
        ) | Out-Null
    }
} finally {
    $Archive.Dispose()
}

$ZipInfo = Get-Item $ZipPath
$SizeKB = [math]::Round($ZipInfo.Length / 1KB, 2)
$Hash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()

Write-Output "[OK] Package created: $ZipPath"
Write-Output "[OK] Size: $SizeKB KB | SHA256: $Hash"
exit 0
