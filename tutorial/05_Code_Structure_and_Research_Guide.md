# Tutorial 5: Code Structure and Research Guide

> **Deeper version available.** [`architecture/04_ftl_file_map.md`](architecture/04_ftl_file_map.md) has a "which file do I open" table for the FTL, and [`architecture/02_boot_and_wiring.md`](architecture/02_boot_and_wiring.md) lists every abstract/concrete factory pair with the line that chooses it.

SimpleSSD is built to be a research platform. Now that you understand the architecture and request flow, here is a guide on where to look if you want to implement new features or algorithms based on your studies.

## Where To Implement Changes

### 1. New Host I/O Schedulers
**Goal:** Implement a deadline-aware or fair-queueing scheduler.
**Where to look:** 
- `bil/scheduler.hh`
- `bil/noop_scheduler.cc`
**Why:** BIL sees all host block requests *before* they enter the SSD firmware.

### 2. New Cache/Write Buffer Policies (e.g. BPLRU)
**Goal:** Optimize write coalescing to reduce Write Amplification.
**Where to look:** 
- `simplessd/icl/generic_cache.cc`
**Why:** `GenericCache` already handles dirty lines, partial writes, and evictions.

### 3. New Garbage Collection Policies
**Goal:** Implement a novel victim-selection algorithm or real-time GC.
**Where to look:** 
- `simplessd/ftl/page_mapping.cc`
- Specifically `PageMapping::calculateVictimWeight()` and `selectVictimBlock()`.
**Why:** The victim selection policy is fully encapsulated in these FTL functions.

### 4. Advanced FTL Maps (e.g. Demand-based FTL - DFTL)
**Goal:** Simulate the performance impact of caching the mapping table in SRAM while keeping the full table in NAND.
**Where to look:**
- `simplessd/ftl/page_mapping.cc`
**Why:** The current page mapping logic assumes a full DRAM mapping table with latency penalties. You would need to add a translation cache layer here.

### 5. Semantic SSDs / Ransomware Defense (SrFTL)
**Goal:** Have the SSD analyze overwrite patterns to detect ransomware or protect old versions of data.
**Where to look:**
- Add semantic extensions to `BIL::BIO`.
- Hook into `PageMapping::writeInternal` to track entropy or protect recently invalidated versions.

## Model Fidelity: Knowing Your Limits

As a researcher, it is important to know what claims are safe to make with this simulator.

**Safe Claims:**
- "Changing queue depth in this model changes latency."
- "This new GC policy copies fewer valid pages under this workload."
- "This cache policy alters the hit rate and reduces PAL programming time."

**Risky/Invalid Claims:**
- "This perfectly models ext4 file system behavior." *(The simulator doesn't model file system semantics out-of-the-box unless you use specific semantic traces).*
- "This is exactly how a Samsung 980 Pro behaves." *(Real SSDs have highly proprietary FTLs; this is a generic research model).*

## Next Steps

To become comfortable with the code, I recommend:
1. Run a `randwrite` workload and observe the GC and WAF statistics.
2. Change the `EvictPolicy` in `simplessd/config/sample.cfg` and see how the tail latency changes.
3. Open `simplessd/ftl/page_mapping.cc` and read `writeInternal` with Tutorial 4 open!

Happy simulating!
