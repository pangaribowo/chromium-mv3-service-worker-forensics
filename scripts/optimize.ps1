param(
    [ValidateSet("Status", "Clean", "Tune")]
    [string]$Mode = "Status"
)

function Write-Section($title) {
    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "  $title" -ForegroundColor Cyan
    Write-Host "==================================================" -ForegroundColor Cyan
}

function Write-Ok($msg) { Write-Host "  [OK] $msg" -ForegroundColor Green }
function Write-Del($msg) { Write-Host "  [DEL] $msg" -ForegroundColor Yellow }
function Write-Info($msg) { Write-Host "  [i] $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Red }

function Get-FolderSize($path) {
    if (-not (Test-Path $path)) { return 0 }
    $measure = Get-ChildItem $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
    if ($measure.Sum) { return $measure.Sum } else { return 0 }
}

function Format-Size($bytes) {
    if ($bytes -ge 1GB) { return "$([math]::Round($bytes/1GB, 2)) GB" }
    if ($bytes -ge 1MB) { return "$([math]::Round($bytes/1MB, 2)) MB" }
    return "$([math]::Round($bytes/1KB, 2)) KB"
}

function Invoke-Status {
    Write-Section "SYSTEM HEALTH REPORT"
    
    # Disk
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    $freeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
    $totalGB = [math]::Round($disk.Size / 1GB, 2)
    $pctFree = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 1)
    $diskColor = if ($freeGB -lt 10) { "Red" } elseif ($freeGB -lt 20) { "Yellow" } else { "Green" }
    
    Write-Host "  Disk C: " -NoNewline
    Write-Host "$freeGB GB free" -ForegroundColor $diskColor -NoNewline
    Write-Host " / $totalGB GB total ($pctFree% free)"
    
    # RAM
    $os = Get-CimInstance Win32_OperatingSystem
    $totalRAM = [math]::Round($os.TotalVisibleMemorySize / 1MB, 2)
    $freeRAM = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
    $usedRAM = [math]::Round($totalRAM - $freeRAM, 2)
    $pctRAM = [math]::Round(($usedRAM / $totalRAM) * 100, 1)
    $ramColor = if ($pctRAM -gt 85) { "Red" } elseif ($pctRAM -gt 70) { "Yellow" } else { "Green" }
    
    Write-Host "  RAM   : " -NoNewline
    Write-Host "$usedRAM GB used" -ForegroundColor $ramColor -NoNewline
    Write-Host " / $totalRAM GB total ($pctRAM%)"
    
    # CPU
    $cpu = Get-CimInstance Win32_Processor
    $cpuColor = if ($cpu.LoadPercentage -gt 80) { "Red" } elseif ($cpu.LoadPercentage -gt 50) { "Yellow" } else { "Green" }
    Write-Host "  CPU   : " -NoNewline
    Write-Host "$($cpu.LoadPercentage)% load" -ForegroundColor $cpuColor -NoNewline
    Write-Host " ($($cpu.Name.Trim()))"
    
    # Top 5 Memory-heavy processes
    Write-Section "TOP 5 MEMORY-HEAVY PROCESSES"
    Get-Process | Group-Object ProcessName | ForEach-Object {
        [PSCustomObject]@{
            ProcessName = $_.Name
            Instances = $_.Count
            "RAM(MB)" = [math]::Round(($_.Group | Measure-Object WorkingSet64 -Sum).Sum / 1MB, 1)
        }
    } | Sort-Object "RAM(MB)" -Descending | Select-Object -First 5 | Format-Table -AutoSize
    
    # Estimated cleanable cache
    Write-Section "ESTIMATED CLEANABLE CACHE"
    $totalCleanable = 0
    
    $targets = @(
        @{ Name = "Windows Temp"; Path = "$env:TEMP" },
        @{ Name = "System Temp"; Path = "C:\Windows\Temp" },
        @{ Name = "Delivery Optimization"; Path = "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache" },
        @{ Name = "Windows Update Cache"; Path = "C:\Windows\SoftwareDistribution\Download" },
        @{ Name = "npm cache"; Path = "$env:APPDATA\npm-cache" },
        @{ Name = "pnpm store"; Path = "$env:LOCALAPPDATA\pnpm\store" }
    )
    
    $braveBase = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    $braveProfiles = Get-ChildItem $braveBase -Directory -Filter "Profile*" -ErrorAction SilentlyContinue
    foreach ($bp in $braveProfiles) {
        $targets += @{ Name = "Brave Cache ($($bp.Name))"; Path = "$($bp.FullName)\Cache" }
    }
    
    foreach ($t in $targets) {
        $size = Get-FolderSize $t.Path
        if ($size -gt 0) {
            $totalCleanable += $size
            $col = if ($size -gt 100MB) { "Yellow" } else { "Gray" }
            Write-Host "  $($t.Name) : $(Format-Size $size)" -ForegroundColor $col
        }
    }
    
    Write-Host ""
    Write-Host "  Total estimated cleanable : $(Format-Size $totalCleanable)" -ForegroundColor Yellow
    Write-Host "  Run -Mode Clean to scrub safely." -ForegroundColor Gray
}

