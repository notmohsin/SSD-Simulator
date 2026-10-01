# Chapter 2 — Constructor, Destructor, CMT Helpers, and `initialize`

[← Back to `page_mapping` guide](README.md)

**Source:** [`page_mapping.cc`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc) lines **34–351**

**Prerequisites:** [01_page_mapping_hh.md](01_page_mapping_hh.md) (class layout, GMT/CMT members)

**Related:** CMT lookup/eviction mechanics live in [06_cmt_access.md](06_cmt_access.md). Theory background: [08_CMT_Mentor_Census.md](../08_CMT_Mentor_Census.md).

---

## Overview

This chapter covers everything that happens **before** the measured workload runs:

1. **Constructor** — allocate geometry, free-block pool, CMT sizing from config.
2. **Destructor** — flush dirty CMT entries into GMT for a coherent final map.
3. **CMT utility functions** — coherence helpers used by trim/format/GC and shutdown.
4. **`initialize()`** — synthetic warm-up fill + invalidation, then reset CMT **counters** (not contents).

These functions establish the FTL state that `read`/`write` (Chapter 3) and free-block allocation (Chapter 4) assume.

---

## Section A — `PageMapping` constructor (lines 34–95)

### Line range

`page_mapping.cc` **34–95**

### Purpose

Construct a `PageMapping` FTL instance: inherit from `AbstractFTL`, reserve containers, populate the **free-block list**, pre-allocate **write-pointer blocks** (`lastFreeBlock`), zero statistics, read FTL config for random-I/O tweak and **CMT capacity/policy/latencies**.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 34 | `PageMapping::PageMapping(ConfigReader &c, Parameter &p, PAL::PAL *l, DRAM::AbstractDRAM *d)` | Constructor entry: config reader, geometry `Parameter`, PAL pointer, DRAM pointer. |
| 35 | `    : AbstractFTL(p, l, d),` | Base-class init: stores `param`, PAL, DRAM for all FTL subclasses. |
| 36 | `      pPAL(l),` | Duplicate PAL pointer in this class (`pPAL`) for member access. |
| 37 | `      conf(c),` | Store reference to config reader (must outlive `PageMapping`). |
| 38 | `      lastFreeBlock(param.pageCountToMaxPerf),` | Vector sized to **parallel write streams** — one active free block per stream index. |
| 39 | `      lastFreeBlockIOMap(param.ioUnitInPage),` | Bitset tracking which sub-pages of the current superpage were touched. |
| 40 | `      bReclaimMore(false) {` | GC hint flag; body opens. Initially false. |
| 41 | `  blocks.reserve(param.totalPhysicalBlocks);` | Reserve hash-map capacity for in-use blocks (avoids rehash during simulation). |
| 42 | `  table.reserve(param.totalLogicalBlocks * param.pagesInBlock);` | Reserve GMT (`table`) capacity for worst-case one entry per logical page. |
| 43 | *(blank)* | Visual separator. |
| 44 | `  for (uint32_t i = 0; i < param.totalPhysicalBlocks; i++) {` | Loop over every physical block index in the device. |
| 45 | `    freeBlocks.emplace_back(Block(i, param.pagesInBlock, param.ioUnitInPage));` | Create a `Block` object for index `i` and append to **free list** (not yet in `blocks`). |
| 46 | `  }` | End physical-block loop. |
| 47 | *(blank)* | |
| 48 | `  nFreeBlocks = param.totalPhysicalBlocks;` | Counter: all blocks start free. |
| 49 | *(blank)* | |
| 50 | `  status.totalLogicalPages = param.totalLogicalBlocks * param.pagesInBlock;` | Publish total LPN space in public `status` struct. |
| 51 | *(blank)* | |
| 52 | `  // Allocate free blocks` | Comment: pull blocks from free pool into write pointers. |
| 53 | `  for (uint32_t i = 0; i < param.pageCountToMaxPerf; i++) {` | For each parallel write stream `0 … pageCountToMaxPerf-1`. |
| 54 | `    lastFreeBlock.at(i) = getFreeBlock(i);` | Allocate one physical block for that stream (see [04_free_blocks.md](04_free_blocks.md)). |
| 55 | `  }` | End lastFreeBlock init loop. |
| 56 | *(blank)* | |
| 57 | `  lastFreeBlockIndex = 0;` | Rotate which stream is “current” for the next superpage write. |
| 58 | *(blank)* | |
| 59 | `  memset(&stat, 0, sizeof(stat));` | Zero all FTL stats including CMT counters. |
| 60 | *(blank)* | |
| 61 | `  bRandomTweak = conf.readBoolean(CONFIG_FTL, FTL_USE_RANDOM_IO_TWEAK);` | Config: enable superpage / sub-page mapping (`EnableRandomIOTweak`). |
| 62 | `  bitsetSize = bRandomTweak ? param.ioUnitInPage : 1;` | One CMT/GMT entry holds `bitsetSize` (block,page) pairs — 8 when tweak on, 1 when off. |
| 63 | *(blank)* | |
| 64 | `  cmtPolicy = (CMT_POLICY)conf.readInt(CONFIG_FTL, FTL_CMT_POLICY);` | `0` = LRU, `1` = LFU (`CMTPolicy` in config). |
| 65 | *(blank)* | |
| 66–71 | Comment block | Explains **cmtEntryBytes = 8 × bitsetSize**: each sub-mapping is 4B LPN + 4B PPN metaphor; byte-based cache sizing must not undercount entries. |
| 72 | `  cmtEntryBytes = 8 * bitsetSize;` | Bytes of mapping payload per CMT entry (not counting policy metadata). |
| 73 | *(blank)* | |
| 74 | `  float cmtRatio = conf.readFloat(CONFIG_FTL, FTL_CMT_CAPACITY_RATIO);` | If &gt; 0, size CMT as fraction of logical pages. |
| 75 | `  if (cmtRatio > 0.0f) {` | Ratio path preferred when configured. |
| 76 | `    cmtCapacity = (uint64_t)((float)status.totalLogicalPages * cmtRatio);` | Entry count = total LPNs × ratio. |
| 77 | `  }` | |
| 78 | `  else {` | Fallback: absolute byte budget. |
| 79 | `    uint64_t cmtBytes = conf.readUint(CONFIG_FTL, FTL_CMT_CAPACITY_BYTES);` | e.g. `CMTCapacityBytes` from config. |
| 80 | `    cmtCapacity = cmtBytes / cmtEntryBytes;` | Convert bytes → number of **entries** (superpages). |
| 81 | `  }` | |
| 82 | `  if (cmtCapacity < 16) cmtCapacity = 16;` | Floor: tiny caches are unrealistic and break experiments. |
| 83 | *(blank)* | |
| 84 | `  // DFTL "double read" penalty: NAND flash read latency on CMT miss` | Comment for miss latency knob. |
| 85 | `  cmtMissLatency = conf.readUint(CONFIG_FTL, FTL_CMT_MISS_LATENCY);` | Picoseconds added on CMT miss ([06_cmt_access.md](06_cmt_access.md)). |
| 86 | `  // NAND flash program latency for dirty write-back on eviction` | Comment for write-back latency. |
| 87 | `  cmtWriteBackLatency = conf.readUint(CONFIG_FTL, FTL_CMT_WRITEBACK_LATENCY);` | Picoseconds on dirty eviction write-back. |
| 88 | `  cmtMinFreq = 0;` | LFU: smallest occupied frequency bucket; 0 = empty cache. |
| 89 | *(blank)* | |
| 90–94 | `debugprint(...)` | Log policy name, `cmtCapacity`, `cmtEntryBytes`, `bitsetSize`, total bytes. |
| 95 | `}` | Constructor end. |

