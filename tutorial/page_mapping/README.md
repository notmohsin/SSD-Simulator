# `page_mapping` — Understanding the FTL Algorithm

A concept-driven guide to SimpleSSD's page-level Flash Translation Layer, built around the files:

- [`page_mapping.hh`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.hh) (214 lines)
- [`page_mapping.cc`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc) (1564 lines)

**Context:** [`../architecture/README.md`](../architecture/README.md) — the simulator around this file: event model, boot order, layer contracts, and the other files in `simplessd/ftl/`.

**Theory:** [`../08_CMT_Mentor_Census.md`](../08_CMT_Mentor_Census.md) for CMT/DFTL background and experiments.

> [!NOTE]
> **Previous version:** The original line-by-line annotated chapters are preserved in `../page_mapping_old/` for reference.

---

## How this series is organized

Unlike a line-by-line code walkthrough, this series is organized by **concepts and request flows**. Each chapter starts by explaining the *problem*, then shows how the code solves it, with Mermaid diagrams before code and explicit "**Why this way?**" callouts for every major design decision.

**CMT depth:** Chapters 4 and 5 give the deepest treatment to the Cached Mapping Table, since that's the primary research focus.

---

## Reading order

| # | Chapter | The one thing to take away |
|---|---------|---------------------------|
| 1 | [The Big Picture](01_the_big_picture.md) | `PageMapping` translates host I/O to flash operations; every design choice exists because flash can't be overwritten in-place |
| 2 | [Boot & Init](02_boot_and_init.md) | The constructor sizes everything from PAL geometry; `initialize()` pre-fills the drive for realistic benchmarks |
| 3 | [GMT & Address Space](03_gmt_and_address_space.md) | The GMT is the ground truth for every mapping; a sentinel PPN means "never written" |
| 4 | [CMT: Why & How](04_cmt_why_and_how.md) | The GMT is too large for SRAM; the CMT caches the hot working set; every miss costs an extra flash read |
| 5 | [CMT: LRU & LFU Deep Dive](05_cmt_deep_dive.md) | Both policies are O(1); LRU bets on recency, LFU on frequency; worked traces and edge cases |
| 6 | [I/O Paths](06_io_paths.md) | Public methods are thin wrappers; `readInternal`/`writeInternal` do the real work with tick budgets |
| 7 | [Garbage Collection](07_garbage_collection.md) | GC selects victims, migrates valid pages, erases blocks; it interacts with CMT for mapping coherence |
| 8 | [Wear & Stats](08_wear_and_stats.md) | 18 exported statistics; understanding their quirks is essential for correct experiment analysis |

---

## Suggested study paths

**Quick overview (15 min):** Chapter 1 only — the complete read/write walkthrough gives you the big picture.

**Before a mentor meeting (30 min):** Chapters 1 → 4 (CMT motivation) → skip to the worked traces in Chapter 5.

**CMT research deep dive:** Chapters 4 → 5 → 6 (how I/O paths call `accessCMT`) → Census §28 for fidelity limits.

**Full understanding:** All 8 chapters in order.

---

## Function index (quick lookup)

