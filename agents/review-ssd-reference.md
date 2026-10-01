# SimpleSSD Fidelity Reference (papers-first)

Read this file when running `/reviewSSD` or a portable fidelity review. Authority order: **papers → SimpleSSD baseline → project tutorials**.

---

## Primary papers

| Paper | Use when reviewing |
| --- | --- |
| Gupta, Kang, Ahn, Lee, Chang — **DFTL: A Flash Translation Layer Employing Demand-based Selective Caching of Page-level Address Mappings** (ASPLOS '09) | CMT, translation pages, miss/write-back costs, global directory, translation-page GC |
| Shah, Mitra, Matani — **An O(1) algorithm for implementing the LFU cache eviction scheme** (2010; referenced in `page_mapping.cc`) | LFU bucket structure, eviction order, frequency semantics |
| Li, Chen, Lee — **An Efficient Wear Leveling Scheme for Large-Capacity Flash Memory Storage Systems** (SIGMETRICS '13) | `calculateWearLeveling()` metric; cited in SimpleSSD for WL factor |

**DFTL essentials (ASPLOS '09):**

- Full map stored as **translation pages** on NAND; only a subset cached in SRAM (CMT).
- **CMT miss:** read translation page from flash (extra read latency — "double read" when data is also needed).
- **Dirty eviction:** write translation page back to flash (extra program).
- Translation page packs **many** LPN→PPN entries (~512 in a 4 KB page in the paper's model).
- Translation pages themselves need **GC** and a **global translation directory**.

---

## GC background

**Out-of-place update (invariant):**

- Program only into **erased** pages.
- Overwrite at logical level → write new physical page, invalidate old copy.
- Reclaim space via **GC:** select victim block → copy valid pages → erase block.

**SimpleSSD victim policies** (`EvictPolicy` in config):

- Greedy (most invalid pages)
- Cost-benefit (age × valid ratio)
- Random, d-choice

**GC trigger:** free blocks fall below `GCThreshold` (fraction of total blocks).

---

## Fidelity rubric

### A. Mapping & CMT (DFTL family)

| Check | Real SSD / paper | SimpleSSD baseline |
| --- | --- | --- |
| GMT residency | Map largely on NAND; CMT is SRAM cache | GMT always in RAM (`PageMapping::table`) — **documented limitation** |
| Miss path | PAL read of translation page | `tick += CMTMissLatency` (synthetic) |
| Dirty eviction | PAL program of translation page | Copy to `table` + `tick += CMTWriteBackLatency` |
| Entry granularity | One translation page → many LPNs | One CMT entry = one LPN superpage vector (`8 * bitsetSize` bytes) |
| Window-fill | Spatial locality within translation page | `cmtWindowFill`, `cmtWindowSize` — partial model of translation-page read |
| Policies | LRU/LFU semantics; LFU often uses aging in practice | LFU has **no frequency aging** — cache poisoning possible |
| Warm-up stats | Steady-state hits after fill | `resetCMTStats()` at end of `initialize()` |
| Unmapped reads | No mapping allocation on read miss | `accessCMT(..., allocate=false)`; still increments miss counter |
| End-of-sim flush | N/A | `flushCMT()` does **not** charge write-back latency |

### B. GC & block lifecycle

| Check | Real SSD | SimpleSSD |
| --- | --- | --- |
| Out-of-place write | New data → free page; old invalidated | `writeInternal` |
| GC trigger | Free blocks below threshold | `GCThreshold`, `selectVictimBlock` |
| Relocation | Valid pages copied before erase | `doGarbageCollection`, `validPageCopies` stat |
| GC latency | GC work visible in I/O latency | **Gap:** `writeInternal` uses local `beginAt`; GC tick not added to triggering write |
| CMT + GC | Remap may touch mapping cache | `accessCMT(..., isGC=true)` |
| Write amplification | Extra programs from relocation | Stats / DRAM write bytes |

### C. Wear leveling & endurance

| Check | Real SSD | SimpleSSD |
| --- | --- | --- |
| Erase distribution | Dynamic WL spreads erases | **No WL algorithm** — only `calculateWearLeveling()` metric |
| Block retirement | Retire near endurance limit | `EraseThreshold` default ~100k; realistic MLC ~3k — **effectively off** |
| Bad blocks | Removed from free pool | `eraseInternal` drops block when `eraseCount >= EraseThreshold` |

### D. Latency & stats honesty

- New `tick` charges: CMT synthetic vs PAL I/O vs neither — right layer?
- Capacity: `cmtCapacity = bytes / cmtEntryBytes`, not `bytes / 8`
- Sweeps: ICL off isolates CMT — not a full-system claim
- Hit rate on sparse unmapped reads understates due to miss counting

---

## Project fidelity baseline (documented limitations)

From `PROGRESS.md` and `tutorial/08_CMT_Mentor_Census.md` §28:

1. GMT always in RAM — CMT does not move the map to NAND.
2. Miss/write-back are synthetic `tick` adds, not PAL translation I/O.
3. No translation-page packing — one miss per LPN, not per translation page.
4. ICL off in CMT sweeps — isolates CMT; not full-system.
5. Unmapped reads increment miss count before returning nullptr.
6. `flushCMT` does not charge write-back latency (end-of-sim coherence only).
7. LFU frequencies never age — historically hot pages can poison the cache.
8. On-demand GC does not add latency to the write that triggers it (`writeInternal` local `beginAt`).
9. `EraseThreshold` block retirement effectively disabled at default.

**Honest pitch (what the project actually studies):**

> DFTL-style **replacement policy and cache sizing** under a synthetic miss/write-back cost model — not flash-resident translation storage.

---

## Key file map (`page_mapping.cc`)

| Region | Lines (approx) | Functions / topic |
| --- | --- | --- |
| CMT setup | 65–103 | Policy, capacity, window-fill, latencies |
| CMT API | 123–263 | `flushCMT`, `cmtErase`, `resetCMTStats` |
| Init / warm-up | 264–393 | `initialize`, prefill, stat reset |
| Public I/O | 394–525 | `read`, `write`, `trim`, `format` |
| Free blocks | 526–606 | `getFreeBlock`, `getLastFreeBlock` |
| GC victim | 607–717 | `calculateVictimWeight`, `selectVictimBlock` |
| GC relocate | 718–840 | `doGarbageCollection` |
| CMT access | 841–1403 | `accessCMT`, LRU/LFU, window-fill batch |
| Internal I/O | 1404–1662 | `readInternal`, `writeInternal`, `trimInternal` |
| Erase / WL | 1663–1747 | `eraseInternal`, block retirement |
| Stats | 1748–1933 | `getStatList`, CMT counters |

**Config keys:** `simplessd/ftl/config.cc` — `CMTPolicy`, `CMTCapacityBytes`, `CMTMissLatency`, `CMTWriteBackLatency`, `CMTWindowFill`, `CMTWindowSize`, GC keys.

---

## Window-fill vs DFTL (review guidance)

Real DFTL: one translation-page read brings **many** mappings into the CMT.

This project's `cmtWindowFill`: on miss, install neighboring LPNs within `cmtWindowSize` (window fill).

**Judge:**

- **Correct** as an *approximation* of translation-page spatial locality if window size ≈ entries per translation page and cost is one miss latency per trigger.
- **Misleading** if results or comments imply full DFTL translation-page I/O without noting GMT-in-RAM and single-LPN entry granularity.
- **Incorrect** if window fill inserts mappings that violate allocate-on-read rules or double-charges miss latency per filled entry without justification.

---

## Secondary project docs

| Doc | Use for |
| --- | --- |
| `tutorial/08_CMT_Mentor_Census.md` | End-to-end CMT behavior, worked examples, §28 limitations |
| `tutorial/page_mapping/` | Annotated `page_mapping.{hh,cc}` |
| `tutorial/architecture/01_simulator_model.md` | Event model, GC latency gap |
| `PROGRESS.md` | Stale results warnings, experiment status |
