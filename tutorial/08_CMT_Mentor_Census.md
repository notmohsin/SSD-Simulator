# CMT Implementation Census — The Whole Picture

*A single document that explains the SSD problem, what SimpleSSD did before CMT, every piece of CMT code you added in `simplessd/`, how each path works with worked examples, what went wrong and was fixed, and how to read your results. Written so you can understand the system end-to-end, not only answer a mentor in sixty seconds.*

**For line-by-line code annotations of `page_mapping.{hh,cc}`, see [`page_mapping/README.md`](page_mapping/README.md).**

Companion docs (narrower focus):

| Doc | Use for |
| --- | --- |
| [`page_mapping/README.md`](page_mapping/README.md) | Annotated blocks for every function in `page_mapping.{hh,cc}` |
| [`architecture/README.md`](architecture/README.md) | The simulator around the FTL: event model, boot order, layer contracts, `ftl.cc` / `block.cc` / `config.cc`, end-to-end traces |
| [`cmt_guide.md`](cmt_guide.md) | Gentler CMT intro (may lag fixes in places) |
| [`06_CMT_Deep_Dive.md`](06_CMT_Deep_Dive.md) | Structure-focused deep dive |
| [`07_CMT_Review_And_Fixes.md`](07_CMT_Review_And_Fixes.md) | Bug postmortem only |
| **This file** | Full picture: census + theory + code + experiments |

---

## Table of Contents

