<#
.SYNOPSIS
    Fix-BraveExtensions - Memulihkan proses Brave & memperbaiki Service Worker ekstensi Manifest V3 (seperti Tab Suspender).
.PARAMETER CloseAndFixAll
    Jika diaktifkan, akan menutup proses Brave terlebih dahulu agar profil yang sedang terbuka juga dapat di-reset Service Worker Database-nya.
#>
param(
    [switch]$CloseAndFixAll,
    [string]$BraveUserDataPath = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
)

Write-Host "=== Brave Extension & Service Worker Health Check ===" -ForegroundColor Cyan

if ($CloseAndFixAll) {
    $runningBrave = Get-Process brave -ErrorAction SilentlyContinue
    if ($runningBrave) {
        Write-Host "[!] Menutup proses Brave agar seluruh profil dapat diperbaiki..." -ForegroundColor Yellow
        Stop-Process -Name brave -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
    }
}

# 1. Pastikan Power Throttling dinonaktifkan
$bravePath = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
if (Test-Path $bravePath) {
    powercfg /powerthrottling disable /path $bravePath 2>&1 | Out-Null
    Write-Host "[OK] Windows Power Throttling untuk Brave: Disabled (Never On)" -ForegroundColor Green
}

# 2. Cari semua proses Brave yang sedang tercekik di mode Idle (Efficiency Mode)
$idleProcs = @(Get-Process brave -ErrorAction SilentlyContinue | Where-Object { $_.PriorityClass -eq 'Idle' })
if ($idleProcs.Count -gt 0) {
    Write-Host "[!] Ditemukan $($idleProcs.Count) proses Brave dalam mode Idle/Efficiency. Memulihkan..." -ForegroundColor Yellow
    foreach ($p in $idleProcs) {
        try {
            $p.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::Normal
            Write-Host "    -> PID $($p.Id) dikembalikan ke prioritas Normal." -ForegroundColor Gray
        } catch {
            Write-Host "    -> Gagal mengubah PID $($p.Id): $_" -ForegroundColor Red
        }
    }
    Write-Host "[OK] Semua proses Brave berhasil dikembalikan ke performa Normal!" -ForegroundColor Green
} else {
    Write-Host "[OK] Tidak ada proses Brave yang tercekik (semua berjalan Normal)." -ForegroundColor Green
}

