# Architectural Decision Records (ADR)

This document records the key architectural decisions and rejected alternatives made during the triage and remediation of the Chromium Manifest V3 Service Worker outage across 18 Brave profiles.

---

## ADR-001: Exclude `Service Worker\ScriptCache` & `CacheStorage` from Routine Cache Scrubbers

* **Status:** Accepted & Implemented (`scripts/optimize.ps1`)
* **Date:** 2026-10-13
* **Context:**  
  Routine disk cleanup scripts (`optimize.ps1 -Mode Clean`) previously included `"Service Worker\ScriptCache"` and `"Service Worker\CacheStorage"` in the list of browser cache directories to purge. While this reclaimed disk space, it severed the invariant between `<Profile>\Service Worker\Database` (LevelDB registration metadata) and `<Profile>\Service Worker\ScriptCache` (SimpleCache worker bytecode), triggering `ServiceWorkerStatusCode::kErrorDiskCache` and killing Manifest V3 extension workers on the subsequent browser launch.
* **Decision:**  
  Remove `"Service Worker\ScriptCache"` and `"Service Worker\CacheStorage"` from the `$cacheDirs` array in `optimize.ps1` for both Brave and Chrome. Limit routine browser cache scrubbing strictly to stateless HTTP/GPU caches (`Cache`, `Code Cache`, `GPUCache`, `DawnGraphiteCache`, `DawnWebGPUCache`, `GrShaderCache`, `ShaderCache`).
* **Rejected Alternatives:**
  1. *Delete `Service Worker\Database` on every routine clean alongside `ScriptCache`:* Rejected because wiping `Service Worker\Database` on every routine cleanup also wipes Progressive Web App (PWA) Service Worker registrations and forces every installed extension across 18 profiles to re-compile and re-register all worker scripts on next launch.
  2. *Leave `ScriptCache` in `$cacheDirs` and rely on Chromium's second-session recovery:* Rejected because it breaks extensions on the first session after every cleanup run.

---

## ADR-002: Atomic Reset of `Database` + `ScriptCache` + `CacheStorage` Without Touching Extension Data Stores

* **Status:** Accepted & Implemented (`scripts/Fix-BraveExtensions.ps1` & `scripts/optimize.ps1`)
* **Date:** 2026-10-13
* **Context:**  
  14 closed Brave profiles and 4 open Brave profiles were already in a desynchronized state (`type=0` deletion tombstones in `Service Worker\Database` or wiped `ScriptCache` payloads). Meanwhile, those profiles contained valuable user extension state (hundreds of suspended tab URLs, whitelist rules, and session history) inside `<Profile>\Local Extension Settings\fiabciakcmgepblmdkmemdbbkilneeeh`, `<Profile>\Sync Extension Settings`, and `<Profile>\IndexedDB`.
* **Decision:**  
  When healing a desynchronized closed profile, atomically delete only the three ephemeral Service Worker runtime directories:
  * `<Profile>\Service Worker\Database`
  * `<Profile>\Service Worker\ScriptCache`
  * `<Profile>\Service Worker\CacheStorage`  
  Strictly preserve `Local Extension Settings`, `Sync Extension Settings`, and `IndexedDB`.
* **Rejected Alternatives:**
  1. *Reinstall the extension or clear all extension storage:* Rejected because deleting `Local Extension Settings` or uninstalling Tab Suspender permanently destroys the user's saved tab suspension lists, settings, and active `park.html` tabs.
  2. *Binary-patch LevelDB `.log` / `.ldb` files in place:* Rejected because modifying LevelDB records without updating CRC32C block checksums and sequence numbers corrupts the LevelDB manifest, whereas deleting the `Service Worker\Database` directory is natively supported by Chromium's `ServiceWorkerRegistry` as a clean-slate initialization.

---

## ADR-003: Mandate `brave://restart` Over `brave://extensions` Toggle for Open Profiles

* **Status:** Accepted & Documented in CLI Output and Runbooks
* **Date:** 2026-10-13
* **Context:**  
  On the 4 open Brave profiles (`Profile 2`, `Profile 6`, `Profile 9`, `Profile 22`), `Service Worker\Database\LOCK` is held exclusively (`FileShare.None`) by the active browser process. Standard troubleshooting advice suggests toggling an unresponsive extension off and on in `brave://extensions`.
* **Decision:**  
  Explicitly block and warn against toggling Tab Suspender off in `brave://extensions`, and instead instruct the operator to run **`brave://restart`** in the address bar (or use `Fix-BraveExtensions.ps1 -CloseAndFixAll`, which restarts Brave with `--restore-last-session`).
* **Rejected Alternatives:**
  1. *Toggle the extension off/on in `brave://extensions`:* Rejected because Chromium's `ExtensionService::UnloadExtension` immediately closes every open tab whose URL begins with `chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/park.html`, destroying hundreds of suspended tabs across open windows.
  2. *Force-delete locked LevelDB files while Brave is running:* Impossible on Windows NT due to mandatory kernel file locking on `Database\LOCK` and active `.ldb`/`.log` handles, and attempting partial deletion while the browser is open causes immediate in-memory vs on-disk state corruption.

---

## ADR-004: Dual-Layer EcoQoS Mitigation (OS Policy + Runtime Process Priority Elevation)

* **Status:** Accepted & Implemented (`scripts/Fix-BraveExtensions.ps1`)
* **Date:** 2026-10-13
* **Context:**  
  Even after disabling Windows Power Throttling at the executable level via `powercfg /powerthrottling disable /path "...\brave.exe"`, Chromium's internal `ProcessPriorityDelegate` on Windows can still invoke `SetPriorityClass(..., IDLE_PRIORITY_CLASS)` (`BasePriority = 4`) on backgrounded extension/renderer processes during a running session.
* **Decision:**  
  Implement both:
  1. Persistent OS-level power throttling exemption via `powercfg /powerthrottling disable /path "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe"`.
  2. Runtime process scanning (`Get-Process brave | Where-Object { $_.PriorityClass -eq 'Idle' }`) in `Fix-BraveExtensions.ps1` to immediately elevate any throttled `brave.exe` child processes to `ProcessPriorityClass::Normal`.
* **Rejected Alternatives:**
  1. *Rely solely on `powercfg /powerthrottling disable`:* Rejected because empirical testing during the session showed 4 newly backgrounded `brave.exe` processes re-entering `PriorityClass = Idle` via Chromium's internal priority delegate despite the `powercfg` exemption.
