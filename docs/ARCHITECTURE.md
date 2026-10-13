# Under-the-Hood Architecture: Chromium Service Worker Storage & Windows EcoQoS

This document details the low-level storage formats, state machines, binary record layouts, and OS scheduling mechanics underlying Manifest V3 extension failures in Chromium-based browsers (Brave, Chrome, Edge).

---

## 1. Chromium `ServiceWorkerRegistry` & Dual-Store Architecture

In Chromium's `content/browser/service_worker/` implementation, Manifest V3 extension background scripts run as ephemeral Service Workers rather than persistent DOM background pages. Persisting a Service Worker across browser restarts requires two separate storage subsystems inside `<Profile>\Service Worker\` to remain strictly consistent:

```
┌────────────────────────────────────────────────────────────────────────────┐
│                       CHROMIUM BROWSER PROCESS                             │
│                                                                            │
│  ┌────────────────────────────────────┐   ┌─────────────────────────────┐  │
│  │   extensions::ExtensionRegistrar   │──►│ content::ServiceWorker      │  │
│  │   Checks MV3 registration state    │   │ Registry & StorageControl   │  │
│  └────────────────────────────────────┘   └──────┬───────────────┬──────┘  │
│                                                  │               │         │
│                     Metadata Read/Write (Mojo)   │               │ Disk I/O│
│                                                  ▼               ▼         │
│  ┌───────────────────────────────────────────────┐ ┌─────────────────────┐ │
│  │ <Profile>\Service Worker\Database\ (LevelDB)  │ │ ScriptCache\        │ │
│  │ • 000003.log (Write-Ahead Log WriteBatches)   │ │ (SimpleCache)       │ │
│  │ • 000005.ldb (Compacted SSTable Blocks)       │ │ • index             │ │
│  │ • Key: REG:chrome-extension://<32-char-id>/   │ │ • the-real-index    │ │
│  │ • Val: ServiceWorkerRegistrationData Protobuf │ │ • <res_id>_0 (Code) │ │
│  │   └──► Contains resource_id list [101..131] ──┼─┼─► <res_id>_1 (V8)   │ │
│  └───────────────────────────────────────────────┘ └─────────────────────┘ │
└────────────────────────────────────────────────────────────────────────────┘
```

### 1.1 LevelDB Write-Ahead Log (`.log`) Binary Record Layout
When `ServiceWorkerDatabase` mutates a registration (either registering an extension worker or deleting a corrupted one), it commits a LevelDB `WriteBatch` to `<Profile>\Service Worker\Database\<seq>.log`.

Inside the `.log` file, each `WriteBatch` contains a 12-byte header (8-byte sequence number + 4-byte record count) followed by contiguous entry records:

```
Byte Offset:   [i - 2]          [i - 1]          [i ... i + 22]              [i + 23 ... i + 54]
             ┌────────────────┬────────────────┬───────────────────────────┬──────────────────────────┐
Field:       │ ValueType (1B) │ KeyLength (1B) │ Prefix (23 Bytes)         │ Extension ID (32 Bytes)  │
             ├────────────────┼────────────────┼───────────────────────────┼──────────────────────────┤
Active Put:  │ 0x01 (Value)   │ 0x38 (56)      │ "REG:chrome-extension://" │ "fiabciakcmgepblmdk..."  │
Tombstone:   │ 0x00 (Deleted) │ 0x38 (56)      │ "REG:chrome-extension://" │ "fiabciakcmgepblmdk..."  │
             └────────────────┴────────────────┴───────────────────────────┴──────────────────────────┘
```

* **`ValueType = 0x01` (`leveldb::kTypeValue`):** The registration is active; followed by the varint value length and serialized `ServiceWorkerRegistrationData` protobuf.
* **`ValueType = 0x00` (`leveldb::kTypeDeletion`):** A deletion tombstone appended when Chromium invalidates and unregisters the Service Worker (e.g., upon encountering `ServiceWorkerStatusCode::kErrorDiskCache`). No value payload follows a `0x00` record.

