# Chromium Manifest V3 Service Worker Forensics & Self-Healing Toolkit
### *LevelDB vs SimpleCache Desynchronization Triage, Windows EcoQoS Recovery & Multi-Profile Extension Auditing*

[![Platform](https://img.shields.io/badge/Platform-Windows%2010%20%7C%2011%20(64--bit)-0078D6?logo=windows)](https://microsoft.com/windows)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?logo=powershell)](https://github.com/PowerShell/PowerShell)
[![Engine](https://img.shields.io/badge/Browser%20Engine-Chromium%20%7C%20Brave%20MV3-FB542B?logo=brave)](https://brave.com)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Architecture](https://img.shields.io/badge/Subsystems-LevelDB%20%7C%20SimpleCache%20%7C%20EcoQoS-orange)]()

---

## 📌 Executive Summary & Problem Model

Modern Chromium-based browsers (Brave, Google Chrome, Microsoft Edge) enforce the **Manifest V3 (MV3)** extension architecture, replacing persistent background pages (`background.html`) with ephemeral **Service Workers** managed on disk by two tightly coupled storage engines inside `<Profile>\Service Worker\`:
1. **`Database\` (LevelDB):** Stores serialized registration state (`REG:chrome-extension://<32-char-id>/`) and internal `resource_id` pointers.
2. **`ScriptCache\` (Chromium SimpleCache):** Stores the physical worker script bodies (`worker.js`, `importScripts` modules, and V8 bytecode) referenced by `Database\`.

On multi-profile developer workstations (tested across **18 Brave profiles** on an **Intel Core i5-6300U / 8 GB RAM / Windows 10 Pro** host), three compounding failure modes caused critical Manifest V3 extensions—specifically **Tab Suspender v2.0.12** (`fiabciakcmgepblmdkmemdbbkilneeeh`)—to become completely unresponsive when clicked:

1. **The Split-Brain Cache Scrubbing Trap (`ServiceWorkerStatusCode::kErrorDiskCache`):**  
   System cleanup scripts (`optimize.ps1 -Mode Clean` invoked via `Optimize-Clean 2xmg.bat`) purged `Service Worker\ScriptCache` and `Service Worker\CacheStorage` while leaving `Service Worker\Database` intact. On the first browser launch after cleaning, `ExtensionRegistrar` saw an active registration (`type=1`) in LevelDB and skipped worker installation, but waking the Service Worker failed with `kErrorDiskCache` because the `ScriptCache` payloads were gone. Chromium then wrote a LevelDB deletion tombstone (`type=0` / `kTypeDeletion`) to `Database\*.log`, leaving the extension dead for the entire first session (recovering only on a second restart via `RE_REGISTER_ON_STATE_MISMATCH`).
2. **Windows NT EcoQoS / Efficiency Mode Thread Starvation:**  
   14 `brave.exe` subprocesses (including extension worker and renderer processes) were throttled to `PriorityClass = Idle` (`BasePriority = 4`), starving background IPC wakeups and synchronous `importScripts` initialization (30 modules) on a 2-core / 4-thread CPU.
3. **Multi-Megabyte Extension Storage Bloat (`IndexedDB` & `Local Extension Settings`):**  
   Tab preview screenshots (`IndexedDB` blobs) and uncompacted historical tab records (`Local Extension Settings` LevelDB) inflated single-extension storage to **54.52 MB – 90.74 MB** in `Profile 9` and **40.88 MB – 41.29 MB** in `Profile 2`.

This repository provides the **forensic post-mortem, LevelDB WriteBatch binary scanner, extension storage auditor, and atomic self-healing scripts** to permanently eliminate Manifest V3 Service Worker desynchronization without losing user extension data or suspended tabs.

---

## 📊 Empirical KPI & Forensic Measurement Matrix

> *DATA INTEGRITY NOTICE: All metrics below are real measurements captured directly from the 18 production Brave profiles and process tables during this troubleshooting session.*

| Metric / Subsystem Dimension | Pre-Remediation State (Measured) | Post-Remediation State (Measured) | Verification Source |
| :--- | :---: | :---: | :--- |
| **Routine Cleaner Behavior (`optimize.ps1`)** | Deleted `ScriptCache` & `CacheStorage` alone *(Induced Split-Brain)* | **Excludes `ScriptCache`/`CacheStorage` + Atomic Self-Heal** | `scripts/optimize.ps1` |
| **Closed Brave Profiles with Desynced SW** | **14 Closed Profiles** *(Wiped `ScriptCache` / Stale `Database`)* | **14 Closed Profiles Atomically Reset (`Healthy = 14`)** | `scripts/Fix-BraveExtensions.ps1` |
| **Open Brave Profiles (`Profile 2, 6, 9, 22`)** | `Tab Suspender = type=0` (`kTypeDeletion` in `.log`) | **Detected & Guided via `brave://restart` (0 Tab Loss)** | LevelDB `.log` WriteBatch scan |
| **`Database` vs `ScriptCache` Timestamp Delta** | **+39,865 min to +246,632 min** *(`DbCurrent` vs `ScIndex`)* | **0 min Desync on Healed Profiles** | Filesystem `CreationTime` audit |
| **Windows Power Throttling (`brave.exe`)** | Enabled / Dynamic *(14 processes at `Idle` / `BasePriority 4`)* | **`Disabled (Never On)` + Elevated to `Normal` (`BasePriority 8`)** | `powercfg /powerthrottling` & `Get-Process` |
| **Extension Data Preservation (`Local Extension Settings`)** | At risk if extension toggled/reinstalled | **100% Preserved across all 18 profiles** | Automated & Live Directory Audit |
| **`Profile 9` Tab Suspender Storage Footprint** | **36.93 MB – 67.89 MB** `IndexedDB` + **17.59 MB – 22.85 MB** `LocalExt` | **Audited & Preserved without corruption** | `scripts/Audit-BraveExtensionStorage.ps1` |
| **`Profile 2` Tab Suspender Storage Footprint** | **11.28 MB – 15.79 MB** `IndexedDB` + **25.50 MB – 29.60 MB** `LocalExt` | **Audited & Preserved without corruption** | `scripts/Audit-BraveExtensionStorage.ps1` |

---

## 🏗️ Visual Architecture & Failure/Recovery Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                     CAUSE: PARTIAL CACHE SCRUBBING TRAP                      │
│  optimize.ps1 (Old) ──► Deletes `Service Worker\ScriptCache\*`               │
│                     ──► Leaves  `Service Worker\Database\*` (type=1 Active)  │
└───────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│               SESSION 1: SPLIT-BRAIN FAILURE (EXTENSION DEAD)                │
│  1. Brave launches → ExtensionRegistrar reads `Database` (sees `type=1`)     │
│  2. User clicks Tab Suspender → ServiceWorkerScriptLoader reads `ScriptCache`│
│  3. `ScriptCache` misses (`ERR_CACHE_MISS`) → Raises `kErrorDiskCache`       │
│  4. Chromium writes `type=0` (`kTypeDeletion`) to `Database\000003.log`      │
│  5. Worker terminates permanently for Session 1 (Recovers only on Session 2) │
└───────────────────────────────────────┬──────────────────────────────────────┘
                                        │
                                        ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│           SOLUTION: ATOMIC SELF-HEALING & LEVELDB FORENSIC ENGINE            │
│  • Fix-BraveExtensions.ps1 scans `.ldb` & `.log` WriteBatches (`REG:...`)    │
│  • Detects `type=0` tombstones, 0-payload `ScriptCache`, or timestamp drift  │
│  • Closed Profiles: Atomically resets `Database` + `ScriptCache` + `Cache`   │
│  • Open Profiles: Enforces `brave://restart` (protects `park.html` tabs!)    │
│  • OS Scheduler: Disables `brave.exe` EcoQoS & elevates `Idle` → `Normal`    │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## 📂 Repository Tree & Quickstart Guide

```
.
├── README.md                              # Executive Presentation, Empirical KPIs & Quickstart
├── LICENSE                                # MIT License
├── .gitignore                             # Git ignore rules for logs and editor metadata
├── docs/                                  # Technical Deep-Dive & Architectural Hub
│   ├── CASE_STUDY.md                      # Incident Forensics, 18-Profile Triage & Verification
│   ├── ARCHITECTURE.md                    # LevelDB WriteBatch Layout, SimpleCache & EcoQoS Internals
│   └── ADR.md                             # Architectural Decision Records & Rejected Alternatives
├── scripts/                               # PowerShell Forensic, Recovery & Maintenance Tools
│   ├── Fix-BraveExtensions.ps1            # LevelDB WriteBatch scanner, SW reset & EcoQoS healer
│   ├── Audit-BraveExtensionStorage.ps1    # Multi-profile extension IndexedDB/LevelDB & SW auditor
│   └── optimize.ps1                       # Remediated workstation cleaner with SW self-healing
└── launchers/                             # 1-Click Batch Execution Wrappers
    ├── Fix-Brave-Extensions.bat           # 1-Click Brave MV3 Service Worker & EcoQoS recovery
    └── Audit-Brave-Storage.bat            # 1-Click multi-profile extension storage audit table
```

### Quickstart Commands

#### 1. Audit Extension Storage & Service Worker Registration State Across All Profiles
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Audit-BraveExtensionStorage.ps1
```

#### 2. Run Non-Destructive Service Worker Recovery & EcoQoS Elevation
Heals all closed Brave profiles, disables Windows Power Throttling on `brave.exe`, and elevates any `Idle` processes to `Normal`:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Fix-BraveExtensions.ps1
```

#### 3. Recover Open Profiles Without Losing Suspended (`park.html`) Tabs
If any profile is currently open and flagged as `[OPEN]`, type the following in Brave's address bar and press Enter:
```text
brave://restart
```
*(Or run `powershell -ExecutionPolicy Bypass -File .\scripts\Fix-BraveExtensions.ps1 -CloseAndFixAll` to automatically close Brave, heal all profiles, and relaunch with `--restore-last-session`.)*

> ⚠️ **CRITICAL OPERATIONAL WARNING:** Never toggle **Tab Suspender** off in `brave://extensions` while tabs are suspended! Disabling an extension immediately closes all open tabs matching `chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/park.html`. Always use `brave://restart`.

---

## 📖 Documentation Index (`docs/`)

* 📄 **[docs/CASE_STUDY.md](docs/CASE_STUDY.md)** — End-to-end forensic investigation, timestamp correlation between `Database\CURRENT` and `ScriptCache\index`, multi-profile storage bloat breakdown, and automated edge-case verification results.
* 🧠 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — Low-level internals of Chromium's `ServiceWorkerRegistry`, binary byte layout of LevelDB `.log` `WriteBatch` records (`0x01` vs `0x00`), the Two-Session Split-Brain State Machine, and Windows NT EcoQoS (`BasePriority 4`) scheduling mechanics.
* ⚖️ **[docs/ADR.md](docs/ADR.md)** — Architectural Decision Records documenting why `ScriptCache` must be excluded from routine scrubbers, why `Local Extension Settings` is preserved during atomic reset, and why `brave://restart` is mandated over `brave://extensions` toggling.

---

## 👤 Author & License Metadata

**Fatahillah Alif Pangaribowo**
* **GitHub:** [@pangaribowo](https://github.com/pangaribowo)
* **Email:** [fatahillahalifp04@gmail.com](mailto:fatahillahalifp04@gmail.com)
* **License:** MIT License — see [LICENSE](LICENSE) for full text.
