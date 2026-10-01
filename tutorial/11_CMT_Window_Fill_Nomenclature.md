# CMT Window Fill — Nomenclature

This project models **DFTL translation-page spatial locality** by loading a **window** of neighboring LPN mappings into the CMT on a demand miss. Use the terms below consistently in code comments, configs, logs, tutorials, and reports.

**Do not call this feature “prefetch”** in project docs or experiment output — that collides with SimpleSSD’s separate **ICL read prefetch** (`EnableReadPrefetch`, `ReadPrefetchMode` in `[icl]` / PAL), which is unrelated to the CMT.

---

## Canonical vocabulary

| Concept | Use | Avoid |
| --- | --- | --- |
| Feature name | **Window fill** (noun), **window-fill** (adjective) | Prefetch, spatial prefetch, CMT prefetch |
| Enable flag | **Window fill ON/OFF** | Prefetch ON/OFF, PF_ON (except job labels) |
| Config keys | `CMTWindowFill`, `CMTWindowSize` | `CMTSpatialPrefetch`, `CMTPrefetchWindow` |
| Code identifiers | `cmtWindowFill`, `cmtWindowSize`, `collectFillCandidates`, `evictForFillBatch`, `chargeWindowFillDRAM` | — |
| Job labels (`run.sh`) | `WF_OFF`, `WF_ON_W512` | `PF_OFF`, `PF_ON` |
| Env / sweep vars | `WINDOW_FILL`, `WINDOW_SIZE`, `SWEEP_WINDOW_FILL` | `PREFETCH`, `PREFETCH_WINDOW` |
| Per-entry flags | `fillOrigin`, `fillUnused` (internal) | prefetched, prefetch origin |
| Stats (machine keys — **do not rename**) | `fill_triggers`, `fill_insertions`, `fill_hits`, `fill_evicted_unused`, `fill_accuracy_percent`, `fill_waste_rate_percent`, `fill_coverage_percent` | — |
| Stat descriptions (human text) | “Window-fill …” | “Prefetch …” |

---

## Config (`simplessd/config/sample.cfg`)

```ini
## CMT window fill
# On a CMT miss, load a window of logically adjacent LPNs (DFTL translation-page model).
CMTWindowFill = false

## CMT window size (LPNs)
# Entries installed per miss when CMTWindowFill = true. Typically 512.
CMTWindowSize = 512
```

Default `run.sh` `WINDOW_FILL=false`. Default sweep is `SWEEP_WINDOW_FILL=(false)` so random jobs do not measure cache poisoning. Use `TEST_MODE` or sequential workloads for WF_ON.

**Thesis limits (also §28 of the CMT census):** the GMT stays in RAM, and `evictForFillBatch` charges one `CMTWriteBackLatency` per fill batch. A full window is installed only when the previous demand LPN shares that window (`windowFillBudget`). Random misses on a full CMT do not evict the cache to insert neighbors.

**Trace replay:** `Traces/stg_0.txt` lengths are bytes. Use `ByteOffset`/`ByteLength` with `config/ssd_trace_replay.cfg` (`FillRatio=0`). Do not multiply those fields by 512 as LBAs.

---

## `run.sh` output

```
Window Fill     : ON
Window Size     : 512
...
CMT hit rate: 98.44%   window-fill accuracy: 100.0%
```

Sweep summary column **Fill Acc%** maps to `ftl.page_mapping.cmt.fill_accuracy_percent`.

---

## Reports and papers

> The global mapping table remains in simulator RAM. Window fill (`CMTWindowFill`, `CMTWindowSize`) approximates one translation-page read: a follow-up miss in the same window may install up to `CMTWindowSize - 1` neighbors and evict to make room, while a random miss on a full CMT does not. Dirty victims of that batch are copied into the RAM GMT and charged one translation-page program latency, not one program per LPN. This is not NAND-resident translation storage.

---

## Out of scope (different subsystems)

| Name | Subsystem | Leave as-is |
| --- | --- | --- |
| `EnableReadPrefetch`, `ReadPrefetch*` | ICL / host read cache | Yes |
| mcpat `prefetchb` | Power model | Yes |