### 1.2 LevelDB SSTable (`.ldb`) Prefix/Snappy Compression vs `.log` Precedence
In compacted LevelDB SSTable files (`*.ldb`, such as `Profile 2\Service Worker\Database\000009.ldb`), LevelDB stores keys in lexicographical order (`ID_TO_ORIGIN:...`, `INIT_DATA_TYPE:...`, `REG:chrome-extension://...`, `REG:https://...`, `RES:...`, `UNIQUE_ORIGIN:chrome-extension://...`) and applies two layers of compression within each SSTable data block:
1. **Restart-Block Prefix Delta Encoding (`shared_bytes`):** Adjacent keys sharing a common prefix omit the repeated prefix bytes (`"REG:"` or `"REG:chrome-extension://"`).
2. **Snappy LZ77 Block Compression:** Because `"REG:"` and `"chrome-extension://"` already appear earlier in the block (e.g., under `ID_TO_ORIGIN:` and `UNIQUE_ORIGIN:`), Snappy replaces subsequent `"REG:chrome-extension://"` occurrences with 2-byte LZ77 copy back-references. Consequently, a real compacted `.ldb` file (`000009.ldb`, 10,853 bytes, 9 registered extensions) contains **zero** literal occurrences of the 23-byte string `"REG:chrome-extension://"`, while preserving the high-entropy 32-character mpdecimal SHA-256 extension IDs (`[a-p]{32}`) as literal ASCII sequences.

During forensic scanning (`scripts/Fix-BraveExtensions.ps1`, `scripts/Audit-BraveExtensionStorage.ps1`, and `Repair-ChromiumServiceWorker` in `scripts/optimize.ps1`):
1. Compacted SSTable files (`.ldb`) are decoded using 1-to-1 ISO-8859-1 (Latin1) byte-to-char mapping and scanned first in ascending order via compiled regex `(?<![a-z])([a-p]{32})(?![a-z])` to establish baseline extension registrations (`type = 1`).
2. Uncompacted Write-Ahead Log files (`.log`) are scanned second in ascending order via compiled regex `REG:chrome-extension://([a-p]{32})`, inspecting `ValueType` at `[offset - 2]` and `KeyLength` at `[offset - 1]`. Any `WriteBatch` record in `.log` overrides the `.ldb` state for that 32-character extension ID (`extRegState[$extId] = $typeByte`).
3. **Time & Space Complexity of Forensic Scanner:**
   * **Time Complexity:** $\mathcal{O}(B)$ per profile via compiled .NET regular expressions over Latin1 buffers where $B$ is the total byte size of `.ldb` and `.log` files in `Service Worker\Database` (completing across all 18 Brave profiles in **~485 ms**).
   * **Space Complexity:** $\mathcal{O}(B_{\max} + E)$ where $B_{\max}$ is the size of the largest single LevelDB file buffer in memory and $E$ is the number of distinct registered extension IDs.

---

## 2. The Two-Session Split-Brain State Machine

Why does deleting `Service Worker\ScriptCache` cause Manifest V3 extensions to fail on the **first** browser launch after cleaning, yet self-heal on the **second** launch?