| Function | Chapter | What it does |
|----------|---------|--------------|
| `PageMapping()` / `~PageMapping()` | [02](02_boot_and_init.md) | Constructor (sizes everything) / Destructor (flushes CMT) |
| `initialize` | [02](02_boot_and_init.md) | Pre-fills drive for realistic benchmarks |
| `flushCMT` | [02](02_boot_and_init.md) | Writes dirty CMT entries to GMT on shutdown |
| `cmtErase` | [02](02_boot_and_init.md) | Drops LPN from CMT without write-back (trim/format) |
| `getLiveMapping` | [02](02_boot_and_init.md) | Read-only peek at current mapping (no cache mutation) |
| `repairLFUMinFreq` | [02](02_boot_and_init.md) | Fixes `cmtMinFreq` after empty bucket |
| `resetCMTStats` | [02](02_boot_and_init.md) | Zeros CMT counters after warm-up |
| `read`, `write`, `trim`, `format`, `getStatus` | [06](06_io_paths.md) | Public API (thin wrappers + CPU latency) |
| `readInternal` | [06](06_io_paths.md) | Mapping lookup → DRAM → PAL read |
| `writeInternal` | [06](06_io_paths.md) | Mapping update → invalidate old → allocate new → PAL write → GC check |
| `trimInternal` | [06](06_io_paths.md) | Peek mapping → invalidate → drop from CMT + GMT |
| `eraseInternal` | [06](06_io_paths.md) | Assert empty → erase block → return to free list |
| `accessCMT` | [04](04_cmt_why_and_how.md), [05](05_cmt_deep_dive.md) | Dispatcher → LRU or LFU cache lookup/insert/evict |
| `accessCMT_LRU` | [05](05_cmt_deep_dive.md) | LRU cache implementation |
| `accessCMT_LFU` | [05](05_cmt_deep_dive.md) | LFU cache implementation (O(1) frequency buckets) |
| `freeBlockRatio` | [07](07_garbage_collection.md) | Free blocks / total blocks |
| `getFreeBlock`, `getLastFreeBlock` | [07](07_garbage_collection.md) | Stream-aligned block allocation |
| `calculateVictimWeight` | [07](07_garbage_collection.md) | GC victim scoring (greedy / cost-benefit / random / d-choice) |
| `selectVictimBlock` | [07](07_garbage_collection.md) | Picks N worst blocks to reclaim |
| `doGarbageCollection` | [07](07_garbage_collection.md) | Migrates valid pages, erases victims |
| `calculateWearLeveling` | [08](08_wear_and_stats.md) | Jain's fairness index over erase counts |
| `getStatList`, `getStatValues`, `resetStatValues` | [08](08_wear_and_stats.md) | 18 stats exported to the simulator |

---

## Key data structures at a glance

| Name | Type | Role | Chapter |
|------|------|------|---------|
| `table` | `unordered_map<uint64_t, vector<pair<uint32_t,uint32_t>>>` | **GMT** — ground truth LPN→PPN map | [03](03_gmt_and_address_space.md) |
| `blocks` | `unordered_map<uint32_t, Block>` | In-use physical blocks with valid/invalid bitmaps | [03](03_gmt_and_address_space.md) |
| `freeBlocks` | `list<Block>` | Erased blocks, sorted by erase count | [03](03_gmt_and_address_space.md) |
| `cmt` | `unordered_map<uint64_t, pair<CMTEntry, list::iterator>>` | **LRU cache** — O(1) lookup + splice | [05](05_cmt_deep_dive.md) |
| `cmtOrder` | `list<uint64_t>` | LRU recency list (front=MRU, back=victim) | [05](05_cmt_deep_dive.md) |
| `cmtLFU` | `unordered_map<uint64_t, CMTEntryLFU>` | **LFU cache** — O(1) lookup | [05](05_cmt_deep_dive.md) |
| `cmtFreqBuckets` | `unordered_map<uint64_t, list<uint64_t>>` | LFU frequency buckets | [05](05_cmt_deep_dive.md) |
| `lastFreeBlock` | `vector<uint32_t>` | Open write blocks (one per parallel stream) | [07](07_garbage_collection.md) |

---

## Acronyms

| Short | Long | Meaning |
|-------|------|---------|
| FTL | Flash Translation Layer | Logical-to-physical mapping, GC, wear |
| GMT | Global Mapping Table | Full `LPN → PPN` map (the `table` variable) |
| CMT | Cached Mapping Table | Size-limited SRAM cache over the GMT |
| LPN | Logical Page Number | FTL-level superpage address |
| PPN | Physical Page Number | `(blockIndex, pageIndex)` pair |
| LCA | Logical Cluster Address | ICL-level page address |
| GC | Garbage Collection | Reclaiming blocks by moving valid pages |
| PAL | Parallelism Abstraction Layer | NAND geometry and timing |
| DFTL | Demand-based FTL | Gupta et al. (ASPLOS '09) — cached page-level mapping |

---

## Source snapshot

Written against the working tree of **2026-08-11**. Line numbers cited in chapters were read from source at that time; if you pull upstream changes, re-check before trusting a citation.