function Invoke-Clean {
    Write-Section "ROUTINE CACHE SCRUBBING"
    
    $freedTotal = 0
    
    # 1. User Temp (including Puppeteer profiles, Docker updates, Claude temp)
    Write-Info "Cleaning User Temp & test artifacts..."
    $before = Get-FolderSize $env:TEMP
    
    Get-ChildItem $env:TEMP -Directory -Filter "puppeteer_dev_chrome_profile-*" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $dockUp = Join-Path $env:TEMP "DockerDesktopUpdates"
    if (Test-Path $dockUp) { Remove-Item $dockUp -Recurse -Force -ErrorAction SilentlyContinue }
    $claudeT = Join-Path $env:TEMP "claude"
    if (Test-Path $claudeT) { Remove-Item $claudeT -Recurse -Force -ErrorAction SilentlyContinue }
    
    Get-ChildItem $env:TEMP -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $after = Get-FolderSize $env:TEMP
    $freed = $before - $after; if ($freed -gt 0) { $freedTotal += $freed }
    Write-Del "User Temp & Artifacts: $(Format-Size $freed)"
    
    # 2. System Temp
    $before = Get-FolderSize "C:\Windows\Temp"
    Get-ChildItem "C:\Windows\Temp" -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    $after = Get-FolderSize "C:\Windows\Temp"
    $freed = $before - $after; if ($freed -gt 0) { $freedTotal += $freed }
    Write-Del "System Temp: $(Format-Size $freed)"
    
    # 3. Delivery Optimization Cache
    $doCache = "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
    $before = Get-FolderSize $doCache
    Stop-Service "DoSvc" -Force -ErrorAction SilentlyContinue
    Remove-Item "$doCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    $freed = $before; if ($freed -gt 0) { $freedTotal += $freed }
    Write-Del "Delivery Optimization: $(Format-Size $freed)"
    
    # 4. Windows Update Download Cache
    $wuCache = "C:\Windows\SoftwareDistribution\Download"
    $before = Get-FolderSize $wuCache
    Stop-Service "wuauserv" -Force -ErrorAction SilentlyContinue
    Remove-Item "$wuCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Service "wuauserv" -ErrorAction SilentlyContinue
    $after = Get-FolderSize $wuCache
    $freed = $before - $after; if ($freed -gt 0) { $freedTotal += $freed }
    Write-Del "Windows Update Cache: $(Format-Size $freed)"
    
    # 5. Brave Browser Cache (all profiles)
    Write-Info "Cleaning Brave browser caches..."
    $braveBase = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    $braveFreed = 0
    $braveProfiles = Get-ChildItem $braveBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Profile*" -or $_.Name -eq "Default" }
    foreach ($bp in $braveProfiles) {
        # Note: Do NOT delete "Service Worker\ScriptCache" or "Service Worker\CacheStorage" alone,
        # as doing so desynchronizes Service Worker\Database and breaks Manifest V3 extensions (e.g., Tab Suspender).
        $cacheDirs = @("Cache", "Code Cache", "GPUCache", "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "ShaderCache")
        foreach ($cd in $cacheDirs) {
            $cPath = Join-Path $bp.FullName $cd
            if (Test-Path $cPath) {
                $size = Get-FolderSize $cPath
                Remove-Item "$cPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                $braveFreed += $size
            }
        }

        # Self-heal closed profiles if Service Worker\ScriptCache was previously wiped out of sync with Database
        $swPath = Join-Path $bp.FullName "Service Worker"
        $swDbPath = Join-Path $swPath "Database"
        $swScPath = Join-Path $swPath "ScriptCache"
        $swCsPath = Join-Path $swPath "CacheStorage"
        $dbCurrent = Get-Item (Join-Path $swDbPath "CURRENT") -ErrorAction SilentlyContinue
        if ($dbCurrent) {
            $scIndex = Get-Item (Join-Path $swScPath "index") -ErrorAction SilentlyContinue
            $scPayloads = @(if (Test-Path $swScPath) { Get-ChildItem $swScPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin @("index", "the-real-index") } })
            if ((-not $scIndex) -or ($scPayloads.Count -eq 0) -or (($scIndex.CreationTime - $dbCurrent.CreationTime).TotalMinutes -gt 2)) {
                $lockFile = Join-Path $swDbPath "LOCK"
                $isLocked = $false
                if (Test-Path $lockFile) {
                    $fsLock = $null
                    try {
                        $fsLock = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    } catch { $isLocked = $true }
                    finally { if ($fsLock) { $fsLock.Dispose() } }
                }
                if (-not $isLocked) {
                    if (Test-Path $swDbPath) { Remove-Item $swDbPath -Recurse -Force -ErrorAction SilentlyContinue }
                    if (Test-Path $swScPath) { Remove-Item $swScPath -Recurse -Force -ErrorAction SilentlyContinue }
                    if (Test-Path $swCsPath) { Remove-Item $swCsPath -Recurse -Force -ErrorAction SilentlyContinue }
                    Write-Ok "Re-synced Service Worker storage on closed profile ($($bp.Name))"
                }
            }
        } elseif ((Test-Path $swScPath) -or (Test-Path $swCsPath)) {
            if (Test-Path $swScPath) { Remove-Item $swScPath -Recurse -Force -ErrorAction SilentlyContinue }
            if (Test-Path $swCsPath) { Remove-Item $swCsPath -Recurse -Force -ErrorAction SilentlyContinue }
            Write-Ok "Cleaned orphaned Service Worker cache on closed profile ($($bp.Name))"
        }
    }
    $freedTotal += $braveFreed
    Write-Del "Brave Browser Cache: $(Format-Size $braveFreed)"
    
    # 6. Chrome Browser Cache (all profiles)
    $chromeBase = "$env:LOCALAPPDATA\Google\Chrome\User Data"
    $chromeFreed = 0
    $chromeProfiles = Get-ChildItem $chromeBase -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "Profile*" -or $_.Name -eq "Default" }
    foreach ($cp in $chromeProfiles) {
        # Exclude Service Worker\ScriptCache and Service Worker\CacheStorage to preserve MV3 extension registrations
        $cacheDirs = @("Cache", "Code Cache", "GPUCache")
        foreach ($cd in $cacheDirs) {
            $cPath = Join-Path $cp.FullName $cd
            if (Test-Path $cPath) {
                $size = Get-FolderSize $cPath
                Remove-Item "$cPath\*" -Recurse -Force -ErrorAction SilentlyContinue
                $chromeFreed += $size
            }
        }
    }
    $freedTotal += $chromeFreed
    Write-Del "Chrome Browser Cache: $(Format-Size $chromeFreed)"
    
    # 7. Package Manager Caches (npm, pnpm, pip)
    Write-Info "Cleaning Package Manager caches (npm, pnpm, pip)..."
    $pkgFreed = 0
    $pkgCaches = @(
        "$env:APPDATA\npm-cache",
        "$env:LOCALAPPDATA\npm-cache",
        "$env:LOCALAPPDATA\pnpm-cache"
    )
    foreach ($pc in $pkgCaches) {
        if (Test-Path $pc) {
            $size = Get-FolderSize $pc
            Remove-Item $pc -Recurse -Force -ErrorAction SilentlyContinue
            $pkgFreed += $size
        }
    }
    try { & pip cache purge 2>$null | Out-Null } catch {}
    $freedTotal += $pkgFreed
    Write-Del "Package Caches (npm/pnpm/pip): $(Format-Size $pkgFreed)"
    
    # 8. App Updater Pending Caches
    Write-Info "Cleaning application updater caches..."
    $updFreed = 0
    $updaterDirs = @(
        "$env:LOCALAPPDATA\antigravity-updater\pending",
        "$env:LOCALAPPDATA\@mendeley-internaldesktop-reference-manager-updater\pending",
        "$env:LOCALAPPDATA\obsidian-updater\pending",
        "$env:LOCALAPPDATA\@flowprompterdesktop-updater\pending"
    )
    foreach ($ud in $updaterDirs) {
        if (Test-Path $ud) {
            $size = Get-FolderSize $ud
            Remove-Item $ud -Recurse -Force -ErrorAction SilentlyContinue
            $updFreed += $size
        }
    }
    $freedTotal += $updFreed
    Write-Del "App Updater Caches: $(Format-Size $updFreed)"

    # 9. IDE Caches (VS Code, Cursor)
    Write-Info "Cleaning IDE caches..."
    $ideFreed = 0
    $ideCacheDirs = @(
        "$env:APPDATA\Code\CachedData",
        "$env:APPDATA\Code\CachedExtensionVSIXs",
        "$env:APPDATA\Code\Crashpad",
        "$env:APPDATA\Cursor\CachedData"
    )
    foreach ($ic in $ideCacheDirs) {
        if (Test-Path $ic) {
            $size = Get-FolderSize $ic
            Remove-Item "$ic\*" -Recurse -Force -ErrorAction SilentlyContinue
            $ideFreed += $size
        }
    }
    $freedTotal += $ideFreed
    Write-Del "IDE Caches: $(Format-Size $ideFreed)"

    # 10. Recycle Bin
    Write-Info "Scrubbing Recycle Bin..."
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Del "Recycle Bin scrubbed"
    
    Write-Section "CLEANUP COMPLETE"
    Write-Host "  Total Space Reclaimed : $(Format-Size $freedTotal)" -ForegroundColor Green
    
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
    Write-Host "  Current Free Storage  : $([math]::Round($disk.FreeSpace/1GB, 2)) GB" -ForegroundColor Green
}

