# Tutorial 6: CMT (Cached Mapping Table) — Deep Dive

This tutorial covers the design, implementation, and validation of the **Cached Mapping Table (CMT)** that was implemented as part of the DFTL architecture in SimpleSSD-Standalone. By the end of this tutorial you will understand why the CMT exists, exactly how it works in code, and how to correctly interpret its simulation metrics.

---

## 1. Background: The Address Translation Problem

Every SSD uses a **Flash Translation Layer (FTL)** to hide the physical complexity of NAND flash (no in-place overwrites, erase-before-write) from the host. The FTL maintains a **Global Mapping Table (GMT)** that translates every Logical Page Number (LPN) issued by the host into a Physical Page Number (PPN) on the flash.

For a **64 GB SSD** with **4 KB pages**, the GMT contains:

$$\frac{64 \times 1024 \times 1024 \text{ KB}}{4 \text{ KB}} = 16{,}777{,}216 \text{ entries}$$

At 8 bytes per entry (4B LPN + 4B PPN), the full GMT occupies **128 MB of DRAM**. Storing all of this permanently in controller DRAM is expensive and impractical for real hardware.

**DFTL** (Demand-based Flash Translation Layer, Gupta et al., ASPLOS '09) solves this by storing the GMT on NAND flash and keeping only a small, working-set cache in DRAM. This cache is the **CMT**.

---

## 2. What is the CMT?

The CMT is an **LRU (Least Recently Used) demand-paged translation cache** implemented on top of the GMT. It works analogously to a CPU L1 cache:

| Concept | CPU Cache | CMT |
|---|---|---|
| Slow backing store | Main memory (DRAM) | GMT on NAND flash |
| Fast cache | L1/L2 SRAM | CMT in controller DRAM |
| Cache unit | Cache line | Translation entry (1 LPN → PPN) |
| Replacement policy | LRU | LRU |
| Write-back | Dirty cache line flush | Dirty translation flush |

---

## 3. Data Structures

The CMT is implemented in [`simplessd/ftl/page_mapping.hh`](../simplessd/ftl/page_mapping.hh) and [`simplessd/ftl/page_mapping.cc`](../simplessd/ftl/page_mapping.cc).

### 3.1 `CMTEntry`

```cpp
struct CMTEntry {
    std::vector<std::pair<uint32_t, uint32_t>> mapping;  // Physical (block, page)
    bool dirty;  // true = modified, needs write-back on eviction
};
```

Each entry stores the physical address mapping for one LPN and a dirty flag.

### 3.2 LRU Ordering List

```cpp
std::list<uint64_t> cmtOrder;  // front = MRU, back = LRU
```

A doubly-linked list of LPNs. Front is most recently used, back is least recently used (first to be evicted). Using `std::list` allows O(1) splice operations.

### 3.3 The Cache Store

```cpp
std::unordered_map<uint64_t,
    std::pair<CMTEntry, std::list<uint64_t>::iterator>> cmt;
```

A hash map from `LPN → (CMTEntry, iterator_into_cmtOrder)`. The stored iterator enables O(1) LRU position update via `splice` on every hit.

### 3.4 Capacity Fields

| Field | Type | Default | Current Config |
|---|---|---|---|
| `cmtCapacity` | `uint64_t` | — | `32,768` entries (2 MB config) |
| `cmtEntryBytes` | `uint64_t` | — | `64` B (`8 * bitsetSize`, `bitsetSize = 8`) |
| `cmtMissLatency` | `uint64_t` | `40,000,000 ps` | `40 µs` |
| `cmtWriteBackLatency` | `uint64_t` | `500,000,000 ps` | `500 µs` |

---

## 4. How `cmtCapacity` is Determined

In the constructor (`page_mapping.cc`):

```cpp
// One entry caches a whole superpage = bitsetSize mappings of 8 B each
cmtEntryBytes = 8 * bitsetSize;

float cmtRatio = conf.readFloat(CONFIG_FTL, FTL_CMT_CAPACITY_RATIO);
if (cmtRatio > 0.0f) {
    // Use ratio of total logical pages
    cmtCapacity = (uint64_t)((float)status.totalLogicalPages * cmtRatio);
}
else {
    // Use hard byte limit
    uint64_t cmtBytes = conf.readUint(CONFIG_FTL, FTL_CMT_CAPACITY_BYTES);
    cmtCapacity = cmtBytes / cmtEntryBytes;
}
if (cmtCapacity < 16) cmtCapacity = 16;  // Minimum guard
```

**Current configuration** (`CMTCapacityRatio = 0.0`, `CMTCapacityBytes = 2097152`, `bitsetSize = 8`):

$$\text{cmtEntryBytes} = 8 \times 8 = 64 \text{ B}$$

$$\text{cmtCapacity} = \frac{2{,}097{,}152}{64} = 32{,}768 \text{ entries} \rightarrow \text{covers } 128 \text{ MB of address space}$$

> [!WARNING]
> Until 2026-08-06 this divided by 8 rather than by `cmtEntryBytes`, giving 262,144 entries — an actual 16 MB cache labelled "2 MB". Results from before that date are not comparable.

---

## 5. The `accessCMT` Function

All reads, writes, and trims call `accessCMT` instead of accessing `table` directly. This is the heart of the CMT implementation.

```cpp
std::vector<std::pair<uint32_t, uint32_t>> &
PageMapping::accessCMT(uint64_t lpn, bool isWrite, uint64_t &tick, bool isGC)
```

### Flow Diagram

```
accessCMT(lpn, isWrite, tick, isGC)
│
├─ LPN found in cmt? ──YES──► Increment cmtHits (or cmtGCHits)
│                              Splice to front of cmtOrder  [O(1)]
│                              If isWrite: set dirty = true
│                              Return mapping reference ◄──────────┐
│                                                                   │
└─ NOT found ─────────────► Increment cmtMisses (or cmtGCMisses)  │
                             │                                      │
                             ├─ cmt.size() >= cmtCapacity?         │
                             │   YES: Evict LRU from cmtOrder.back │
                             │        Increment cmtEvictions        │
                             │        If dirty: flush to GMT table  │
                             │                 Increment cmtDirtyEvictions
                             │                 tick += cmtWriteBackLatency (500µs)
                             │        Erase from cmt               │
                             │                                      │
                             └─ LPN in GMT (table)?                │
                                 NO (brand-new): Create sentinel   │
                                                 No NAND penalty   │
                                 YES (existing): tick += cmtMissLatency (40µs)
                                                                    │
                             Push LPN to cmtOrder.front            │
                             Insert CMTEntry into cmt              │
                             Return mapping reference ─────────────┘
```

### Why Two Latencies?

| Event | Latency | Reason |
|---|---|---|
| **CMT Miss (existing LPN)** | +40 µs | Must read translation page from NAND flash |
| **Dirty Eviction** | +500 µs | Must program (write) dirty translation page back to NAND flash |
| **CMT Hit** | 0 (only DRAM access) | Mapping already in controller DRAM |
| **Brand-new LPN** | 0 | No mapping on flash to fetch |

---

## 6. Integration in I/O Paths

| Operation | Call | `isWrite` | Effect |
|---|---|---|---|
| `readInternal` | `accessCMT(lpn, false, tick)` | `false` | Clean lookup; entry not marked dirty |
| `writeInternal` | `accessCMT(lpn, true, tick)` | `true` | Entry immediately marked dirty in CMT |
| `trimInternal` | `accessCMT(lpn, false, tick)` | `false` | After invalidation, explicitly erases LPN from both CMT and GMT |
| GC copy | `accessCMT(lpn, true, tick, true)` | `true` | `isGC=true` routes stats to `cmtGCHits`/`cmtGCMisses` separately |

---

## 7. Statistics Explained

Every periodic log printout contains the following CMT metrics:

| Metric Key | Meaning |
|---|---|
| `cmt.hits` | Translation lookups served from DRAM cache (fast path) |
| `cmt.misses` | Translation lookups that required fetching from NAND flash |
| `cmt.hit_rate` | `hits / (hits + misses) × 100%` — user I/O only, GC excluded |
| `cmt.evictions` | Total LRU evictions to make room for new entries |
| `cmt.dirty_evictions` | Subset of evictions where the entry was modified (required flash write-back) |
| `cmt.writebacks` | Total NAND flash write operations to persist evicted dirty mappings |
| `cmt.gc_hits` | Cache hits triggered by Garbage Collection (tracked separately) |
| `cmt.gc_misses` | Cache misses triggered by Garbage Collection |
| `cmt.capacity` | Max entries the CMT can hold (set at startup) |
| `cmt.entry_bytes` | Mapping bytes modelled per entry (`8 * bitsetSize`) |
| `cmt.capacity_bytes` | True cache size in bytes (`capacity * entry_bytes`) |
| `cmt.occupancy` | Entries actually in the CMT at the time of the log printout |
| `cmt.policy` | Replacement policy the run used: 0 = LRU, 1 = LFU |

> [!IMPORTANT]
> **The hit rate excludes GC traffic by design.** The DFTL paper evaluates CMT efficiency only from the perspective of host I/O. GC-triggered mapping lookups are necessary background work, not a reflection of the translation cache's usefulness to the host.

> [!IMPORTANT]
> **The hit rate also excludes warm-up.** `initialize()` prefills the drive through `accessCMT()`, and every one of those accesses is a compulsory miss. The counters are zeroed once filling finishes, so these numbers describe the measured workload only. Before 2026-08-06 they did not, which roughly halved every reported hit rate.

---

## 8. Why a High Hit Rate Can Be Misleading

The most important lesson from our validation experiments:

> [!WARNING]
> A high CMT hit rate does **not** necessarily mean the CMT is performing well. It can simply mean the CMT is **too large** for the workload footprint, so evictions never happen.

### Our Validation Experiment

| Configuration | CMT Size | Cache Coverage | Active Footprint | Evictions | Hit Rate |
|---|---|---|---|---|---|
| **Misleading** | 16 MB CMT | 8 GB | ~3.14 GB | **0** | **83%** |
| **Realistic (PoC)** | 2 MB CMT | 1 GB | 8 GB | **1,646,749** | **26.8%** |
| **Realistic + Prefill** | 2 MB CMT | 1 GB | 8 GB (75% warm) | **2,979,591** | **9.7%** |

**The root cause of the misleading 83% result:**
1. The 16 MB CMT covers 8 GB of address space.
2. The SSD's internal DRAM data cache absorbed most writes before they reached the FTL — only 3.14 GB of unique LPNs ever appeared at the translation layer.
3. Since 3.14 GB < 8 GB (CMT coverage), the cache never filled up. After the initial cold misses, **every access was a guaranteed hit**. Zero evictions ever occurred.

**The fix:** Disable the DRAM data cache (`EnableReadCache = 0`, `EnableWriteCache = 0`) and use a CMT smaller than the workload's active footprint.

---

## 9. Configuration Reference

In `simplessd/config/sample.cfg` under the `[ftl]` section:

```ini
## CMT replacement policy: 0 = LRU, 1 = LFU
CMTPolicy = 0

## CMT Capacity Parameters
# If CMTCapacityRatio > 0, it overrides CMTCapacityBytes
CMTCapacityRatio = 0.0

# Hard limit in bytes (entries = bytes / (8 * bitsetSize))
CMTCapacityBytes = 2097152   # 2 MB → 32,768 entries → covers 128 MB

## CMT Miss Latency (picoseconds)
# Cost of reading a translation page from NAND on a CMT miss (DFTL "double read")
CMTMissLatency = 40000000    # 40 µs

## CMT Write-Back Latency (picoseconds)
# Cost of programming a dirty translation page back to NAND on eviction
CMTWriteBackLatency = 500000000  # 500 µs
```

And under `[icl]` to disable the DRAM data cache so CMT pressure is real:

```ini
EnableReadCache = 0
EnableWriteCache = 0
```

---

## 10. Running a Stress Test

Use the `run_sim.sh` script to run a simulation and save all metrics to a single file in the `outputs/` folder:

```bash
bash run_sim.sh my_test.txt
```

Then check your results:

```bash
grep "cmt\." outputs/my_test.txt | tail -20
```

You should see evictions, writebacks, and a hit rate below 30% with the current 2 MB CMT + disabled cache + 8 GB workload configuration.