### Invariants after constructor

- `freeBlocks.size() == nFreeBlocks == param.totalPhysicalBlocks - param.pageCountToMaxPerf` (exactly `pageCountToMaxPerf` blocks moved to `blocks` via `getFreeBlock`).
- `lastFreeBlock.size() == param.pageCountToMaxPerf`; each element is a valid block index in `blocks`.
- `table` is empty; CMT containers (`cmt`, `cmtLFU`, …) are empty.
- `cmtCapacity >= 16`; `cmtEntryBytes == 8 * bitsetSize`.
- `stat` all zeros.

### Links

- [04_free_blocks.md](04_free_blocks.md) — `getFreeBlock` called during ctor.
- [06_cmt_access.md](06_cmt_access.md) — policies that use `cmtCapacity`, latencies.
- [08_CMT_Mentor_Census.md §12](../08_CMT_Mentor_Census.md) — capacity math.

---

## Section B — Destructor and `flushCMT` (lines 97–127)

### Line range

`page_mapping.cc` **97–127**

### Purpose

On simulation teardown, write **dirty** CMT copies back to GMT so `table` reflects the final mapping. Then clear all CMT structures (no eviction latency — end-of-run coherence only).

### Line-by-line — destructor (97–101)

| Line | Code | Meaning |
| --- | --- | --- |
| 97 | `PageMapping::~PageMapping() {` | Destructor entry. |
| 98–99 | Comment | Dirty entries may be ahead of GMT; flush for inspectability. |
| 100 | `  flushCMT();` | Synchronous write-back of dirty entries; see below. |
| 101 | `}` | Destructor end. |