function Invoke-Tune {
    Write-Section "SUBSYSTEM & BACKGROUND OPTIMIZATION"
    
    # Disable services
    $disableList = @(
        @{ Name = "DiagTrack"; Reason = "Microsoft Telemetry Daemon" },
        @{ Name = "MapsBroker"; Reason = "Offline Maps Manager" },
        @{ Name = "PhoneSvc"; Reason = "Phone Link Service" }
    )
    
    Write-Host ""
    foreach ($svc in $disableList) {
        $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($s -and $s.StartType -ne "Disabled") {
            Stop-Service $svc.Name -Force -ErrorAction SilentlyContinue
            Set-Service $svc.Name -StartupType Disabled
            Write-Ok "Disabled: $($svc.Name) ($($svc.Reason))"
        } elseif ($s) {
            Write-Info "Already disabled: $($svc.Name)"
        }
    }
    
    # Manual services
    $manualList = @(
        @{ Name = "SysMain"; Reason = "Superfetch" },
        @{ Name = "WSearch"; Reason = "Search Indexer" },
        @{ Name = "AESMService"; Reason = "Intel SGX" },
        @{ Name = "cplspcon"; Reason = "Intel HDCP" },
        @{ Name = "lfsvc"; Reason = "Geolocation" }
    )
    
    Write-Host ""
    foreach ($svc in $manualList) {
        $s = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
        if ($s -and $s.StartType -eq "Automatic") {
            Set-Service $svc.Name -StartupType Manual
            Write-Ok "Manual: $($svc.Name) ($($svc.Reason))"
        } elseif ($s) {
            Write-Info "Already manual/disabled: $($svc.Name)"
        }
    }
    
    # Disable scheduled tasks
    $taskList = @(
        "LenovoBatteryPartSalesMonthlyToast",
        "LenovoCompanionAppAddinDailyScheduleTask",
        "LenovoSupportHealthReportSchedule",
        "Lenovo.Vantage.SmartPerformance.MonthlyReport",
        "NVM for Windows Author Update Check",
        "NVM for Windows Node.js Current Update Check",
        "NVM for Windows Node.js LTS Update Check",
        "NVM for Windows Update Check",
        "MicrosoftEdgeUpdateTaskMachineCore",
        "MicrosoftEdgeUpdateTaskMachineUA",
        "Microsoft Compatibility Appraiser",
        "ProgramDataUpdater",
        "MapsUpdateTask"
    )
    
    Write-Host ""
    foreach ($task in $taskList) {
        $t = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        if ($t -and $t.State -ne "Disabled") {
            Disable-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue | Out-Null
            Write-Ok "Task disabled: $task"
        } elseif ($t) {
            Write-Info "Already disabled: $task"
        }
    }
    
    # Delivery Optimization P2P
    $doPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization"
    if (-not (Test-Path $doPath)) { New-Item -Path $doPath -Force | Out-Null }
    Set-ItemProperty -Path $doPath -Name "DODownloadMode" -Value 0 -Type DWord
    Write-Ok "Delivery Optimization P2P Disabled"
    
    # Edge background
    $edgePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
    if (-not (Test-Path $edgePolicyPath)) { New-Item -Path $edgePolicyPath -Force | Out-Null }
    Set-ItemProperty -Path $edgePolicyPath -Name "StartupBoostEnabled" -Value 0 -Type DWord
    Set-ItemProperty -Path $edgePolicyPath -Name "BackgroundModeEnabled" -Value 0 -Type DWord
    Write-Ok "Edge Startup Boost & Background Disabled"
    
    Write-Section "TUNING COMPLETE"
    Write-Host "  System configurations applied successfully." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   Windows Performance Optimizer" -ForegroundColor Cyan
Write-Host "   Mode: $Mode" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

switch ($Mode) {
    "Status" { Invoke-Status }
    "Clean"  { Invoke-Clean }
    "Tune"   { Invoke-Tune }
}

$nowStr = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host ""
Write-Host "  Completed at $nowStr" -ForegroundColor Gray
Write-Host ""