1. [How to use this document](#1-how-to-use-this-document)
2. [Glossary](#2-glossary)
3. [SSD basics you need before CMT](#3-ssd-basics-you-need-before-cmt)
4. [Where SimpleSSD sits: the stack](#4-where-simplessd-sits-the-stack)
5. [What PageMapping looked like BEFORE CMT](#5-what-pagemapping-looked-like-before-cmt)
6. [The real-world problem: mapping tables do not fit in SRAM](#6-the-real-world-problem-mapping-tables-do-not-fit-in-sram)
7. [DFTL in plain language](#7-dftl-in-plain-language)
8. [What YOU built: the one-sentence pitch and the honest model](#8-what-you-built-the-one-sentence-pitch-and-the-honest-model)
9. [File census — every touched file](#9-file-census--every-touched-file)
10. [Timeline of your work](#10-timeline-of-your-work)
11. [Config knobs — what each one actually does](#11-config-knobs--what-each-one-actually-does)
12. [Capacity math — the most important calculation](#12-capacity-math--the-most-important-calculation)
13. [Superpages and `bitsetSize` — why one “entry” is 64 bytes](#13-superpages-and-bitsetsize--why-one-entry-is-64-bytes)
14. [Data structures in full](#14-data-structures-in-full)
15. [Dirty vs clean — a timeline you can draw on a whiteboard](#15-dirty-vs-clean--a-timeline-you-can-draw-on-a-whiteboard)
16. [The CMT API — every function and when to use it](#16-the-cmt-api--every-function-and-when-to-use-it)
17. [End-to-end: one READ](#17-end-to-end-one-read)
18. [End-to-end: one WRITE](#18-end-to-end-one-write)
19. [End-to-end: TRIM and FORMAT](#19-end-to-end-trim-and-format)
20. [End-to-end: GC and warm-up](#20-end-to-end-gc-and-warm-up)
21. [LRU worked example (small cache)](#21-lru-worked-example-small-cache)
22. [LFU worked example (same trace)](#22-lfu-worked-example-same-trace)
23. [LRU implementation walkthrough](#23-lru-implementation-walkthrough)
24. [LFU implementation walkthrough](#24-lfu-implementation-walkthrough)
25. [Latency model — what adds to `tick`](#25-latency-model--what-adds-to-tick)
26. [Statistics — how to read an output file](#26-statistics--how-to-read-an-output-file)
27. [Bugs found and fixed — with “why it mattered”](#27-bugs-found-and-fixed--with-why-it-mattered)
28. [Fidelity limits — say these out loud](#28-fidelity-limits--say-these-out-loud)
29. [Experiments — what you ran and what it means](#29-experiments--what-you-ran-and-what-it-means)
30. [How the pieces connect (mental map)](#30-how-the-pieces-connect-mental-map)
31. [Mentor Q&A (expanded)](#31-mentor-qa-expanded)
32. [Study checklist — can you explain X?](#32-study-checklist--can-you-explain-x)
33. [Quick reference card](#33-quick-reference-card)

---

## 1. How to use this document

Read in this order the first time:

1. Sections **2–8** — build the mental model (SSD → SimpleSSD → why CMT → what you actually modelled).
2. Sections **11–16** — config, capacity, structures, dirty bit, API.
3. Sections **17–22** — follow real I/O with small examples until it clicks.
4. Sections **23–27** — map examples back to code and to the bugs you fixed.
5. Sections **28–31** — experiments, honesty about the model, viva prep.

If you only have twenty minutes before a meeting: **8, 12, 15, 21, 28, 31**.

---

## 2. Glossary

| Term | Meaning in this project |
| --- | --- |
| **LPN** | Logical Page Number — host-facing address unit after the FTL divides the request into pages |
| **PPN** | Physical location — here a pair `(blockIndex, pageIndex)` inside a NAND block |
| **GMT** | Global Mapping Table — full map LPN → vector of PPNs. In code: `PageMapping::table` |
| **CMT** | Cached Mapping Table — small cache of GMT entries with a replacement policy |
| **FTL** | Flash Translation Layer — software that owns mapping, GC, wear leveling |
| **PAL** | Physical Abstraction Layer — issues NAND read/program/erase in the simulator |
| **HIL** | Host Interface Layer — NVMe/SATA-facing side |
| **ICL** | Internal Cache Layer — data cache (read/write cache); **disabled** in your sweeps |
| **BIL** | Block I/O Layer — host request generator / scheduler in Standalone |
| **Dirty entry** | CMT copy was written; GMT may be stale until write-back or flush |
| **Miss latency** | Synthetic cost for “read translation page from NAND” (`CMTMissLatency`) |
| **Write-back latency** | Synthetic cost for “program dirty translation page” (`CMTWriteBackLatency`) |
| **`bitsetSize`** | How many sub-page mappings one LPN entry holds (`ioUnitInPage` if random-I/O tweak on) |
| **Superpage** | Parallel stripe across dies/planes; one logical write may touch multiple sub-pages |
| **Warm-up / fill** | `initialize()` prefills the drive so the workload does not start empty |
| **`tick`** | Simulated time in picoseconds; latencies are added to this counter |
| **LRU** | Evict least *recently* used |
| **LFU** | Evict least *frequently* used (ties broken by recency in your code) |
| **DFTL** | Demand-based Flash Translation Layer (Gupta et al., ASPLOS ’09) — paper that motivates CMT |

---

## 3. SSD basics you need before CMT

### 3.1 Flash cannot overwrite in place

NAND flash pages are written once, then must be **erased** (at block granularity) before rewrite. So an SSD almost never updates a page “in place.” A host write to logical address L becomes:

1. Allocate a **new** free physical page.
2. Program the data there.
3. Update the mapping so L now points to the new page.
4. Mark the old physical page **invalid**.

That mapping update is the heart of the FTL.

### 3.2 Why a mapping table exists

The host thinks in a flat logical address space. Flash is organised as:

```
channels → packages → dies → planes → blocks → pages
```

The FTL hides that. Every host read/write needs: **LPN → PPN** before PAL can touch NAND.

### 3.3 Garbage collection (GC)

As invalid pages pile up, free space runs out. GC:

1. Picks a victim block (often “fewest valid pages” = greedy).
2. **Reads** still-valid pages out.
3. **Writes** them elsewhere (extra programs → write amplification).
4. Erases the victim block.

GC also needs mappings (to find which LPNs live in the victim, and to update them after relocation). Your CMT is consulted on that path too.

### 3.4 Controllers are memory-poor relative to the map

A large drive’s full page map is hundreds of MB. Controller SRAM/DRAM is smaller and expensive. Real devices therefore **cache** hot mappings and keep the rest on flash as **translation pages**. That cache is what DFTL calls the CMT.

---

## 4. Where SimpleSSD sits: the stack

SimpleSSD-Standalone is a discrete-event simulator. A request roughly travels:

```
Request generator (BIL / IGL)
        ↓
SIL (NVMe driver emulation)
        ↓
HIL (host interface)
        ↓
ICL (optional data cache)     ← you set EnableRead/WriteCache = 0 in sweeps
        ↓
FTL::PageMapping              ← *** YOUR CMT LIVES HERE ***
        ↓
PAL (NAND timing / energy)
        ↓
(simulated flash)
```

**Important separation:**

- **Data path:** host payload bytes → eventually PAL read/program.
- **Mapping path:** LPN lookup → used to choose which physical page PAL touches.

Your CMT only sits on the **mapping path**. It does not cache user data. That is ICL’s job (and you turned ICL off so CMT effects are not mixed with data-cache effects).

### Simulation time

Almost everything interesting adds to `uint64_t tick` (picoseconds). When you see:

```cpp
tick += cmtMissLatency;
```

you are saying: “this operation costs this much simulated time,” not “wait on a wall clock.” Wall-clock time of the simulator process is separate (`Host time duration` in the run summary).

---

## 5. What PageMapping looked like BEFORE CMT

Before your work, mapping lookup was essentially:

```cpp
auto iter = table.find(req.lpn);
// use iter->second as the vector of (block, page) pairs
```

`table` is:

```cpp
std::unordered_map<uint64_t, std::vector<std::pair<uint32_t, uint32_t>>> table;
//                 LPN        [ sub0:(blk,page), sub1:(blk,page), ... ]
```

So:

- Every LPN that has ever been written has an entry in host RAM.
- Lookup cost in the *model* was basically a hash lookup + optional DRAM-model access timing.
- There was **no** notion of “mapping cache too small,” “evict a translation entry,” or “pay for loading a translation page.”

**What you changed conceptually:** every hot-path lookup that used to hit `table` directly now goes through a **size-limited cache** first. `table` remains the full GMT (ground truth in the simulator). The CMT is an overlay that adds **capacity pressure** and **synthetic translation I/O cost**.

---

## 6. The real-world problem: mapping tables do not fit in SRAM

Numeric intuition (same style as the guide):

- 128 GB SSD, 4 KB pages → about 33.5 million pages.
- 8 bytes per mapping → about **268 MB** for a full page map.

Controller DRAM might be tens of MB. You cannot keep the whole map hot. Strategies:

| Strategy | Idea | Pain |
| --- | --- | --- |
| Block mapping | One map entry per block | Bad random-write behaviour |
| Hybrid | Mix page/block maps | Complex |
| Page mapping + cache (DFTL) | Full page map on NAND, small SRAM cache | Cache misses cost NAND reads |

You implemented the **page mapping + cache** idea *inside* a simulator that still keeps the full map in RAM.

---

## 7. DFTL in plain language

DFTL’s story:

1. Store the full map as **translation pages** on NAND.
2. Keep a small **CMT** of recently used mappings in fast memory.
3. On CMT miss: read the needed translation page from NAND (extra read — “double read” if you also need data).
4. On dirty eviction: write the translation page back (extra program).

Your code names those costs:

- `CMTMissLatency` ≈ cost of step 3.
- `CMTWriteBackLatency` ≈ cost of step 4.

**What DFTL has that you do not:** actual translation pages allocated on flash, a global translation directory, garbage collection of translation pages, etc. See [§28](#28-fidelity-limits--say-these-out-loud).

---

## 8. What YOU built: the one-sentence pitch and the honest model

### Pitch

> I added a DFTL-style **Cached Mapping Table** on SimpleSSD’s page-mapping FTL: a size-limited cache of LPN→PPN mappings with runtime-selectable **LRU** or **LFU**, dirty write-back, synthetic miss/write-back latencies, and coherent destroy paths (trim/format), while the full GMT remains in simulator RAM.

### Honest model (memorise this)

| Real DFTL | Your simulator |
| --- | --- |
| GMT mostly on NAND | GMT always in `std::unordered_map table` |
| Miss = PAL read of translation page | Miss = `tick += CMTMissLatency` |
| Dirty eviction = PAL program of translation page | Dirty eviction = copy into `table` + `tick += CMTWriteBackLatency` |
| Translation page holds many LPNs | One CMT entry = one LPN’s superpage vector |
| CMT in controller SRAM | CMT in process memory, size-capped by config |

You are studying **replacement policy and cache sizing under a DFTL-like cost model**, not re-implementing flash-resident translation storage.

---

## 9. File census — every touched file

CMT code in the `simplessd` submodule touches **only** these six files:

| File | What you added |
| --- | --- |
| [`ftl/page_mapping.hh`](../simplessd/ftl/page_mapping.hh) | CMT members (LRU + LFU), method declarations, CMT stats fields |
| [`ftl/page_mapping.cc`](../simplessd/ftl/page_mapping.cc) | Constructor sizing, `accessCMT*`, helpers, call-site rewires, stats export |
| [`ftl/config.hh`](../simplessd/ftl/config.hh) | `FTL_CMT_*` keys, `CMT_POLICY` enum, config fields |
| [`ftl/config.cc`](../simplessd/ftl/config.cc) | Defaults, parsing, validation, `readInt`/`readUint`/`readFloat` |
| [`config/sample.cfg`](../simplessd/config/sample.cfg) | Documented CMT section |
| [`config/gc_test.cfg`](../simplessd/config/gc_test.cfg) | Same CMT section |

**Diff vs pre-CMT (`62e7cbf` → working tree):** roughly **+1355 / −50** lines across those files. First landing commit: `9fcadf1` (2026-07-24). Later uncommitted work adds LFU switch + correctness fixes (~+573/−68 vs that commit).

**Not CMT but part of the project (Standalone repo, outside submodule):**

- `run_sweep_2h.sh` / `run_sim.sh` / `run_parallel.sh` — run automation, log layout
- `compare_stats.py` — compare runs
- tutorials under `tutorial/`
- `outputs/sweep_2h_20260806_185300/` — kept results
- `PROGRESS.md` — project status

**Explicitly not modified for CMT:** PAL, DRAM models, NVMe HIL logic (aside from an irrelevant whitespace touch in the first commit).

---

## 10. Timeline of your work

### Phase A — First CMT (Jul 2026, `9fcadf1`)

Goal: make mapping-cache behaviour measurable.

1. Added config keys and defaults.
2. Built LRU CMT (`cmt` + `cmtOrder`).
3. Replaced hot-path `table.find` with cache access.
4. Added miss / dirty-writeback tick penalties.
5. Exported basic CMT stats.
6. Documented knobs in `sample.cfg`.

### Phase B — LFU attempt and silent breakage

1. Began adding LFU structures (`cmtLFU`, frequency buckets).
2. A string-patch script (`activate_lfu.py`) was applied **halfway**: some functions used `cmtLFU` while the accessor still filled LRU `cmt`.
3. Symptoms: flush did not write the live dirty set; occupancy could read 0; format could see stale cache state — **compiled fine**.
4. Lesson: one dispatcher (`accessCMT` / `cmtErase` / `cmtSize`), not six hand edits.

### Phase C — Review and redesign (Aug 2026)

1. Verified LRU algorithm correctness (O(1) splice, write hits update recency).
2. Runtime `CMTPolicy` selecting LRU or LFU.
3. Fixed warm-up contamination, capacity ×8 mislabel, allocate-on-read, trim index-0.
4. Fixed destroy paths (`getLiveMapping`), LFU `cmtMinFreq` repair.
5. Re-swept under corrected accounting.

### Phase D — Review readiness (Aug 7)

1. Deleted ~25G junk outputs; kept one clean sweep dir.
2. Dual-policy smoke tests; mentor census doc (this file).

---

## 11. Config knobs — what each one actually does

Set under `[ftl]` in `simplessd/config/sample.cfg` (and `gc_test.cfg`). Parsed in `ftl/config.cc`.

| Key | Example | Effect |
| --- | --- | --- |
| `CMTPolicy` | `0` or `1` | Which structures `accessCMT` uses |
| `CMTCapacityRatio` | `0.0` | If `> 0`, capacity = fraction of `#logical pages` |
| `CMTCapacityBytes` | `2097152` | Used when ratio is 0; converted to entry count |
| `CMTMissLatency` | `40000000` | ps added on miss load of existing GMT entry |
| `CMTWriteBackLatency` | `500000000` | ps added on dirty eviction |

**Why sweeps set `CMTCapacityRatio = 0.0`:** so the **bytes** knob controls size and labels match `cmt.capacity_bytes`. If you leave the code default ratio `0.01` and forget to set ratio to 0 in a custom cfg, you silently get a 1%-of-LPNs cache instead of your byte budget.

**Validation:** bad policy or ratio outside `[0,1]` → `panic` at config update.

**Related non-CMT knobs that still matter:**

| Key | Why it matters to CMT |
| --- | --- |
| `EnableRandomIOTweak` | Sets `bitsetSize` → entry bytes → capacity entry count |
| `FillRatio` | Warm-up size → how many compulsory misses before reset |
| `EnableReadCache` / `EnableWriteCache` | Must be 0 if you want CMT-only effects |
| `Block` (PAL) | Drive geometry → `#logical pages` → hit-rate denominator |

---

## 12. Capacity math — the most important calculation

Constructor logic (paraphrased from `page_mapping.cc`):

```text
bitsetSize     = EnableRandomIOTweak ? ioUnitInPage : 1
cmtEntryBytes  = 8 * bitsetSize

if CMTCapacityRatio > 0:
    cmtCapacity = totalLogicalPages * ratio
else:
    cmtCapacity = CMTCapacityBytes / cmtEntryBytes

cmtCapacity = max(cmtCapacity, 16)
```

### Worked example (your usual config)

Assume `EnableRandomIOTweak = 1` and `ioUnitInPage = 8` (what you measured on this project):

```text
cmtEntryBytes = 8 * 8 = 64 bytes/entry
CMTCapacityBytes = 2,097,152
cmtCapacity = 2,097,152 / 64 = 32,768 entries
cmt.capacity_bytes (stat) = 32,768 * 64 = 2,097,152  ✓
```

### The bug that misled early results

Early code used `bytes / 8`, as if one entry were one 8-byte mapping. With `bitsetSize = 8` that made a “2 MB” config hold **8×** too many entries (really 16 MB of mapping data). Every point on the size axis was mislabelled. Fixed by dividing by `8 * bitsetSize`.

### How to verify in any output file

Look for:

```text
ftl.page_mapping.cmt.capacity
ftl.page_mapping.cmt.entry_bytes
ftl.page_mapping.cmt.capacity_bytes
```

If `entry_bytes` is 64 and `capacity_bytes` equals your config bytes, sizing is sane.

---

## 13. Superpages and `bitsetSize` — why one “entry” is 64 bytes

NAND can program multiple dies/planes together. SimpleSSD can treat one logical page as a **superpage** with `ioUnitInPage` sub-units.

With `EnableRandomIOTweak = 1`:

- `bitsetSize = ioUnitInPage` (commonly 8 here).
- One GMT/CMT value is a **vector** of `bitsetSize` pairs `(block, page)`.
- A host 4 KB request may only set some bits in `ioFlag`, but the **mapping entry** still stores the whole vector.

Why 8 bytes per sub-mapping in the accounting comment: DFTL-style “4B LPN + 4B PPN” budgeting per slot (your pairs are `(uint32_t, uint32_t)` = 8 bytes). So:

```text
bytes per CMT entry ≈ 8 × bitsetSize
```

**Mental model:** evicting one CMT entry drops the whole superpage’s mapping from the cache, not one 4 KB slice.

**Trim/format implication:** you must scan **all** sub-pages when deciding if anything is mapped. Judging only index 0 was bug #5.

---

## 14. Data structures in full

### 14.1 GMT (unchanged ownership, still authoritative after flush)

```text
table: unordered_map<LPN, vector<(block, page)>>
```

Sentinel for “never mapped sub-page”: `block == totalPhysicalBlocks` (and page = `pagesInBlock`). First write allocates a real block/page and overwrites that slot in the vector (in CMT first if dirty).

### 14.2 LRU structures (`CMTPolicy = 0`)

```text
struct CMTEntry {
  vector<(block,page)> mapping;  // copy of GMT vector (may be newer if dirty)
  bool dirty;
};

cmtOrder: list<LPN>     // front = most recently used, back = victim
cmt: map<LPN, pair<CMTEntry, list_iterator>>
```

Why store the iterator? So a hit can `splice` that node to the front in **O(1)** without searching the list.

### 14.3 LFU structures (`CMTPolicy = 1`)

```text
struct CMTEntryLFU {
  vector<(block,page)> mapping;
  bool dirty;
  uint64_t freq;           // lifetime accesses while resident
  list_iterator listIt;    // position inside cmtFreqBuckets[freq]
};

cmtLFU: map<LPN, CMTEntryLFU>
cmtFreqBuckets: map<freq, list<LPN>>   // front = MRU within that frequency
cmtMinFreq: smallest freq that currently has at least one LPN
```

**Eviction rule:** victim = `cmtFreqBuckets[cmtMinFreq].back()`  
→ least frequency, and among those the least recently used.

**Insert rule:** new entries always start at `freq = 1`, and `cmtMinFreq = 1`.

### 14.4 Only one policy’s maps are live

Both policy structs exist in the class, but only the active policy is populated. All mutations go through policy-aware helpers so they cannot drift apart again (the Phase B failure mode).

---

## 15. Dirty vs clean — a timeline you can draw on a whiteboard

Suppose LPN 42 is not in CMT. Cache has room.

```text
t0  WRITE LPN 42
    miss → create/load GMT → insert CMT, dirty=true
    CMT[42] = new PPN A
    GMT[42] = sentinel or old value   ← may still be STALE

t1  READ LPN 42
    hit → splice/promote, dirty stays true
    uses PPN A from CMT

t2  WRITE LPN 42 again
    hit → dirty=true, CMT[42] = PPN B
    old PPN A invalidated in FTL write path
    GMT[42] still not B until write-back

t3  CMT full, 42 is chosen as victim, dirty
    table[42] = CMT[42]     ← GMT becomes B
    tick += writeBackLatency
    erase from CMT

t4  READ LPN 42
    miss → load GMT (now B) → tick += missLatency → insert clean (unless write)
```

**Destroy path (trim) at t2:**

```text
getLiveMapping(42) → sees CMT copy with PPN B
invalidate B
cmtErase(42)        ← NO write-back (would resurrect mapping)
table.erase(42)
```

If trim/format had used GMT at t2, they might invalidate the wrong page or hit a sentinel and **panic**. That is why `getLiveMapping` exists.

---

## 16. The CMT API — every function and when to use it

| Function | Cache mutation | Stats | Latency | Use when |
| --- | --- | --- | --- | --- |
| `accessCMT(...)` | yes | hit/miss | maybe | Normal read/write/GC mapping access |
| `accessCMT_LRU` / `_LFU` | yes | yes | maybe | Called only by dispatcher |
| `getLiveMapping(lpn)` | **no** | **no** | **no** | Trim/format need current mapping without caching |
| `cmtErase(lpn)` | drop only | no | no | Mapping is being destroyed |
| `repairLFUMinFreq()` | min pointer | no | no | After emptying LFU min bucket |
| `cmtSize()` | no | used by stats | no | Occupancy reporting |
| `flushCMT()` | clear all | no | **no** tick cost | Destructor coherence |
| `resetCMTStats()` | counters only | zeros | no | End of warm-up |

### `accessCMT` signature meaning

```cpp
accessCMT(lpn, isWrite, tick, isGC = false, allocate = true)
```

| Arg | Meaning |
| --- | --- |
| `isWrite` | Mark dirty on hit/insert |
| `isGC` | Account under `cmt.gc_*` instead of user hits/misses |
| `allocate` | If false and LPN absent from GMT → return `nullptr` (do not create) |

**Call matrix:**

| Site | isWrite | isGC | allocate |
| --- | --- | --- | --- |
| `readInternal` | false | false | **false** |
| `writeInternal` | true | false | true (default) |
| GC relocate | true | **true** | true |
| trim/format | — use `getLiveMapping` instead — | | |

---

## 17. End-to-end: one READ

Host issues a read that becomes FTL `readInternal(req, tick)`:

```text
1. mappingData = accessCMT(lpn, write=false, allocate=false)

2a. HIT
    - count cmtHits
    - update recency (LRU splice) or frequency (LFU promote)
    - return pointer into CMT
    - NO miss latency

2b. MISS, LPN in GMT
    - count cmtMisses
    - maybe evict (if dirty, write-back + WB latency)
    - tick += missLatency
    - insert into CMT (dirty=false)
    - return pointer

2c. MISS, LPN not in GMT (never written)
    - count cmtMisses
    - return nullptr
    - readInternal does nothing (no PAL read)
    - IMPORTANT: does NOT create a mapping

3. If mapping valid:
    - optional pDRAM->read on mapping bytes (DRAM model)
    - for each set ioFlag bit: PAL read of that physical page
    - tick advances with NAND read latency from PAL
```

**Two different “memory” costs on a miss+read:**

1. CMT miss latency (translation tax you added).
2. PAL data-page read latency (always existed).

Plus DRAM-model cost for touching the mapping vector in RAM.

---

## 18. End-to-end: one WRITE

```text
1. mappingData = *accessCMT(lpn, write=true, allocate=true)
   - miss may create GMT sentinel entry (no miss latency)
   - insert/find in CMT with dirty=true

2. If previous valid mapping exists:
    - invalidate old physical pages (FTL block metadata)

3. Allocate new free pages / last free block logic (existing FTL)

4. Update mappingData[i] = new (block, page)   // THIS is the CMT copy
   - GMT still stale until eviction/flush

5. PAL program the new physical pages
```

**Why writes always allocate:** a write *defines* a mapping. Reads must not invent one.

---

## 19. End-to-end: TRIM and FORMAT

### Trim (one LPN)

```text
mapping = getLiveMapping(lpn)   // CMT if present, else GMT, else null
if no valid sub-page: return
invalidate each mapped sub-page
cmtErase(lpn)                   // no write-back
table.erase(lpn)
```

**What we deliberately do *not* do:** call `accessCMT` on miss. That would:

1. Count a miss,
2. Possibly dirty-evict a useful victim,
3. Pay miss latency,
4. Insert the doomed LPN,
5. Immediately erase it.

### Format (LPN range)

Same idea per GMT entry in range: live mapping → invalidate → `cmtErase` → erase GMT → then GC listed blocks.

Also skips sentinel sub-pages (`block >= totalPhysicalBlocks`) so format does not panic on never-mapped slots.

---

## 20. End-to-end: GC and warm-up

### Warm-up (`initialize`)

1. Prefill writes a fraction of the logical space (`FillRatio`).
2. Those writes go through CMT → lots of compulsory misses, cache fills with dirty entries.
3. At the end: log warm-up hit/miss counts, then **`resetCMTStats()`**.
4. Cache **contents stay warm**; only counters go to zero.

So the first user I/Os after warm-up often **hit**, and reported hit rate describes the workload — not the prefill.

### GC

When relocating valid pages, GC calls `accessCMT(lpn, isWrite=true, isGC=true)`.

- Hits/misses go to `cmt.gc_*`.
- User `cmt.hit_rate` ignores GC.
- GC can still dirty entries and change replacement state (especially LFU frequencies).

---

## 21. LRU worked example (small cache)

Cache capacity = **3**. Trace of accesses (R=read, W=write). Start empty.

| Step | Op | CMT after (MRU → LRU) | Notes |
| --- | --- | --- | --- |
| 1 | W A | [A*] | miss, insert dirty |
| 2 | W B | [B*, A*] | miss |
| 3 | W C | [C*, B*, A*] | miss, full |
| 4 | R A | [A*, C*, B*] | hit, splice A to front |
| 5 | W D | [D*, A*, C*] | miss, evict B* (dirty WB), insert D dirty |
| 6 | R C | [C*, D*, A*] | hit |

`*` = dirty.

At step 5, evicting B charges write-back latency and copies B’s mapping into GMT.

---

## 22. LFU worked example (same first five ops)

Capacity 3. Frequency in parentheses.

| Step | Op | State (freq buckets) | Notes |
| --- | --- | --- | --- |
| 1 | W A | f1: A* | insert freq 1 |
| 2 | W B | f1: B*,A* | |
| 3 | W C | f1: C*,B*,A* | full |
| 4 | R A | f1: C*,B* ; f2: A* | A promoted 1→2 |
| 5 | W D | evict from f1 back → A? wait: f1 back is A? | Careful: list front=MRU |

More carefully for step 5: after step 4, suppose f1 list front=MRU is C then B (back=B is LRU within f1). Victim = B. A is safe at freq 2 even if older in wall-clock than C.

**Takeaway for your results:** under uniform random reads after a fill that dirtied everything at freq 1, **one hit** promotes an entry to freq 2 and protects it from eviction while victims remain freq-1. Hit rates stay similar to LRU; **dirty eviction counts fall**.

---

## 23. LRU implementation walkthrough

File: `accessCMT_LRU` in `page_mapping.cc`.

### Hit branch

1. Find LPN in `cmt`.
2. `cmtHits++` or `cmtGCHits++`.
3. `cmtOrder.splice(begin, cmtOrder, iterator)` — **always**, before dirty check.
4. If `isWrite` → `dirty = true`.
5. Return `&entry.mapping`.

**Why splice is outside `if (isWrite)`:** otherwise the cache would track “recently written,” not “recently used.” Reads would not protect hot clean pages.

### Miss branch

1. Count miss.
2. If `!allocate && not in table` → `nullptr`.
3. If `cmt.size() >= capacity`:
   - Victim = `cmtOrder.back()`.
   - Find in map **before** pop (desync safety).
   - Dirty → `table[v]=mapping`, stats, `tick += writeBack`.
   - Erase; re-find `gmtIt` (rehash safety).
4. If not in GMT → `emplace` sentinel vector (no miss latency).
5. Else → `tick += missLatency`.
6. `push_front` + `emplace` with `dirty=isWrite`.

---

## 24. LFU implementation walkthrough

File: `accessCMT_LFU`.

### Hit

1. Remove LPN from bucket `freq`.
2. If bucket empty and was `cmtMinFreq` → `cmtMinFreq++`.
3. Insert into `freq+1` at **front**.
4. Dirty if write; return mapping.

### Miss / eviction

1. Same allocate/`nullptr` rules.
2. If full:
   - Look up `cmtFreqBuckets[cmtMinFreq]`.
   - If missing/empty → `repairLFUMinFreq()`; if still empty → **`panic`** (never silent overflow).
   - Pop `.back()`, dirty write-back like LRU, erase from `cmtLFU`.
3. Load GMT (same latency rules as LRU).
4. Insert at freq 1; `cmtMinFreq = 1`.

### `cmtErase` + `repairLFUMinFreq`

Destroy paths remove an LPN from its bucket. If that empties the min bucket, `cmtMinFreq` must move to the next occupied frequency. Otherwise the next eviction looks at an empty bucket and used to **skip** eviction while still inserting — capacity overflow.

---

## 25. Latency model — what adds to `tick`

| Event | Adds |
| --- | --- |
| CMT hit | nothing from CMT |
| Miss creating brand-new GMT entry | nothing from CMT |
| Miss loading existing GMT entry | `CMTMissLatency` |
| Miss → nullptr (unmapped read) | nothing (but miss **counter** still ++) |
| Clean eviction | nothing |
| Dirty eviction | `CMTWriteBackLatency` |
| `flushCMT` | nothing (no tick accounting) |
| PAL data read/program | existing PAL costs |
| `pDRAM->read` on mapping | DRAM model costs |

Default miss 40 µs and write-back 500 µs match the comments for MLC LSB read/program order-of-magnitude — they are **knobs**, not measured from your PAL NAND model.

---

## 26. Statistics — how to read an output file

After the layout fix, new runs look like:

```text
=== header ===
Started : ...

=== SUBSYSTEM STATS ===
Periodic log printout @ tick ...
... many ftl.page_mapping.cmt.* lines ...
End of log @ tick ...

=== RUN SUMMARY ===
SimpleSSD Standalone v2.0
*** Statistics of Request Generator ***
...
End of simulation @ tick ...

Finished : ...
```

(Your kept Aug 6 sweep files may still have summary *above* subsystem stats; data is fine, only order differs.)

### CMT lines that matter most

| Stat | Question it answers |
| --- | --- |
| `cmt.policy` | Did I actually run LFU? |
| `cmt.capacity_bytes` | Is the size label honest? |
| `cmt.hit_rate` | User-path hit % after warm-up |
| `cmt.hits` / `cmt.misses` | Absolute counts; sum ≈ requests on full-drive randread |
| `cmt.evictions` | How often the cache turned over |
| `cmt.dirty_evictions` | How often eviction paid write-back |
| `cmt.gc_hits` / `cmt.gc_misses` | Mapping pressure from GC |
| `cmt.occupancy` | Usually == capacity if working set ≫ cache |

### Hit rate formula in code

```text
hit_rate = 100 * cmtHits / (cmtHits + cmtMisses)
```

Excludes GC. Warm-up excluded because counters were reset.

### Sanity checklist on a randread result

1. `policy` matches filename (`LRU`/`LFU`).
2. `capacity_bytes` matches config.
3. `hit_rate ≈ 100 * capacity / totalLogicalPages` for uniform random.
4. No `[BIL] submitIO` spam (that was a deleted debug `cerr`).
5. File ~100 lines, not 270k.

---

## 27. Bugs found and fixed — with “why it mattered”

| # | What was wrong | Why numbers lied | Fix |
| --- | --- | --- | --- |
| 1 | Warm-up misses stayed in counters | Hit rate ~halved | `resetCMTStats()` after init |
| 2 | Half-applied LFU containers | Flush/format/occupancy wrong, silent | `CMTPolicy` + unified API |
| 3 | Capacity `bytes/8` | “2 MB” was 16 MB | `bytes/(8*bitsetSize)` |
| 4 | Reads allocated on miss | GMT grew; pollution | `allocate=false` on read |
| 5 | Trim used sub-page 0 only | Wrong skip / panic risk | Scan all indices |
| 6 | Format used stale GMT | Panic / valid-page leak | `getLiveMapping` |
| 7 | Trim load-then-erase | Fake miss/evict/latency | peek, don’t `accessCMT` |
| 8 | LFU minFreq stale after erase | Silent skip → overflow | `repairLFUMinFreq` + panic |

**Why you cannot rescale old results:** #1 and #3 push in opposite directions.

**Standalone footgun:** `[BIL] submitIO` lines came from a temporary `std::cerr` in `bil/entry.cc`, not from `DebugLogFile`. Config could not turn it off. Removed; current binary has no such string.

---

## 28. Fidelity limits — say these out loud

Run `/reviewSSD` (or @-mention `agents/review-ssd.md`) before claiming new CMT behavior is DFTL-faithful.

1. **GMT is always in RAM.** CMT does not move the map to NAND.
2. **Miss/WB are synthetic `tick` adds**, not PAL translation I/O.
3. **No translation-page packing** — one miss per LPN, not per 4 KB translation page holding hundreds of maps. Sequential DFTL hit rates would look better in a fuller model.
4. **ICL off in sweeps** — good for isolating CMT; not a full-system claim.
5. **Unmapped reads still increment miss count** before returning nullptr — negligible on full-drive random, not on sparse holes.
6. **`flushCMT` does not charge write-back latency** — end-of-sim coherence only.
7. **LFU frequencies never age** — historically hot pages can “poison” the cache; classic LFU caveat.
8. **GMT stays in RAM, including after write-back.** A dirty eviction copies the mapping into `table`. It does not program a translation page through PAL.
9. **A window-fill batch charges one write-back.** `evictForFillBatch` still writes every dirty victim into the GMT, then adds `CMTWriteBackLatency` at most once for that batch. Latency understates a batch whose dirty LPNs would occupy several NAND translation pages.
10. **Window fill is not “every miss installs 512 mappings.”** `windowFillBudget` installs a full window, and may evict to do it, only when the previous demand LPN is in the same window. A random miss on a full CMT installs the demand entry only.

**Thesis paragraph (limits 1, 8, 9, 10):**

> The global mapping table remains in simulator RAM for the whole run. The CMT is an SRAM cache in front of that table; dirty write-back updates RAM and adds a synthetic latency. It does not store translation pages on NAND. When window fill evicts dirty entries, the model charges one translation-page program for the batch, not one program per LPN. A full window is installed only on a follow-up miss in the same logical window. A random miss does not evict the cache to prefetch cold neighbors.

---

## 29. Experiments — what you ran and what it means

### Kept artifact

`SimpleSSD-Standalone/outputs/sweep_2h_20260806_185300/`

| Block | Status |
| --- | --- |
| randread LRU | 30/30 |
| randread LFU | 30/30 |
| randwrite | partial |
| randrw | not run |

### What randread taught you

1. Hit rates match the theoretical uniform-random formula after fixes — **implementation + accounting trusted**.
2. LRU vs LFU **hit rates tie** — expected without skew.
3. LFU reduces **dirty evictions** on the warm dirty set — policy difference shows up in write-backs, not hits.
4. The most interesting policy comparison for write-backs needs **randrw/randwrite** (still incomplete).

### How a sweep job configures CMT

`run_sweep_2h.sh` patches:

- standalone cfg: workload, `LogFile` → temp stats file
- simplessd cfg: `CMTPolicy`, `CMTCapacityBytes`, `CMTCapacityRatio=0`, fill, caches off

Then assembles: subsystem stats + run summary into one `.txt`.

---

## 30. How the pieces connect (mental map)

```text
                    ┌─────────────────────────┐
                    │   sample.cfg (FTL)      │
                    │   CMTPolicy, Bytes, …   │
                    └───────────┬─────────────┘
                                │ read at ctor
                                ▼
┌──────────────┐      ┌─────────────────────┐
│ readInternal │─────►│ accessCMT            │──► LRU or LFU structures
│ writeInternal│      │  hit / miss / evict  │        │
│ GC           │      └──────────┬──────────┘        │ dirty WB / miss load
└──────────────┘                 │                     ▼
                                 │              ┌──────────────┐
┌──────────────┐                 │              │ GMT `table`  │
│ trim/format  │──getLiveMapping─┴──────────────►│ (full map)   │
│              │──cmtErase (no WB)───────────────┤              │
└──────────────┘                                 └──────┬───────┘
                                                       │
initialize ──resetCMTStats──► (cache stays warm)       │
destructor ──flushCMT──► dirty → GMT                   ▼
                                               PAL data NAND
```

**One rule of thumb:**

- Need to **use or update** a mapping for I/O → `accessCMT`.
- Need to **destroy** a mapping → `getLiveMapping` + `cmtErase`, never write-back.

---

## 31. Mentor Q&A (expanded)

**Q: Show me your CMT code.**  
A: `simplessd/ftl/page_mapping.hh` (structures) and `.cc` (`accessCMT_LRU` / `_LFU`). Config in `ftl/config.*` and the CMT block of `config/sample.cfg`.

**Q: Is this a real DFTL?**  
A: It is a DFTL-*inspired* CMT on top of an in-RAM GMT. Latencies model translation I/O; flash-resident translation pages are not implemented. That is a deliberate scope choice.

**Q: How do you know a 2 MB cache is really 2 MB?**  
A: `cmt.entry_bytes` and `cmt.capacity_bytes` are printed. With `bitsetSize=8`, 2 MB → 32768×64. Early bug used `/8` and lied by 8×.

**Q: Prove LRU is O(1).**  
A: Map stores a list iterator; hit is `splice` to front; victim is `back()`.

**Q: Prove LFU is O(1).**  
A: Frequency-bucket lists; min-frequency pointer; within-bucket LRU via front/back; hit moves between two buckets.

**Q: Why do LRU and LFU hit rates match?**  
A: Uniform random has no hot set. After sequential fill every entry is freq 1, so early LFU victims resemble LRU order. Difference appears in dirty write-backs when reads promote some dirty entries.

**Q: What was your worst bug?**  
A: Half-migrating to LFU with a patch script — silent semantic bugs. Fixed with a runtime policy switch and a single API.

**Q: What happens if format runs with dirty CMT entries?**  
A: `getLiveMapping` invalidates the live PPNs, then `cmtErase` drops the entry without writing it back to GMT.

**Q: Why reset stats but keep the cache full after warm-up?**  
A: Prefill compulsory misses must not dilute hit rate; a warm cache matches a device that already held data.

**Q: Next step?**  
A: Finish write/mixed sweeps; add a skewed workload if we want hit-rate separation; state fidelity limits in the report.

**Q: Where do miss latencies go in the output?**  
A: They are folded into total simulated `tick` / latency stats, not a separate “translation energy” line. Counters tell you *how many* misses/write-backs occurred; tick tells you *time impact* together with PAL.

**Q: Does GC use the CMT?**  
A: Yes, via `accessCMT(..., isGC=true)`. Those counts are separate from user hit rate but still affect cache contents.

---

## 32. Study checklist — can you explain X?

Tick these off out loud without the notes:

- [ ] Why SSDs need an FTL map, and why overwrite-in-place is impossible  
- [ ] What `table` is, and what a sentinel mapping means  
- [ ] What problem DFTL solves, and what part you did / did not implement  
- [ ] Why `bitsetSize` changes capacity entry count  
- [ ] Draw LRU structures and one hit + one dirty eviction  
- [ ] Draw LFU buckets and one promote + one eviction  
- [ ] Why reads use `allocate=false` and trim uses `getLiveMapping`  
- [ ] Dirty timeline (write → GMT stale → write-back)  
- [ ] Warm-up: what is cleared vs what stays  
- [ ] How to verify `capacity_bytes` in an output file  
- [ ] Why uniform random ties LRU/LFU on hit rate  
- [ ] Name three fidelity limits without looking  

If any box fails, re-read that section and the matching code once.

---

## 33. Quick reference card

```text
FILES (simplessd):  page_mapping.{hh,cc}  config.{hh,cc}  sample.cfg  gc_test.cfg

CONFIG:  CMTPolicy  CMTCapacityRatio  CMTCapacityBytes  CMTMissLatency  CMTWriteBackLatency

SIZE:    entry_bytes = 8 * bitsetSize
         capacity    = bytes / entry_bytes   (if ratio == 0)

HOT API: accessCMT(lpn, isWrite, tick, isGC, allocate)
PEEK:    getLiveMapping(lpn)
DROP:    cmtErase(lpn)            // never write-back
END:     flushCMT()               // dirty → GMT
WARMUP:  resetCMTStats()          // counters only

LRU: map + list (MRU front, victim back)
LFU: map + freq buckets (victim = minFreq.back())

READ:  allocate=false
WRITE: allocate=true, dirty
TRIM/FORMAT: peek + erase
GC: isGC=true

HIT RATE: 100 * userHits / (userHits + userMisses)   // after warm-up reset

MODEL: in-RAM GMT + synthetic translation latencies ≠ full on-flash DFTL
```

### 60-second live demo path

1. `config/sample.cfg` — five CMT keys.  
2. `page_mapping.hh` — LRU vs LFU structs.  
3. `accessCMT_LRU` — splice, dirty, evict+WB, miss latency.  
4. Output file — `cmt.policy`, `cmt.capacity_bytes`, `cmt.hit_rate`, `cmt.dirty_evictions`.  
5. Closing sentence: “GMT stays in RAM; we model DFTL cache pressure and costs.”

---

## Appendix A — Commit / change map

| When | What |
| --- | --- |
| 2026-07-24 `9fcadf1` | First CMT (LRU + config + stats) |
| Working tree after | LFU policy, fixes #1–#8, live-mapping destroy paths |
| Standalone | Sweep scripts, tutorials, cleaned `outputs/sweep_2h_20260806_185300/` |

## Appendix B — Suggested reading order inside the code

1. `PageMapping` constructor (CMT sizing)  
2. `accessCMT` → `accessCMT_LRU` (entire function)  
3. `readInternal` / `writeInternal` call sites  
4. `getLiveMapping` + `trimInternal` + `format`  
5. `accessCMT_LFU` + `cmtErase` + `repairLFUMinFreq`  
6. `resetCMTStats` call at end of `initialize`  
7. `getStatList` / `getStatValues` CMT block  

---

*Last updated: 2026-08-07 — matches review-readiness CMT (policy switch, capacity fix, `getLiveMapping`, LFU minFreq repair, dual-policy smoke).*
