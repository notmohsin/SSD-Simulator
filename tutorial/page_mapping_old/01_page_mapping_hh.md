# Chapter 1 — `page_mapping.hh`

[← README](README.md) | Next: [02_constructor_init.md](02_constructor_init.md)

Source: [`page_mapping.hh`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.hh) (lines 1–214)

---

## Lines 1–18: License header

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 1–18 | GPL v3 boilerplate | CAMELab copyright; SimpleSSD is GPLv3. Your CMT changes are derivative of this file. |

**Invariants:** No code; no runtime effect.

---

## Lines 20–21: Include guard

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 20 | `#ifndef __FTL_PAGE_MAPPING__` | Prevents double inclusion if header pulled twice. |
| 21 | `#define __FTL_PAGE_MAPPING__` | Guard macro name. |

---

## Lines 23–32: Includes

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 23 | `#include <cinttypes>` | `PRIu64` etc. for portable `printf` in `.cc`. |
| 24 | `#include <list>` | LRU `cmtOrder`; LFU frequency bucket lists. |
| 25 | `#include <unordered_map>` | GMT `table`, CMT maps, LFU buckets. |
| 26 | `#include <vector>` | Mapping vectors per LPN; stat list in `.cc`. |
| 28 | `abstract_ftl.hh` | Base class `AbstractFTL` (geometry, PAL ptr, virtual I/O). |
| 29 | `common/block.hh` | `Block` metadata (valid/dirty pages per physical block). |
| 30 | `config.hh` | `CMT_POLICY`, `FTL_CMT_*` config keys. |
| 31 | `ftl.hh` | `Parameter`, `Request`, `Status`. |
| 32 | `pal/pal.hh` | PAL forward types (included via base). |

---

## Lines 34–36: Namespaces

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 34–36 | `namespace SimpleSSD { namespace FTL {` | All FTL types live here. |

---

## Lines 38–42: Class declaration start

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 38 | `class PageMapping : public AbstractFTL` | Concrete page-mapping FTL; implements read/write/trim/format. |
| 40 | `PAL::PAL *pPAL` | NAND timing layer; duplicate of base `pPAL` for local use in `.cc`. |
| 42 | `ConfigReader &conf` | Reference to FTL config (fill ratio, GC policy, CMT knobs). |