### Line-by-line — `flushCMT` (103–127)

| Line | Code | Meaning |
| --- | --- | --- |
| 103 | `void PageMapping::flushCMT() {` | Function entry. |
| 104–106 | Comment | Only **dirty** entries need GMT update; clean entries already match `table`. |
| 107 | `  if (cmtPolicy == CMT_POLICY_LFU) {` | Branch on active policy. |
| 108 | `    for (auto &entry : cmtLFU) {` | Iterate all LFU cache entries (unordered_map). |
| 109 | `      if (entry.second.dirty) {` | If mapping was modified in cache. |
| 110 | `        table[entry.first] = entry.second.mapping;` | Copy mapping vector into GMT at LPN `entry.first`. |
| 111 | `      }` | End dirty check. |
| 112 | `    }` | End LFU loop. |
| 113 | `  }` | |
| 114 | `  else {` | LRU path. |
| 115 | `    for (auto &entry : cmt) {` | Iterate LRU hash map. |
| 116 | `      if (entry.second.first.dirty) {` | `pair<CMTEntry, list iterator>` — entry is `.first`. |
| 117 | `        table[entry.first] = entry.second.first.mapping;` | Write dirty mapping to GMT. |
| 118 | `      }` | |
| 119 | `    }` | |
| 120 | `  }` | End policy branch. |
| 121 | *(blank)* | |
| 122 | `  cmt.clear();` | Empty LRU store. |
| 123 | `  cmtOrder.clear();` | Empty LRU order list. |
| 124 | `  cmtLFU.clear();` | Empty LFU store. |
| 125 | `  cmtFreqBuckets.clear();` | Empty LFU frequency buckets. |
| 126 | `  cmtMinFreq = 0;` | Reset LFU eviction pointer. |
| 127 | `}` | |

### Invariants

