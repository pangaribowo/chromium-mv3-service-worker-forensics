<#
.SYNOPSIS
    Audit-BraveExtensionStorage - Forensic auditor for Chromium/Brave Manifest V3 Service Worker health
    and extension storage bloat (IndexedDB + Local Extension Settings) across all profiles.
.PARAMETER ExtensionId
    Target 32-character Chromium extension ID to inspect (default: fiabciakcmgepblmdkmemdbbkilneeeh / Tab Suspender).
.PARAMETER BraveUserDataPath
    Path to Brave User Data directory.
#>
param(
    [string]$ExtensionId = "fiabciakcmgepblmdkmemdbbkilneeeh",
    [string]$BraveUserDataPath = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
)

function Get-DirStats($path) {
    if (-not (Test-Path $path)) { return @{ Bytes = 0L; Files = 0 } }
    $files = @(Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue)
    $sum = ($files | Measure-Object Length -Sum).Sum
    if (-not $sum) { $sum = 0L }
    return @{ Bytes = [long]$sum; Files = $files.Count }
}

Write-Host "=== Chromium / Brave Extension Storage & Service Worker Forensic Audit ===" -ForegroundColor Cyan
Write-Host "Target Extension ID : $ExtensionId" -ForegroundColor Gray
Write-Host "User Data Path      : $BraveUserDataPath`n" -ForegroundColor Gray

if (-not (Test-Path $BraveUserDataPath)) {
    Write-Host "[!] User Data path not found: $BraveUserDataPath" -ForegroundColor Yellow
    exit 0
}

$profiles = @(Get-ChildItem $BraveUserDataPath -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Profile*" -or $_.Name -eq "Default" })
$latin1 = [System.Text.Encoding]::GetEncoding(28591)
$rxLogTarget = [regex]::new("REG:chrome-extension://$([regex]::Escape($ExtensionId))", [System.Text.RegularExpressions.RegexOptions]::Compiled)
$rxLdbTarget = [regex]::new("(?<![a-z])$([regex]::Escape($ExtensionId))(?![a-z])", [System.Text.RegularExpressions.RegexOptions]::Compiled)

$results = @()

foreach ($prof in $profiles) {
    $idbBlobPath = Join-Path $prof.FullName "IndexedDB\chrome-extension_${ExtensionId}_0.indexeddb.blob"
    $idbLdbPath  = Join-Path $prof.FullName "IndexedDB\chrome-extension_${ExtensionId}_0.indexeddb.leveldb"
    $lesPath     = Join-Path $prof.FullName "Local Extension Settings\$ExtensionId"
    $swDbPath    = Join-Path $prof.FullName "Service Worker\Database"
    $swScPath    = Join-Path $prof.FullName "Service Worker\ScriptCache"

    $idbBlob = Get-DirStats $idbBlobPath
    $idbLdb  = Get-DirStats $idbLdbPath
    $les     = Get-DirStats $lesPath

    $idbTotalMB = [math]::Round(($idbBlob.Bytes + $idbLdb.Bytes) / 1MB, 2)
    $lesTotalMB = [math]::Round($les.Bytes / 1MB, 2)
    $totalMB    = [math]::Round($idbTotalMB + $lesTotalMB, 2)

    # Check Service Worker status
    $swStatus = "No-SW-Dir"
    $scPayloads = 0
    if (Test-Path (Join-Path $prof.FullName "Service Worker")) {
        $scFiles = @(if (Test-Path $swScPath) { Get-ChildItem $swScPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @("index", "the-real-index") } })
        $scPayloads = $scFiles.Count

        $dbCurrentPath = Join-Path $swDbPath "CURRENT"
        if ((-not (Test-Path $swDbPath)) -or (-not (Test-Path $dbCurrentPath))) {
            $swStatus = "Clean/Reset (Ready)"
        } else {
            $regType = -1
            $dbFiles = @(Get-ChildItem $swDbPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in ".ldb", ".log" } | Sort-Object Extension, Name)
            foreach ($lf in $dbFiles) {
                $fs = $null
                try {
                    $fs = [System.IO.File]::Open($lf.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    $bytes = New-Object byte[] $fs.Length
                    [void]$fs.Read($bytes, 0, $bytes.Length)
                } catch { continue }
                finally { if ($fs) { $fs.Dispose() } }

                $rawText = $latin1.GetString($bytes)
                if ($lf.Extension -eq ".ldb") {
                    if ($rxLdbTarget.IsMatch($rawText) -and $regType -eq -1) {
                        $regType = 1
                    }
                } elseif ($lf.Extension -eq ".log") {
                    foreach ($m in $rxLogTarget.Matches($rawText)) {
                        $i = $m.Index
                        if ($i -ge 2) {
                            $t = [int]$bytes[$i - 2]
                            $k = [int]$bytes[$i - 1]
                            if ($t -in @(0, 1) -and $k -ge 50 -and $k -le 120) {
                                $regType = $t
                            }
                        }
                    }
                }
            }
            $swStatus = switch ($regType) {
                0 { "DELETED (type=0)" }
                1 { "ACTIVE (type=1)" }
                default { "Unregistered" }
            }
        }
    }

    if ($totalMB -gt 0 -or $swStatus -ne "No-SW-Dir") {
        $results += [PSCustomObject]@{
            Profile          = $prof.Name
            "IndexedDB(MB)"  = $idbTotalMB
            BlobCount        = $idbBlob.Files
            "LocalExt(MB)"   = $lesTotalMB
            "TotalExt(MB)"   = $totalMB
            SWRegistration   = $swStatus
            ScriptCacheFiles = $scPayloads
        }
    }
}

$results | Sort-Object "TotalExt(MB)" -Descending | Format-Table -AutoSize