**Inherited (not redeclared here):** `param`, base `pPAL`, `pDRAM`, `status` from `AbstractFTL` — see [README quick reference](README.md#quick-reference--inherited-vs-local). `applyLatency` is a free function in `sim/cpu.hh`.

---

## Lines 44–51: GMT and block bookkeeping (upstream FTL)

| Line(s) | Member | Meaning |
| --- | --- | --- |
| 44–45 | `table` | **GMT** — `LPN → vector<(blockIdx, pageIdx)>` per superpage. Ground truth in simulator RAM. |
| 46 | `blocks` | Active physical blocks currently holding data (`blockIdx → Block`). |
| 47 | `freeBlocks` | Erased blocks waiting for allocation (`list<Block>`). |
| 48 | `nFreeBlocks` | Count of free blocks (because `list::size()` may be O(n) on some STLs). |
| 49 | `lastFreeBlock` | One current write target per parallel I/O group (`pageCountToMaxPerf` entries). |
| 50 | `lastFreeBlockIOMap` | Bitset of which sub-pages share the current write block. |
| 51 | `lastFreeBlockIndex` | Rotating index into `lastFreeBlock` for striping writes. |

**Invariant:** A physical block is in `blocks` OR `freeBlocks`, not both.

---

## Lines 53–55: I/O geometry flags

| Line(s) | Member | Meaning |
| --- | --- | --- |
| 53 | `bReclaimMore` | Set when a write block fills; tells GC to reclaim extra blocks next time. |
| 54 | `bRandomTweak` | From `EnableRandomIOTweak` config — partial superpage I/O. |
| 55 | `bitsetSize` | Sub-pages per LPN mapping entry: `ioUnitInPage` if tweak on, else `1`. Drives **CMT entry size**. |

---

## Lines 57–73: CMT configuration scalars

| Line(s) | Member | Meaning |
| --- | --- | --- |
| 68 | `cmtPolicy` | `CMT_POLICY_LRU` (0) or `CMT_POLICY_LFU` (1). |
| 70 | `cmtCapacity` | Max **entries** (not bytes), computed in constructor. |
| 71 | `cmtEntryBytes` | `8 * bitsetSize` — bytes of mapping data per cache entry. |
| 72 | `cmtMissLatency` | Picoseconds added to `tick` on miss load of existing GMT row. |
| 73 | `cmtWriteBackLatency` | Picoseconds added on dirty eviction write-back. |

Comments 57–66: design intent — DFTL-style SRAM cache over `table`; single API prevents policy desync.

---

## Lines 75–87: LRU structures

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 77–80 | `struct CMTEntry` | Cached copy of mapping vector + `dirty` flag. |
| 78 | `mapping` | Copy of `table[lpn]` vector; may be **newer** than GMT when dirty. |
| 79 | `dirty` | If true, GMT is stale until write-back or `flushCMT`. |
| 83 | `cmtOrder` | `list<LPN>`: **front = MRU**, **back = LRU victim**. |
| 86–87 | `cmt` | `LPN → {CMTEntry, list::iterator}` for O(1) splice on hit. |

**Only populated when `cmtPolicy == LRU`.**

---

## Lines 89–110: LFU structures

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 96–101 | `struct CMTEntryLFU` | Mapping + dirty + `freq` + `listIt` into freq bucket. |
| 99 | `freq` | Lifetime access count while resident; never decays. |
| 100 | `listIt` | Iterator into `cmtFreqBuckets[freq]` for O(1) removal. |
| 104 | `cmtFreqBuckets` | `freq → list<LPN>`; **front = MRU** within frequency. |
| 107 | `cmtLFU` | Main LFU store `LPN → CMTEntryLFU`. |
| 110 | `cmtMinFreq` | Smallest frequency with ≥1 LPN; eviction bucket. |

**Only populated when `cmtPolicy == LFU`.**

---

## Lines 112–157: CMT method declarations

| Method | Purpose | Callers |
| --- | --- | --- |
| `accessCMT` | Policy dispatcher; hit/miss/evict/insert | `readInternal`, `writeInternal`, GC |
| `accessCMT_LRU` / `_LFU` | Implementations | `accessCMT` only |
| `cmtErase` | Drop LPN from cache, **no** write-back | `trimInternal`, `format` |
| `repairLFUMinFreq` | Fix `cmtMinFreq` after bucket empty | `cmtErase`, LFU eviction |
| `getLiveMapping` | Peek CMT else GMT; no stats/latency | `trimInternal`, `format` |
| `cmtSize` | Occupancy count | `getStatValues`, warm-up log |
| `flushCMT` | Dirty → GMT, clear all CMT containers | Destructor |
| `resetCMTStats` | Zero CMT counters only | End of `initialize` |

**`allocate` parameter (default true):** if false and LPN not in GMT, return `nullptr` without creating mapping.

**`isGC` parameter (default false):** route stats to `cmt.gc_*` instead of user hits/misses.

---

## Lines 159–172: `stat` struct

| Field | Meaning |
| --- | --- |
| `gcCount` | Times on-demand GC ran from `writeInternal`. |
| `reclaimedBlocks` | Blocks reclaimed across those GC runs. |
| `validSuperPageCopies` | Superpages copied during GC. |
| `validPageCopies` | Sub-pages copied during GC. |
| `cmtHits` / `cmtMisses` | User-path CMT (excludes GC; reset after warm-up). |
| `cmtEvictions` | Entries evicted from CMT. |
| `cmtDirtyEvictions` | Evictions that wrote dirty mapping to GMT. |
| `cmtWritebacks` | Count of write-back operations (equals dirty evictions today). |
| `cmtGCHits` / `cmtGCMisses` | GC-triggered CMT lookups. |

---

## Lines 174–189: Private FTL helpers (non-CMT)

| Method | Role |
| --- | --- |
| `freeBlockRatio` | `nFreeBlocks / totalPhysicalBlocks` — GC trigger input. |
| `convertBlockIdx` | `blockIdx % pageCountToMaxPerf` — parallel group. |
| `getFreeBlock` | Pull block from `freeBlocks` into `blocks`. |
| `getLastFreeBlock` | Current write block for I/O bitmap; rotate on full. |
| `calculateVictimWeight` | Score blocks for GC victim policy. |
| `selectVictimBlock` | Pick victim block list. |
| `doGarbageCollection` | Copy valid pages, update mappings, erase victims. |
| `calculateWearLeveling` | Jain-style fairness metric on erase counts. |
| `calculateTotalPages` | Sum valid/invalid pages in active blocks. |
| `readInternal` / `writeInternal` / `trimInternal` / `eraseInternal` | Core I/O implementation. |

---

## Lines 191–207: Public API

| Method | Override | Role |
| --- | --- | --- |
| Constructor | — | Build block lists, size CMT, read config. |
| Destructor | — | `flushCMT()`. |
| `initialize` | yes | Warm-up fill/invalidate; `resetCMTStats`. |
| `read` / `write` / `trim` | yes | Public entry + CPU latency + debug. |
| `format` | yes | Range erase + GC. |
| `getStatus` | yes | Free blocks, mapped LPN count. |
| `getStatList` / `getStatValues` / `resetStatValues` | yes | Simulator statistics export. |

---

## Lines 210–214: Close guard

| Line(s) | Code | Meaning |
| --- | --- | --- |
| 210–212 | Close namespaces | End `FTL`, `SimpleSSD`. |
| 214 | `#endif` | End include guard. |

---

## Who calls whom (CMT-related)

```text
readInternal  ──► accessCMT(allocate=false)
writeInternal ──► accessCMT(isWrite=true)
trimInternal  ──► getLiveMapping → cmtErase
format        ──► getLiveMapping → cmtErase
GC            ──► accessCMT(isWrite=true, isGC=true)
~PageMapping  ──► flushCMT
initialize    ──► writeInternal → resetCMTStats
```

---

## Self-quiz

1. What type is `table` and what does one value hold?
2. What is the difference between `cmt` and `table`?
3. Which list end is the LRU victim?
4. What does `dirty` mean for a CMT entry?
5. Why store a `list::iterator` inside `cmt`?
6. What does `cmtMinFreq` point to in LFU?
7. When should you call `cmtErase` vs `flushCMT`?
8. What does `allocate=false` prevent?
9. Which stats does `resetCMTStats` clear — and what does it **not** clear?
10. Name three private methods that are **not** CMT-related.

### Answers

1. `unordered_map<uint64_t, vector<pair<uint32_t,uint32_t>>>` — one superpage’s physical mappings.
2. `table` is full GMT; `cmt` is size-limited LRU cache overlay.
3. `cmtOrder.back()`.
4. CMT copy was written; GMT may be stale until write-back.
5. O(1) `splice` to MRU on hit without scanning the list.
6. The smallest frequency bucket that still has at least one LPN.
7. `cmtErase` = destroy mapping (no WB); `flushCMT` = sim shutdown coherence (WB all dirty).
8. Creating GMT/CMT entries for never-written LPNs on read/trim peek.
9. Clears all `cmt*` counters; does **not** clear cache contents or GC stats.
10. e.g. `getFreeBlock`, `selectVictimBlock`, `calculateWearLeveling`.