- After `flushCMT`, every dirty CMT mapping is identical in `table`.
- **No** `tick` penalty and **no** `stat.cmtWritebacks` increment (README open question #4).
- Cache is empty; subsequent lookups go to GMT only until repopulated.

### Links

- [06_cmt_access.md](06_cmt_access.md) — dirty eviction path charges `cmtWriteBackLatency` during simulation; `flushCMT` does not.

---

## Section C — `repairLFUMinFreq` (lines 129–142)

### Line range

`page_mapping.cc` **129–142**

### Purpose

When the LFU bucket at `cmtMinFreq` becomes empty (erase or eviction), point `cmtMinFreq` at the **smallest frequency that still has entries**, or `0` if the cache is empty. Eviction uses `cmtFreqBuckets[cmtMinFreq]` — this repair prevents accessing a missing bucket.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 129 | `void PageMapping::repairLFUMinFreq() {` | Entry. |
| 130 | `  if (cmtFreqBuckets.empty()) {` | No frequency buckets left. |
| 131 | `    cmtMinFreq = 0;` | Empty cache convention. |
| 132 | `    return;` | Early exit. |
| 133 | `  }` | |
| 134 | *(blank)* | |
| 135 | `  cmtMinFreq = cmtFreqBuckets.begin()->first;` | Initial guess: arbitrary bucket key (unordered_map begin). |
| 136 | *(blank)* | |
| 137 | `  for (const auto &bucket : cmtFreqBuckets) {` | Scan all occupied frequencies. |
| 138 | `    if (bucket.first < cmtMinFreq) {` | Found a smaller frequency. |
| 139 | `      cmtMinFreq = bucket.first;` | Update minimum. |
| 140 | `    }` | |
| 141 | `  }` | |
| 142 | `}` | |

### Invariants

- After repair: if cache non-empty, `cmtFreqBuckets.count(cmtMinFreq) > 0` and `cmtMinFreq` is the global minimum key in `cmtFreqBuckets`.
- If cache empty: `cmtMinFreq == 0`.

### Links

- [06_cmt_access.md](06_cmt_access.md) — LFU eviction reads `cmtFreqBuckets[cmtMinFreq].back()`.
- Called from `cmtErase` (this chapter) and LFU eviction in Chapter 6.

---

## Section D — `cmtErase` (lines 144–179)

### Line range

`page_mapping.cc` **144–179**

### Purpose

Remove one LPN from the active CMT **without write-back**. Used when the mapping is **destroyed** (trim/format) — writing back would resurrect a dead mapping in GMT.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 144 | `void PageMapping::cmtErase(uint64_t lpn) {` | Entry: logical page to drop. |
| 145–146 | Comment | No GMT update — caller is deleting the mapping. |
| 147 | `  if (cmtPolicy == CMT_POLICY_LFU) {` | LFU branch. |
| 148 | `    auto iter = cmtLFU.find(lpn);` | Lookup LPN in LFU map. |
| 149 | *(blank)* | |
| 150 | `    if (iter != cmtLFU.end()) {` | Entry exists in cache. |
| 151 | `      uint64_t freq = iter->second.freq;` | Current frequency of this entry. |
| 152 | `      auto bucket = cmtFreqBuckets.find(freq);` | Find list at that frequency. |
| 153 | *(blank)* | |
| 154 | `      if (bucket != cmtFreqBuckets.end()) {` | Bucket should exist if entry exists. |
| 155 | `        bucket->second.erase(iter->second.listIt);` | O(1) remove from freq list via stored iterator. |
| 156 | *(blank)* | |
| 157 | `        if (bucket->second.empty()) {` | Frequency level now empty. |
| 158 | `          cmtFreqBuckets.erase(bucket);` | Remove empty bucket from map. |
| 159 | *(blank)* | |
| 160–161 | Comment | Eviction uses `cmtFreqBuckets[cmtMinFreq]`; repair if we emptied min bucket. |
| 162 | `          if (freq == cmtMinFreq) {` | We removed last entry at min frequency. |
| 163 | `            repairLFUMinFreq();` | Recompute minimum occupied freq. |
| 164 | `          }` | |
| 165 | `        }` | End empty-bucket handling. |
| 166 | `      }` | |
| 167 | *(blank)* | |
| 168 | `      cmtLFU.erase(iter);` | Remove main LFU entry for this LPN. |
| 169 | `    }` | End if found. |
| 170 | `  }` | End LFU branch. |
| 171 | `  else {` | LRU branch. |
| 172 | `    auto iter = cmt.find(lpn);` | Lookup in LRU map. |
| 173 | *(blank)* | |
| 174 | `    if (iter != cmt.end()) {` | If resident. |
| 175 | `      cmtOrder.erase(iter->second.second);` | Remove LPN from LRU order list (iterator stored in pair). |
| 176 | `      cmt.erase(iter);` | Remove from hash map. |
| 177 | `    }` | |
| 178 | `  }` | |
| 179 | `}` | |

### Invariants

- GMT unchanged by `cmtErase`.
- If LPN was in CMT, it is absent from all policy structures after return.
- Dirty bit ignored — intentional data loss of cached copy (mapping is being destroyed).

### Links

- [03_public_io.md](03_public_io.md) — `format` calls `cmtErase`.
- [07_internal_io.md](07_internal_io.md) — `trimInternal` uses `cmtErase`.

---

## Section E — `getLiveMapping` (lines 181–207)

### Line range

`page_mapping.cc` **181–207**

### Purpose

Return a pointer to the **authoritative** mapping vector for an LPN: CMT copy if resident (may be dirty and ahead of GMT), else GMT. **No** cache insertion, **no** stats, **no** latency — read-only coherence helper for destroy paths.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 181 | `std::vector<std::pair<uint32_t, uint32_t>> *PageMapping::getLiveMapping(` | Return type: pointer to mapping vector (block idx, page idx per sub-page). |
| 182 | `    uint64_t lpn) {` | Parameter: logical page number. |
| 183–184 | Comment | CMT may hold newer PPN; GMT may have sentinel or stale PPN until write-back. |
| 185 | `  if (cmtPolicy == CMT_POLICY_LFU) {` | LFU branch. |
| 186 | `    auto it = cmtLFU.find(lpn);` | CMT lookup. |
| 187 | *(blank)* | |
| 188 | `    if (it != cmtLFU.end()) {` | Hit in CMT. |
| 189 | `      return &it->second.mapping;` | Return address of mapping vector inside entry. |
| 190 | `    }` | |
| 191 | `  }` | |
| 192 | `  else {` | LRU branch. |
| 193 | `    auto it = cmt.find(lpn);` | CMT lookup. |
| 194 | *(blank)* | |
| 195 | `    if (it != cmt.end()) {` | Hit. |
| 196 | `      return &it->second.first.mapping;` | LRU stores `pair<CMTEntry, list::iterator>`. |
| 197 | `    }` | |
| 198 | `  }` | |
| 199 | *(blank)* | |
| 200 | `  auto gmtIt = table.find(lpn);` | Fall back to GMT. |
| 201 | *(blank)* | |
| 202 | `  if (gmtIt == table.end()) {` | Never mapped. |
| 203 | `    return nullptr;` | No mapping exists. |
| 204 | `  }` | |
| 205 | *(blank)* | |
| 206 | `  return &gmtIt->second;` | Return GMT vector pointer. |
| 207 | `}` | |

### Invariants

- Never modifies CMT or GMT.
- Returned pointer valid until concurrent mutation of that LPN (caller must not hold across `writeInternal` etc.).

### Links

- [03_public_io.md](03_public_io.md) — `format` uses `getLiveMapping`.
- Contrast [06_cmt_access.md](06_cmt_access.md) — `accessCMT` may allocate, count stats, add latency.

---

## Section F — `cmtSize` and `resetCMTStats` (lines 209–221)

### Line range

`page_mapping.cc` **209–221**

### Purpose

`cmtSize()` — resident entry count for active policy. `resetCMTStats()` — zero CMT counters after warm-up so measured workload hit rate is not drowned by compulsory misses.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 209 | `uint64_t PageMapping::cmtSize() const {` | Const query; no state change. |
| 210 | `  return cmtPolicy == CMT_POLICY_LFU ? cmtLFU.size() : cmt.size();` | Size of active policy's hash map. |
| 211 | `}` | |
| 212 | *(blank)* | |
| 213 | `void PageMapping::resetCMTStats() {` | Zero counters only. |
| 214 | `  stat.cmtHits = 0;` | User/GC hits cleared. |
| 215 | `  stat.cmtMisses = 0;` | User misses cleared. |
| 216 | `  stat.cmtEvictions = 0;` | Eviction count cleared. |
| 217 | `  stat.cmtDirtyEvictions = 0;` | Dirty eviction count cleared. |
| 218 | `  stat.cmtWritebacks = 0;` | Write-back ops cleared. |
| 219 | `  stat.cmtGCHits = 0;` | GC-path hits cleared. |
| 220 | `  stat.cmtGCMisses = 0;` | GC-path misses cleared. |
| 221 | `}` | |

### Invariants

- `resetCMTStats` does **not** clear `stat.gcCount`, wear stats, or CMT **contents**.
- `cmtSize()` equals number of LPN keys in `cmtLFU` or `cmt`.

### Links

- [06_cmt_access.md](06_cmt_access.md) — increments these counters during `accessCMT`.

---

## Section G — `initialize()` (lines 223–351)

### Line range

`page_mapping.cc` **223–351**

### Purpose

**Warm-up** before the benchmark trace: fill a configurable fraction of logical pages (sequential or random), then overwrite a fraction to create **invalid** physical pages (GC pressure), clamp fill to avoid exhausting free blocks, report valid/invalid counts, then **reset CMT stats** while keeping cache hot.

### Line-by-line — setup (223–264)

| Line | Code | Meaning |
| --- | --- | --- |
| 223 | `bool PageMapping::initialize() {` | Returns `true` on success (always here). |
| 224 | `  uint64_t nPagesToWarmup;` | Target valid pages after fill. |
| 225 | `  uint64_t nPagesToInvalidate;` | Target invalid pages after second pass. |
| 226 | `  uint64_t nTotalLogicalPages;` | Total LPN count. |
| 227 | `  uint64_t maxPagesBeforeGC;` | Max mapped pages before GC would be forced. |
| 228 | `  uint64_t tick;` | Simulated time (always 0 in warm-up loops). |
| 229 | `  uint64_t valid;` | For `calculateTotalPages` report. |
| 230 | `  uint64_t invalid;` | For report. |
| 231 | `  FILLING_MODE mode;` | Enum: how to choose LPNs in each step. |
| 232 | *(blank)* | |
| 233 | `  Request req(param.ioUnitInPage);` | FTL request with correct ioFlag bitset width. |
| 234 | *(blank)* | |
| 235 | `  debugprint(LOG_FTL_PAGE_MAPPING, "Initialization started");` | Log marker. |
| 236 | *(blank)* | |
| 237 | `  nTotalLogicalPages = param.totalLogicalBlocks * param.pagesInBlock;` | Same as `status.totalLogicalPages`. |
| 238 | `  nPagesToWarmup =` | Start warmup count. |
| 239 | `      nTotalLogicalPages * conf.readFloat(CONFIG_FTL, FTL_FILL_RATIO);` | `FillRatio` × all LPNs. |
| 240 | `  nPagesToInvalidate =` | Start invalidation count. |
| 241 | `      nTotalLogicalPages * conf.readFloat(CONFIG_FTL, FTL_INVALID_PAGE_RATIO);` | `InvalidPageRatio` × all LPNs. |
| 242 | `  mode = (FILLING_MODE)conf.readUint(CONFIG_FTL, FTL_FILLING_MODE);` | `0`, `1`, or `2` — see below. |
| 243 | `  maxPagesBeforeGC =` | Compute headroom before GC threshold. |
| 244 | `      param.pagesInBlock *` | Pages per block × … |
| 245 | `      (param.totalPhysicalBlocks *` | … total blocks × … |
| 246 | `           (1 - conf.readFloat(CONFIG_FTL, FTL_GC_THRESHOLD_RATIO)) -` | … fraction allowed in use at GC threshold − … |
| 247 | `       param.pageCountToMaxPerf);` | … minus blocks reserved as write pointers. |
| 248 | *(blank)* | Comment: free blocks to maintain. |
| 249 | `  if (nPagesToWarmup + nPagesToInvalidate > maxPagesBeforeGC) {` | Fill would exceed safe capacity. |
| 250 | `    warn("ftl: Too high filling ratio. Adjusting invalidPageRatio.");` | User warning. |
| 251 | `    nPagesToInvalidate = maxPagesBeforeGC - nPagesToWarmup;` | Clamp invalidation count. |
| 252 | `  }` | |
| 253–262 | `debugprint` ×3 | Log totals and percentages for warmup and invalidate targets. |
| 263 | *(blank)* | |
| 264 | `  req.ioFlag.set();` | Full superpage write — all sub-pages in `bitsetSize`. |

### Filling modes

| `FILLING_MODE` | Step 1 (warmup) | Step 2 (invalidate) |
| --- | --- | --- |
| `0` | Sequential LPN `0…n-1` | Sequential LPN `0…m-1` (overwrite) |
| `1` | Sequential | Random LPN in `[0, nPagesToWarmup)` |
| `2` | Random LPN in `[0, nTotalLogicalPages)` | Random LPN in full range |

### Line-by-line — Step 1 Filling (266–286)

| Line | Code | Meaning |
| --- | --- | --- |
| 266 | `  // Step 1. Filling` | Comment. |
| 267 | `  if (mode == FILLING_MODE_0 || mode == FILLING_MODE_1) {` | Modes 0 and 1: sequential warmup. |
| 268 | `    // Sequential` | Comment. |
| 269 | `    for (uint64_t i = 0; i < nPagesToWarmup; i++) {` | One write per target valid page. |
| 270 | `      tick = 0;` | Reset time — warm-up not charged to benchmark clock. |
| 271 | `      req.lpn = i;` | LPN = loop index. |
| 272 | `      writeInternal(req, tick, false);` | Internal write; `false` = not user I/O (stats/latency semantics in Chapter 7). |
| 273 | `    }` | |
| 274 | `  }` | |
| 275 | `  else {` | Mode 2: random warmup. |
| 276 | `    // Random` | Comment. |
| 277 | `    std::random_device rd;` | Seed entropy source. |
| 278 | `    std::mt19937_64 gen(rd());` | 64-bit Mersenne Twister PRNG. |
| 279 | `    std::uniform_int_distribution<uint64_t> dist(0, nTotalLogicalPages - 1);` | Uniform LPN range. |
| 280 | *(blank)* | |
| 281 | `    for (uint64_t i = 0; i < nPagesToWarmup; i++) {` | Same count as sequential path. |
| 282 | `      tick = 0;` | |
| 283 | `      req.lpn = dist(gen);` | Random LPN each iteration. |
| 284 | `      writeInternal(req, tick, false);` | |
| 285 | `    }` | |
| 286 | `  }` | |

### Line-by-line — Step 2 Invalidating (288–322)

| Line | Code | Meaning |
| --- | --- | --- |
| 288 | `  // Step 2. Invalidating` | Comment. |
| 289 | `  if (mode == FILLING_MODE_0) {` | Mode 0: sequential overwrite. |
| 290 | `    // Sequential` | |
| 291 | `    for (uint64_t i = 0; i < nPagesToInvalidate; i++) {` | |
| 292 | `      tick = 0;` | |
| 293 | `      req.lpn = i;` | Same LPNs as early sequential fill → invalidates old physical pages. |
| 294 | `      writeInternal(req, tick, false);` | |
| 295 | `    }` | |
| 296 | `  }` | |
| 297 | `  else if (mode == FILLING_MODE_1) {` | Mode 1: random invalidation within warmed range. |
| 298 | `    // Random` | |
| 299–300 | Comment | Random range `[0, nPagesToWarmup)` works because step 1 was sequential. |
| 301 | `    std::random_device rd;` | |
| 302 | `    std::mt19937_64 gen(rd());` | |
| 303 | `    std::uniform_int_distribution<uint64_t> dist(0, nPagesToWarmup - 1);` | Only LPNs that were written in step 1. |
| 304 | *(blank)* | |
| 305 | `    for (uint64_t i = 0; i < nPagesToInvalidate; i++) {` | |
| 306 | `      tick = 0;` | |
| 307 | `      req.lpn = dist(gen);` | |
| 308 | `      writeInternal(req, tick, false);` | |
| 309 | `    }` | |
| 310 | `  }` | |
| 311 | `  else {` | Mode 2: fully random invalidation. |
| 312 | `    // Random` | |
| 313 | `    std::random_device rd;` | |
| 314 | `    std::mt19937_64 gen(rd());` | |
| 315 | `    std::uniform_int_distribution<uint64_t> dist(0, nTotalLogicalPages - 1);` | Full LPN space. |
| 316 | *(blank)* | |
| 317 | `    for (uint64_t i = 0; i < nPagesToInvalidate; i++) {` | |
| 318 | `      tick = 0;` | |
| 319 | `      req.lpn = dist(gen);` | |
| 320 | `      writeInternal(req, tick, false);` | |
| 321 | `    }` | |
| 322 | `  }` | |

### Line-by-line — Report and CMT reset (324–351)

| Line | Code | Meaning |
| --- | --- | --- |
| 324 | `  // Report` | Comment. |
| 325 | `  calculateTotalPages(valid, invalid);` | Scan blocks for valid/invalid physical page counts ([08_wear_stats.md](08_wear_stats.md)). |
| 326 | `  debugprint(LOG_FTL_PAGE_MAPPING, "Filling finished. Page status:");` | |
| 327–331 | `debugprint` (valid) | Log valid count, %, target, error vs `nPagesToWarmup`. |
| 332–336 | `debugprint` (invalid) | Log invalid count, %, target, error vs `nPagesToInvalidate`. |
| 337 | *(blank)* | |
| 338–341 | Comment | Warm-up compulsory misses would skew hit rate; zero counters only. |
| 342–345 | `debugprint` (CMT warm-up) | Log discarded hit/miss counts and resident `cmtSize()`. |
| 346 | `  resetCMTStats();` | Clear CMT counters (Section F). |
| 347 | *(blank)* | |
| 348 | `  debugprint(LOG_FTL_PAGE_MAPPING, "Initialization finished");` | |
| 349 | *(blank)* | |
| 350 | `  return true;` | Success. |
| 351 | `}` | |

### Invariants after `initialize`

- Drive holds ≈ `nPagesToWarmup` valid and ≈ `nPagesToInvalidate` invalid physical pages (subject to geometry).
- CMT may be full or partial — **contents** reflect warm-up traffic.
- `stat.cmtHits`, `stat.cmtMisses`, etc. are **zero**; GC stats from warm-up may be non-zero.
- `tick` was not advanced by warm-up loops (always passed as 0).

### Links

- [07_internal_io.md](07_internal_io.md) — `writeInternal` implementation.
- [06_cmt_access.md](06_cmt_access.md) — every warm-up write touches CMT.

---

## Self-quiz

1. Why does the constructor call `getFreeBlock` `pageCountToMaxPerf` times before any user I/O?
2. How is `cmtCapacity` computed when `CMTCapacityRatio > 0` vs when ratio is 0?
3. Why is `cmtEntryBytes = 8 * bitsetSize` instead of 8?
4. What does `flushCMT` do to **clean** entries?
5. Why does `cmtErase` never write dirty data back to GMT?
6. When should you call `getLiveMapping` instead of `accessCMT`?
7. What is the purpose of `repairLFUMinFreq`?
8. Why does `initialize` call `resetCMTStats` but not clear the CMT?
9. How is `maxPagesBeforeGC` derived and why does warm-up clamp `nPagesToInvalidate`?
10. What do filling modes 0, 1, and 2 differ on?

### Answers

<details>
<summary>Click to reveal answers</summary>

1. **Write pointers:** Each parallel stream (`pageCountToMaxPerf`) needs an open block to accept programs immediately; `lastFreeBlock[i]` holds that block index per stream ([04_free_blocks.md](04_free_blocks.md)).

2. **Ratio path:** `cmtCapacity = totalLogicalPages × CMTCapacityRatio`. **Byte path:** `cmtCapacity = CMTCapacityBytes / cmtEntryBytes`. Both floored to at least 16.

3. **Superpages:** With `EnableRandomIOTweak`, one logical entry maps `ioUnitInPage` sub-pages (typically 8). Each sub-mapping is 8 bytes in the DFTL model (4B + 4B), so one CMT entry holds `8 × bitsetSize` bytes of mapping data.

4. **Nothing:** Clean entries already match GMT; only dirty entries are copied to `table`. Then all CMT structures are cleared.

5. **Destroy path:** The mapping is being deleted (trim/format). Write-back would put the doomed mapping back into GMT and break coherence.

6. **`getLiveMapping`** when you need the current PPN without loading the LPN into cache, without stats, and without latency — e.g. `format` scanning GMT while invalidating physical pages.

7. **LFU eviction safety:** After removing the last LPN at frequency `f`, if `f == cmtMinFreq`, eviction must not use an empty bucket; repair finds the next smallest occupied frequency.

8. **Hit rate measurement:** Warm-up causes millions of compulsory misses; zeroing counters lets exported stats describe the **benchmark trace** while the cache stays warm like a real powered-on drive.

9. **Headroom:** `pagesInBlock × (totalPhysicalBlocks × (1 - GCThreshold) - pageCountToMaxPerf)` estimates max pages mappable before GC must reclaim, accounting for reserved write-pointer blocks. If warmup + invalidate exceeds that, invalidation is reduced so the drive does not dead-end during fill.

10. **Mode 0:** sequential fill + sequential overwrite. **Mode 1:** sequential fill + random overwrite in `[0, warmup)`. **Mode 2:** random fill + random overwrite over full LPN space.

</details>
