# `page_mapping.{hh,cc}` — Annotated Guide

Line-by-line annotated documentation for:

- [`SimpleSSD-Standalone/simplessd/ftl/page_mapping.hh`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.hh) (214 lines)
- [`SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc) (1564 lines)

**Theory companion:** [`../08_CMT_Mentor_Census.md`](../08_CMT_Mentor_Census.md) (why CMT exists, experiments, mentor Q&A).

**Context companion:** [`../architecture/README.md`](../architecture/README.md) — the simulator around this file: event model, boot order, layer contracts, and the other files in `simplessd/ftl/` (`ftl.cc`, `block.cc`, `config.cc`). Read [`../architecture/04_ftl_file_map.md`](../architecture/04_ftl_file_map.md) if you want to know where `page_mapping.cc` sits before diving in.

**Stale upstream notes:** [`../FTL Line-by-Line Notes.md`](../FTL%20Line-by-Line%20Notes.md) still describes pre-CMT `table.find` — use **this folder** for current code.

---

## How to read

1. Read chapters **in order** the first time.
2. Each section cites **source line ranges** and explains **every statement** in that range.
3. After each chapter, do the **self-quiz** at the bottom.
4. Keep [`08_CMT_Mentor_Census.md`](../08_CMT_Mentor_Census.md) open for DFTL background.

**Suggested study path (20 min before a meeting):** `01` → `06` (CMT) → `07` (read/write) → census §28 (fidelity limits).

---

## Table of contents

| # | File | Source lines | Topics |
| --- | --- | --- | --- |
| 1 | [01_page_mapping_hh.md](01_page_mapping_hh.md) | `.hh` 1–214 | Class layout, GMT, CMT structs, API |
| 2 | [02_constructor_init.md](02_constructor_init.md) | `.cc` 34–351 | Ctor, dtor, CMT helpers, `initialize` |
| 3 | [03_public_io.md](03_public_io.md) | `.cc` 353–479 | `read`/`write`/`trim`/`format`/`getStatus` |
| 4 | [04_free_blocks.md](04_free_blocks.md) | `.cc` 481–563 | Free-block ratio, allocation, write pointer |
| 5 | [05_gc.md](05_gc.md) | `.cc` 565–797 | Victim selection, `doGarbageCollection` |
| 6 | [06_cmt_access.md](06_cmt_access.md) | `.cc` 799–1094 | `accessCMT`, LRU, LFU |
| 7 | [07_internal_io.md](07_internal_io.md) | `.cc` 1096–1405 | `readInternal`, `writeInternal`, trim, erase |
| 8 | [08_wear_stats.md](08_wear_stats.md) | `.cc` 1407–1564 | Wear leveling, stat export |

---

## Function index (quick lookup)

| Function | Chapter |
| --- | --- |
| `PageMapping()` / `~PageMapping()` | 02 |
| `flushCMT`, `repairLFUMinFreq`, `cmtErase`, `getLiveMapping`, `cmtSize`, `resetCMTStats` | 02 |
| `initialize` | 02 |
| `read`, `write`, `trim`, `format`, `getStatus` | 03 |
| `freeBlockRatio`, `convertBlockIdx`, `getFreeBlock`, `getLastFreeBlock` | 04 |
| `calculateVictimWeight`, `selectVictimBlock`, `doGarbageCollection` | 05 |
| `accessCMT`, `accessCMT_LRU`, `accessCMT_LFU` | 06 |
| `readInternal`, `writeInternal`, `trimInternal`, `eraseInternal` | 07 |
| `calculateWearLeveling`, `calculateTotalPages`, `getStatList`, `getStatValues`, `resetStatValues` | 08 |

---

## Quick reference — inherited vs local

`PageMapping` inherits `AbstractFTL` → `StatObject`. These names appear in every chapter but are **not** declared in `page_mapping.hh`:

| Name | Declared in | Role |
| --- | --- | --- |
| `param` | `AbstractFTL` | Device geometry (`totalPhysicalBlocks`, `pagesInBlock`, `ioUnitInPage`, `pageCountToMaxPerf`, …) |
| `pPAL` | `AbstractFTL` **and** duplicated as `PageMapping::pPAL` | NAND timing layer |
| `pDRAM` | `AbstractFTL` | Controller DRAM model (translation traffic charges) |
| `status` | `AbstractFTL` | `totalLogicalPages` / `mappedLogicalPages` / `freePhysicalBlocks` |
| `applyLatency(...)` | Free function in `sim/cpu.hh` | Adds modelled CPU software overhead to `tick` |

Members unique to `PageMapping` (GMT, free lists, CMT, GC helpers) are in [01_page_mapping_hh.md](01_page_mapping_hh.md).

---

## Quick reference — sentinel mapping

Unwritten sub-pages use the **invalid PPN sentinel**:

```text
(blockIdx, pageIdx) = (param.totalPhysicalBlocks, param.pagesInBlock)
```

| Rule | Detail |
| --- | --- |
| Creation | First write to an LPN: `accessCMT` emplaces a GMT vector filled with sentinels ([06](06_cmt_access.md)) |
| Valid check | `mapping.first < param.totalPhysicalBlocks` means a real physical page |
| Must skip | `format`, `trimInternal`, `readInternal` skip sentinels — invalidating one would `panic` on a missing block |
| Live vs GMT | Prefer `getLiveMapping` on destroy paths; GMT alone may still hold a sentinel or pre-writeback PPN |

---

## Quick reference — FTL config keys used by `page_mapping`

All under the FTL section of `simplessd/config/sample.cfg` (enum in `ftl/config.hh`).

| Config name | Enum | Used by | Meaning |
| --- | --- | --- | --- |
| `EnableRandomIOTweak` | `FTL_USE_RANDOM_IO_TWEAK` | ctor | `bitsetSize = ioUnitInPage` if on, else `1` |
| `CMTPolicy` | `FTL_CMT_POLICY` | ctor / `accessCMT` | `0` = LRU, `1` = LFU |
| `CMTCapacityRatio` | `FTL_CMT_CAPACITY_RATIO` | ctor | If `> 0`, capacity = ratio × logical pages (overrides bytes) |
| `CMTCapacityBytes` | `FTL_CMT_CAPACITY_BYTES` | ctor | Else capacity = bytes / `(8 × bitsetSize)` |
| `CMTMissLatency` | `FTL_CMT_MISS_LATENCY` | `accessCMT` | ps added on miss load of existing GMT row |
| `CMTWriteBackLatency` | `FTL_CMT_WRITEBACK_LATENCY` | `accessCMT` | ps added on dirty eviction |
| `FillingMode` | `FTL_FILLING_MODE` | `initialize` | `0`/`1`/`2` fill + invalidate patterns |
| `FillRatio` | `FTL_FILL_RATIO` | `initialize` | Fraction of LPNs to warm up |
| `InvalidPageRatio` | `FTL_INVALID_PAGE_RATIO` | `initialize` | Fraction overwritten to create invalid pages |
| `GCThreshold` | `FTL_GC_THRESHOLD_RATIO` | `writeInternal` | Free-block ratio below which on-demand GC runs |
| `GCMode` | `FTL_GC_MODE` | `selectVictimBlock` | `0` fixed reclaim count, `1` threshold reclaim |
| `GCReclaimBlocks` | `FTL_GC_RECLAIM_BLOCK` | `selectVictimBlock` | Blocks to reclaim when `GCMode = 0` |
| `GCReclaimThreshold` | `FTL_GC_RECLAIM_THRESHOLD` | `selectVictimBlock` | Target free fraction when `GCMode = 1` |
| `EvictPolicy` | `FTL_GC_EVICT_POLICY` | `selectVictimBlock` | Greedy / cost–benefit / random / d-choice |
| `DChoiceParam` | `FTL_GC_D_CHOICE_PARAM` | `selectVictimBlock` | Sample multiplier for d-choice |

Details: ctor/fill in [02](02_constructor_init.md), free blocks in [04](04_free_blocks.md), GC in [05](05_gc.md), CMT latencies in [06](06_cmt_access.md).

---

## Open questions (documented behaviour, not guesses)

These were flagged during writing. Current code behaviour is stated; change only if you decide to refactor.

### 1. Unmapped read increments `cmtMiss` before `nullptr`

**Behaviour:** `readInternal` calls `accessCMT(..., allocate=false)`. On a never-written LPN, the miss counter increments, then the function returns `nullptr` with **no** miss latency and **no** GMT/CMT allocation.

**Impact:** Full-drive random reads are fine. Sparse reads to holes deflate hit rate slightly.

**Status:** Documented quirk; not changed in this pass.

### 2. `cmtWritebacks` vs `cmtDirtyEvictions`

**Behaviour:** Both increment together on every dirty eviction in LRU and LFU paths. They are always equal in the current code.

**Status:** Both exported for clarity (write-back ops vs dirty evictions could diverge if partial write-back were added later).

### 3. GC uses `accessCMT(lpn, isWrite=true, isGC=true)`

**Behaviour:** GC relocation marks mappings dirty and counts under `cmt.gc_*`. LFU promotes frequency on GC hits like user hits.

**Status:** Intentional — GC updates mappings through the same cache coherence path as writes.

### 4. `flushCMT()` charges no `cmtWriteBackLatency`

**Behaviour:** Destructor-only coherence; copies dirty entries to GMT with no `tick` penalty.

**Status:** Acceptable for end-of-simulation; not modelling shutdown translation I/O cost.

### 5. Device geometry in comments

**Behaviour:** Capacity and GC use `param.*` from PAL geometry (blocks, pages/block, `pageCountToMaxPerf`, `ioUnitInPage`). Your sweeps use `Block = 512` in FTL config and `EnableRandomIOTweak = 1` → `bitsetSize = 8`.

**Status:** See constructor chapter for the exact formulas.

---

## Source snapshot

Documentation matches working tree as of **2026-08-11** (CMT policy switch, `getLiveMapping`, LFU `repairLFUMinFreq`, warm-up `resetCMTStats`). Review pass added config/sentinel/AbstractFTL quick refs and fixed the cost–benefit age explanation in ch. 05.