# 3. Periksa & Perbaiki sinkronisasi Service Worker Database dan ScriptCache di semua profil Brave
Write-Host "`n=== Memeriksa Service Worker Ekstensi di Profil Brave ===" -ForegroundColor Cyan
$braveBase = $BraveUserDataPath
$profiles = @(if (Test-Path $braveBase) { Get-ChildItem $braveBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Profile*" -or $_.Name -eq "Default" } })
$needleExt = [System.Text.Encoding]::ASCII.GetBytes("REG:chrome-extension://")
$needleAny = [System.Text.Encoding]::ASCII.GetBytes("REG:")

$fixedCount = 0
$healthyCount = 0
$openBrokenProfiles = @()

foreach ($prof in $profiles) {
    $swPath = Join-Path $prof.FullName "Service Worker"
    if (-not (Test-Path $swPath)) { continue }

    $dbPath = Join-Path $swPath "Database"
    $scPath = Join-Path $swPath "ScriptCache"
    $csPath = Join-Path $swPath "CacheStorage"

    $dbFiles = @(if (Test-Path $dbPath) { Get-ChildItem $dbPath -File -ErrorAction SilentlyContinue })
    if ((-not (Test-Path $dbPath)) -or ($dbFiles.Count -eq 0)) {
        if ((Test-Path $scPath) -or (Test-Path $csPath)) {
            if (Test-Path $scPath) { Remove-Item $scPath -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $csPath) { Remove-Item $csPath -Recurse -Force -ErrorAction SilentlyContinue }
            $fixedCount++
            Write-Host "[FIXED] $($prof.Name): Orphaned Service Worker ScriptCache/CacheStorage dibersihkan." -ForegroundColor Green
        } else {
            $healthyCount++
        }
        continue
    }

    # Cek apakah profil sedang terbuka (LOCK file terkunci oleh Brave)
    $lockPath = Join-Path $dbPath "LOCK"
    $isLocked = $false
    if (Test-Path $lockPath) {
        $fsLock = $null
        try {
            $fsLock = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch {
            $isLocked = $true
        } finally {
            if ($fsLock) { $fsLock.Dispose() }
        }
    }

    # Hitung file payload dan entri (_0) di ScriptCache (selain index dan the-real-index)
    $scFiles = @(Get-ChildItem $scPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @("index", "the-real-index") })
    $scPayloadCount = $scFiles.Count
    $scEntryCount = @($scFiles | Where-Object { $_.Name -like "*_0" }).Count

    # Cek apakah ScriptCache pernah terhapus setelah Database dibuat (mismatch CreationTime)
    $dbCurrentFile = Get-Item (Join-Path $dbPath "CURRENT") -ErrorAction SilentlyContinue
    $scIndexFile = Get-Item (Join-Path $scPath "index") -ErrorAction SilentlyContinue
    $scWipedAfterDb = $false
    if ($dbCurrentFile) {
        if (-not $scIndexFile) {
            $scWipedAfterDb = $true
        } elseif (($scIndexFile.CreationTime - $dbCurrentFile.CreationTime).TotalMinutes -gt 2) {
            $scWipedAfterDb = $true
        }
    }

    # Periksa status registrasi terakhir ekstensi di LevelDB (.ldb lalu .log)
    $extRegState = @{}
    $hasAnyRegistration = $false
    $levelDbFiles = @($dbFiles | Where-Object { $_.Extension -in ".ldb", ".log" } | Sort-Object Extension, Name)
    foreach ($lf in $levelDbFiles) {
        $fs = $null
        try {
            $fs = [System.IO.File]::Open($lf.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $bytes = New-Object byte[] $fs.Length
            [void]$fs.Read($bytes, 0, $bytes.Length)
        } catch {
            continue
        } finally {
            if ($fs) { $fs.Dispose() }
        }

        try {

            for ($i = 0; $i -le $bytes.Length - 4; $i++) {
                if ($bytes[$i] -eq $needleAny[0] -and $bytes[$i+1] -eq $needleAny[1] -and $bytes[$i+2] -eq $needleAny[2] -and $bytes[$i+3] -eq $needleAny[3]) {
                    $hasAnyRegistration = $true
                    if ($i -le $bytes.Length - 56) {
                        $matchExt = $true
                        for ($j = 0; $j -lt $needleExt.Length; $j++) {
                            if ($bytes[$i + $j] -ne $needleExt[$j]) { $matchExt = $false; break }
                        }
                        if ($matchExt) {
                            $extId = [System.Text.Encoding]::ASCII.GetString($bytes, $i + $needleExt.Length, 32)
                            if ($lf.Extension -eq ".log" -and $i -ge 2) {
                                $typeByte = [int]$bytes[$i - 2]
                                $keyLenByte = [int]$bytes[$i - 1]
                                if ($typeByte -in @(0, 1) -and $keyLenByte -ge 50 -and $keyLenByte -le 120) {
                                    $extRegState[$extId] = $typeByte
                                }
                            } elseif ($lf.Extension -eq ".ldb" -and -not $extRegState.ContainsKey($extId)) {
                                $extRegState[$extId] = 1
                            }
                        }
                    }
                }
            }
        } catch {}
    }

    $deletedExts = @($extRegState.GetEnumerator() | Where-Object { $_.Value -eq 0 } | ForEach-Object { $_.Key })
    $activeExts  = @($extRegState.GetEnumerator() | Where-Object { $_.Value -eq 1 } | ForEach-Object { $_.Key })

    # Tidak sinkron jika:
    # (a) Ada ekstensi (seperti Tab Suspender fiabciakcmgepblmdkmemdbbkilneeeh) yang statusnya DELETED (type=0) di Database, ATAU
    # (b) Database memiliki registrasi tetapi ScriptCache kosong (0 payload), ATAU
    # (c) Jumlah script (_0) di ScriptCache lebih sedikit daripada jumlah ekstensi aktif di Database, ATAU
    # (d) Database memiliki registrasi tetapi ScriptCache\index dibuat ulang jauh setelah Database\CURRENT (bekas terhapus script cleaner)
    $isDesynced = ($deletedExts.Count -gt 0) -or
                  ($hasAnyRegistration -and ($scPayloadCount -eq 0)) -or
                  ($activeExts.Count -gt 0 -and ($scEntryCount -lt $activeExts.Count)) -or
                  ($hasAnyRegistration -and $scWipedAfterDb)

    if (-not $isDesynced) {
        $healthyCount++
        continue
    }

    if (-not $isLocked) {
        # Profil sedang tertutup -> aman untuk menghapus Database, ScriptCache, dan CacheStorage
        # Catatan: Data ekstensi di Local Extension Settings, Sync Extension Settings, dan IndexedDB TIDAK disentuh.
        if (Test-Path $dbPath) { Remove-Item $dbPath -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $scPath) { Remove-Item $scPath -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path $csPath) { Remove-Item $csPath -Recurse -Force -ErrorAction SilentlyContinue }
        $fixedCount++
        Write-Host "[FIXED] $($prof.Name): Service Worker Database & ScriptCache di-reset (siap registrasi ulang otomatis)." -ForegroundColor Green
    } else {
        $openBrokenProfiles += $prof.Name
        $tsStatus = if ($extRegState.ContainsKey("fiabciakcmgepblmdkmemdbbkilneeeh")) { "type=$($extRegState['fiabciakcmgepblmdkmemdbbkilneeeh'])" } else { "tidak terdaftar" }
        Write-Host "[OPEN]  $($prof.Name): Profil sedang dibuka (ScriptCache=$scPayloadCount file, Tab Suspender=$tsStatus, ActiveExts=$($activeExts.Count), DeletedExts=$($deletedExts.Count))." -ForegroundColor Yellow
    }
}

if ($CloseAndFixAll -and $fixedCount -gt 0 -and (Test-Path $bravePath)) {
    Write-Host "`n[*] Membuka kembali Brave dengan memulihkan sesi tab terakhir (--restore-last-session)..." -ForegroundColor Cyan
    Start-Process -FilePath $bravePath -ArgumentList "--restore-last-session"
}

Write-Host "`n--- Ringkasan Perbaikan Service Worker ---" -ForegroundColor Cyan
Write-Host "  Profil diperbaiki (tertutup) : $fixedCount" -ForegroundColor Green
Write-Host "  Profil sudah sehat           : $healthyCount" -ForegroundColor Gray

if ($openBrokenProfiles.Count -gt 0) {
    Write-Host "  Profil masih terbuka         : $($openBrokenProfiles.Count) ($($openBrokenProfiles -join ', '))" -ForegroundColor Yellow
    Write-Host "`n[CARA MEMULIHKAN PROFIL YANG SEDANG TERBUKA TANPA KEHILANGAN TAB]" -ForegroundColor Yellow
    Write-Host "  1. Ketik " -NoNewline; Write-Host "brave://restart" -ForegroundColor Cyan -NoNewline; Write-Host " di address bar salah satu jendela Brave lalu tekan Enter."
    Write-Host "     (Brave akan otomatis me-restart seluruh jendela profil sekaligus dan memulihkan 100% tab + Tab Suspender.)" -ForegroundColor Gray
    Write-Host "  [!] PENTING: JANGAN mematikan toggle Tab Suspender di brave://extensions jika ada tab yang sedang di-suspend (park.html)," -ForegroundColor Red
    Write-Host "      karena mematikan ekstensi akan menutup tab park.html yang sedang terparkir!" -ForegroundColor Red
    Write-Host "  (Alternatif via script: powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -CloseAndFixAll)" -ForegroundColor Gray
} else {
    Write-Host "`nSemua profil Brave telah bersih dan siap digunakan dengan normal!" -ForegroundColor Green
}
Write-Host "=========================================================" -ForegroundColor Cyan

