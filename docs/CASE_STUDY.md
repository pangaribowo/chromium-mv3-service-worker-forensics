# Technical Case Study: Chromium Manifest V3 Service Worker Forensics & Triage

**Incident ID:** INC-20261013-MV3-SW  
**Target Application:** Brave Browser (Chromium Engine) across 18 Multi-Profile Workspaces  
**Primary Affected Extension:** Tab Suspender v2.0.12 (`fiabciakcmgepblmdkmemdbbkilneeeh`, Manifest V3)  
**Host Environment:** Windows 10 Pro 22H2 (Build 19045, 64-bit) / Intel Core i5-6300U (2C/4T) / 8 GB DDR4 / 128 GB SSD

---

## 1. Incident Overview & Symptom Catalog

### 1.1 Primary Operational Failure
A power user operating **18 isolated Brave Browser profiles** (`Default` and `Profile 2` through `Profile 28`) reported that browser extensions—most critically **Tab Suspender v2.0.12** (`fiabciakcmgepblmdkmemdbbkilneeeh`)—repeatedly became unresponsive upon clicking the extension toolbar icon. Furthermore:
* Even after initial fixes appeared to work during an active session, **the exact same failure recurred the next morning** immediately after the user ran their desktop maintenance shortcut (`C:\Users\Administrator\Desktop\Optimize-Clean 2xmg.bat`) and opened Brave.
* Oddly, if the user closed Brave and opened it a *second* time without running the cleaner, the extension sometimes recovered on its own—only to die again after the next cleanup cycle.
* Across open profiles, hundreds of tabs were actively parked under `chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/park.html?...`, creating an acute data-loss hazard if anyone toggled or reinstalled the extension via `brave://extensions`.

---

## 2. Three-Layer Forensic Investigation

### 2.1 Finding 1: Windows EcoQoS / Efficiency Mode Process Starvation
Querying all active `brave.exe` processes via PowerShell (`Get-Process brave | Select-Object Id, PriorityClass, BasePriority`) revealed:
* **14 running `brave.exe` processes** were trapped in `PriorityClass = Idle` (`BasePriority = 4`).
* On Windows 10/11, Chromium applies `PROCESS_POWER_THROTTLING_EXECUTION_SPEED` (EcoQoS / Efficiency Mode) to background renderers and utility/service-worker processes.
* On a constrained 2-core / 4-thread Intel Core i5-6300U CPU, `BasePriority 4` threads are preempted by every `Normal` (`BasePriority 8`) and foreground-boosted (`BasePriority 10–15`) thread. When a Manifest V3 extension wakes from idle, its Service Worker (`worker.js`, which synchronously executes **30 `importScripts(...)` module loads**) suffers severe scheduling starvation.

**Remediation Applied:**
```powershell
powercfg /powerthrottling disable /path "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"
```
And programmatically elevated all `Idle` `brave.exe` processes back to `[System.Diagnostics.ProcessPriorityClass]::Normal`.

---

### 2.2 Finding 2: Multi-Megabyte Extension Storage Bloat (`IndexedDB` & `Local Extension Settings`)
Inspecting the on-disk storage directories for `fiabciakcmgepblmdkmemdbbkilneeeh` across all profiles uncovered substantial storage accumulation driven by Tab Suspender's **tab preview screenshot capture** (`IndexedDB` blobs) and historical tab state persistence (`Local Extension Settings` LevelDB):

| Profile | Initial Snapshot (`IndexedDB` + `Local Extension Settings`) | Live Audit (`Audit-BraveExtensionStorage.ps1`) | Underlying Cause |
| :--- | :---: | :---: | :--- |
| **`Profile 9`** | **36.93 MB** (456 blobs) + **17.59 MB** (>180k keys) | **67.89 MB** (388 blobs) + **22.85 MB** (**90.74 MB total**) | High-resolution tab preview blobs + uncompacted LevelDB SSTables |
| **`Profile 2`** | **15.79 MB** + **25.50 MB** (**41.29 MB total**) | **11.28 MB** (49 blobs) + **29.60 MB** (**40.88 MB total**) | Long-lived suspended tab history across multi-window sessions |
| **`Profile 6`** | **16.76 MB** + **13.73 MB** (**30.49 MB total**) | **15.73 MB** (64 blobs) + **5.27 MB** (**21.00 MB total**) | Tab screenshot blobs in `chrome-extension_fiabciak..._0.indexeddb.blob` |
| **`Profile 22`** | **14.30 MB** + **13.22 MB** (**27.52 MB total**) | **17.94 MB** (102 blobs) + **5.61 MB** (**23.55 MB total**) | Active multi-tab suspension state |
| **`Profile 10`** | **10.32 MB** + **14.88 MB** (**25.20 MB total**) | **7.14 MB** (1 blob) + **14.90 MB** (**22.04 MB total**) | Historical LevelDB key retention |

While storage bloat degraded Service Worker cold-boot I/O latency, it did not explain why the extension died deterministically after every `Optimize-Clean` execution—leading to Finding 3.

---