```
                    ┌──────────────────────────────────────────┐
                    │       INITIAL HEALTHY STATE              │
                    │  Database:    REG:<ext> = 0x01 (Active)  │
                    │  ScriptCache: <res_id>_0 present         │
                    └────────────────────┬─────────────────────┘
                                         │
                        [External Cleaner Wipes ScriptCache\*]
                                         │
                                         ▼
                    ┌──────────────────────────────────────────┐
                    │       SPLIT-BRAIN DISK STATE             │
                    │  Database:    REG:<ext> = 0x01 (Active)  │
                    │  ScriptCache: EMPTY (0 payloads)         │
                    └────────────────────┬─────────────────────┘
                                         │
                         [Launch 1: Browser Starts Up]
                                         │
                                         ▼
                    ┌──────────────────────────────────────────┐
                    │  1. ExtensionRegistrar sees 0x01 in DB   │
                    │     → Skips worker installation          │
                    │  2. User clicks extension icon           │
                    │  3. ScriptLoader reads <res_id>_0        │
                    │     → SimpleCache returns ERR_CACHE_MISS │
                    │  4. Raises kErrorDiskCache               │
                    │  5. Writes 0x00 (DELETED) to Database    │
                    │  RESULT: EXTENSION DEAD FOR SESSION 1    │
                    └────────────────────┬─────────────────────┘
                                         │
                         [Launch 2: Browser Restarted]
                                         │
                                         ▼
                    ┌──────────────────────────────────────────┐
                    │  1. ExtensionRegistrar sees 0x00 in DB   │
                    │  2. Fires RE_REGISTER_ON_STATE_MISMATCH  │
                    │  3. Writes 0x01 to DB & populates        │
                    │     worker.js + 30 modules in ScriptCache│
                    │  RESULT: EXTENSION RECOVERS IN SESSION 2 │
                    └──────────────────────────────────────────┘
```

### Atomic Recovery Invariant
To prevent the Session 1 death state entirely:
1. **Preventative Invariant:** Routine cache scrubbers (`optimize.ps1`) MUST NEVER delete `Service Worker\ScriptCache` or `Service Worker\CacheStorage` while leaving `Service Worker\Database` intact.
2. **Corrective Invariant:** If desynchronization has already occurred on a closed profile, deleting **`Database` + `ScriptCache` + `CacheStorage` atomically** transitions the profile directly to an uninitialized Service Worker state. On the very next launch, `ExtensionRegistrar` immediately performs a clean initial registration (`Session 2` path) on the first try.

---

## 3. The `park.html` Tab Destruction Hazard

Extensions such as Tab Suspender (`fiabciakcmgepblmdkmemdbbkilneeeh`) suspend inactive tabs by redirecting their top-level frame to an extension-hosted document:
```
chrome-extension://fiabciakcmgepblmdkmemdbbkilneeeh/park.html?title=...&url=https%3A%2F%2Fexample.com...
```
In Chromium's `ExtensionService::UnloadExtension` lifecycle:
* Whenever an extension is disabled or reloaded via the toggle in `brave://extensions`, Chromium iterates through all `TabStripModel` instances across all open browser windows and **force-closes every `WebContents` whose current committed URL has the scheme and host `chrome-extension://<unloaded-extension-id>/`**.
* Conversely, executing **`brave://restart`** invokes `chrome::AttemptRestart()`, which serializes the full session restore tab list (preserving all `chrome-extension://.../park.html` URLs on disk), terminates the browser process, releases all LevelDB file locks, and restores every suspended tab upon relaunch.

---

## 4. Windows NT EcoQoS (`PROCESS_POWER_THROTTLING_EXECUTION_SPEED`)

Windows 10 (Build 16299+) and Windows 11 implement **EcoQoS / Power Throttling** via `ntoskrnl.exe` thread scheduling:
* Processes flagged with `PROCESS_POWER_THROTTLING_EXECUTION_SPEED` or `PROCESS_MODE_BACKGROUND_BEGIN` have their base scheduling priority reduced from `Normal` (`BasePriority = 8`) to `Idle` (`BasePriority = 4`) and are pinned to minimum P-states / efficiency cores.
* When 14 `brave.exe` subprocesses (including extension worker hosts) drop to `BasePriority 4` on a 2-core / 4-thread Skylake-U processor (`i5-6300U`), background IPC message handling (`chrome.action.onClicked`, `chrome.alarms.onAlarm`, `chrome.tabs.onActivated`) stalls behind foreground rendering threads.
* Registering an explicit per-executable exemption in the Windows Power Policy database (`powercfg /powerthrottling disable /path "...\brave.exe"`) and resetting active process priority classes to `Normal` eliminates OS-level thread starvation.