### 2.3 Finding 3 (Primary Root Cause): `Service Worker\Database` vs `Service Worker\ScriptCache` Desynchronization
Tracing the desktop shortcut `C:\Users\Administrator\Desktop\Optimize-Clean 2xmg.bat` revealed that it invoked:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Users\Administrator\Documents\Projects\optimize.ps1" -Mode Clean
```
Inspecting `Invoke-Clean` inside `optimize.ps1` exposed the exact culprit:
```powershell
# BUGGY PRE-FIX CODE:
$cacheDirs = @(
    "Cache", "Code Cache", "GPUCache",
    "DawnGraphiteCache", "DawnWebGPUCache", "GrShaderCache", "ShaderCache",
    "Service Worker\ScriptCache", "Service Worker\CacheStorage"
)
```
**Why This Broke Manifest V3 Extensions Even When Brave Was Closed:**
1. In Chromium's Service Worker subsystem, `<Profile>\Service Worker\Database` (a LevelDB store) holds the registration key `REG:chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/` (`type=1` / `kTypeValue`), which contains `resource_id` pointers to the compiled worker scripts stored in `<Profile>\Service Worker\ScriptCache` (a Chromium SimpleCache directory).
2. When `optimize.ps1 -Mode Clean` ran, it wiped `Service Worker\ScriptCache\*` and `Service Worker\CacheStorage\*`, **but left `Service Worker\Database` untouched**.
3. Comparing filesystem metadata across the 4 open broken profiles proved this conclusively:

| Profile | `Database\CURRENT` CreationTime | `ScriptCache\index` CreationTime | Desync Delta (Minutes) | `ScriptCache` Payloads | LevelDB `REG:chrome-extension://fiabciak...` Status |
| :--- | :---: | :---: | :---: | :---: | :---: |
| **`Profile 2`** | `2026-04-25 02:20:01` | `2026-10-13 08:52:25` | **+246,632.40 min** | `4` | **`type=0` (`kTypeDeletion`)** |
| **`Profile 22`** | `2026-07-23 16:35:34` | `2026-10-13 08:52:17` | **+117,616.71 min** | `10` | **`type=0` (`kTypeDeletion`)** |
| **`Profile 6`** | `2026-09-15 08:05:56` | `2026-10-13 08:20:22` | **+40,334.43 min** | `0` | **`type=0` (`kTypeDeletion`)** |
| **`Profile 9`** | `2026-09-15 15:54:54` | `2026-10-13 08:20:21` | **+39,865.46 min** | `0` | **`type=0` (`kTypeDeletion`)** |

4. When the user launched Brave after running `Optimize-Clean` (**Session 1**):
   * `ExtensionRegistrar` checked `Service Worker\Database`, saw `REG:chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/` (`type=1`), and assumed the worker was already installed.
   * When the user clicked the Tab Suspender icon, `ServiceWorkerScriptLoader` attempted to load `worker.js` from `ScriptCache` by its `resource_id`.
   * Because `ScriptCache` had been wiped by `optimize.ps1`, SimpleCache returned a disk cache miss (`ServiceWorkerStatusCode::kErrorDiskCache`).
   * Chromium responded to `kErrorDiskCache` by condemning the registration and writing a LevelDB deletion record (`type=0` / `kTypeDeletion`) into `Database\000003.log`.
   * For the remainder of Session 1, the Service Worker was dead and unregistered.
   * Only when the user closed Brave and started a **second session (Session 2)** did `ExtensionRegistrar` detect that `REG:chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/` was now `type=0` (deleted) and trigger `RE_REGISTER_ON_STATE_MISMATCH` to re-populate `ScriptCache`.

---

## 3. Remediation & Verification

### 3.1 Patching the Root Cause in `optimize.ps1`
1. Removed `"Service Worker\ScriptCache"` and `"Service Worker\CacheStorage"` from `$cacheDirs` for both Brave and Chrome in `optimize.ps1`.
2. Added an **atomic self-healing check** inside `optimize.ps1` (`Invoke-Clean`) so that if any closed profile exhibits `Database\CURRENT` vs `ScriptCache\index` desynchronization (or `0` payload files in `ScriptCache`), all three directories (`Database`, `ScriptCache`, and `CacheStorage`) are removed atomically while preserving `Local Extension Settings` and `IndexedDB`.

### 3.2 Executing `Fix-BraveExtensions.ps1` Across All 18 Profiles
We authored and executed `Fix-BraveExtensions.ps1` to scan binary LevelDB `.ldb` and `.log` files across all profiles:
* **14 Closed Profiles (`Profile 3, 7, 10, 11, 12, 13, 14, 16, 17, 18, 20, 21, 24, 28`):** Automatically healed on disk by atomically resetting `Service Worker\Database`, `ScriptCache`, and `CacheStorage` without touching extension user data.
* **4 Open Profiles (`Profile 2, 6, 9, 22`):** Detected as locked (`Database\LOCK` held by active `brave.exe` processes) with `Tab Suspender = type=0`. Guided the user to execute **`brave://restart`** in the address bar so Brave gracefully closes, releases the locks, re-registers the Service Workers, and restores all suspended `park.html` tabs without loss.

### 3.3 Automated Edge-Case Verification Suite
Verified `Fix-BraveExtensions.ps1` against a synthetic 5-profile test harness (`$env:TEMP\BraveSWTest_*`) testing:
1. `Profile 1` (Healthy `type=1` with synced `ScriptCache`) → **Preserved (`True`)**
2. `Profile 2` (`type=0` deletion tombstone in `.log` + `Local Extension Settings` user data) → **SW Reset & User Data Preserved (`True`)**
3. `Profile 3` (Timestamp desync between `Database\CURRENT` and `ScriptCache\index`) → **Detected & Reset (`True`)**
4. `Profile 4` (Active `Database\LOCK` held with `FileShare.None`) → **Skipped Safely & Flagged `[OPEN]` (`True`)**
5. `Profile 5` (Orphaned `ScriptCache` without `Database`) → **Cleaned (`True`)**
6. **Second Pass (Idempotency):** Reported `0` fixed and `4` healthy closed profiles (`True`).
