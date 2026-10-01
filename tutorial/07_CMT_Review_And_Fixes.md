# CMT Code Review: What Was Wrong and How It Was Fixed

*A walkthrough of the 2026-08-06 review of the CMT implementation in `simplessd/ftl/page_mapping.cc`.*

This document assumes you have read [`cmt_guide.md`](cmt_guide.md) and know what a CMT is. It is about the **bugs**, why they were hard to see, and what each one teaches.

Read this one if you want to understand why the numbers changed.

---

## Table of Contents

1. [The Short Version](#1-the-short-version)
2. [The Good News: The LRU Is Correct](#2-the-good-news-the-lru-is-correct)
3. [Bug 1: The Hit Rate Was Measuring the Warm-Up](#3-bug-1-the-hit-rate-was-measuring-the-warm-up)
4. [Bug 2: The Half-Applied Policy Switch](#4-bug-2-the-half-applied-policy-switch)
5. [Bug 3: The Cache Was 8x Bigger Than Its Label](#5-bug-3-the-cache-was-8x-bigger-than-its-label)
6. [Bug 4: Reads Were Creating Mappings](#6-bug-4-reads-were-creating-mappings)
7. [Bug 5: Trim Judged a Superpage by One Sub-Page](#7-bug-5-trim-judged-a-superpage-by-one-sub-page)
8. [The Redesign: One Switch Instead of Six Edits](#8-the-redesign-one-switch-instead-of-six-edits)
9. [Why LRU and LFU Score Almost the Same](#9-why-lru-and-lfu-score-almost-the-same)
10. [What Is Still Not Modelled](#10-what-is-still-not-modelled)
11. [Lessons Worth Keeping](#11-lessons-worth-keeping)

---

## 1. The Short Version

Five bugs. None of them crashed. None of them produced a compiler warning. All of them produced numbers that looked completely reasonable.

| # | Bug | Effect on results |
|---|---|---|
| 1 | Warm-up counted in the hit rate | Hit rates roughly **halved** |
| 2 | Policy switch applied halfway | Silent corruption on shutdown, format, and occupancy |
| 3 | Cache capacity ignored `bitsetSize` | Every cache **8x larger** than its label |
| 4 | Reads allocated mappings | GMT grew without bound; cache polluted |
| 5 | Trim judged a superpage by sub-page 0 | Trims skipped, or a potential crash |

> [!IMPORTANT]
> Bugs 1 and 3 push the numbers in **opposite** directions, so you cannot rescue old results by scaling them. Every result generated before 2026-08-06 has to be regenerated.

---

## 2. The Good News: The LRU Is Correct

Before the bugs, the thing that is right.

The LRU implementation is textbook. It uses the standard hash-map-plus-linked-list structure:

- `cmtOrder` is a `std::list<uint64_t>`, most-recently-used at the front.
- `cmt` maps `LPN → {entry, iterator into cmtOrder}`.

Storing the iterator is what makes it O(1). On a hit, `cmtOrder.splice()` moves that one list node to the front without touching anything else. On a miss, the victim is `cmtOrder.back()`, read directly.

I checked it against the classic LRU mistakes, and it commits none of them:

| Classic mistake | Present? |
|---|---|
| Recency updated on insert but not on hit | No — `splice` runs on every hit |
| Iterating a `std::map` in key order and calling it LRU | No — order is a real list |
| Scanning all entries for the oldest timestamp | No — O(1) `back()` |
| Forgetting to erase the victim from the secondary index | No — both containers erased |
| **Recency not updated on write hits, only read hits** | **No** — `splice` runs before the `isWrite` check |

That last row is the one people usually get wrong, and it is worth understanding why the order of two lines matters:

```cpp
cmtOrder.splice(cmtOrder.begin(), cmtOrder, it->second.second);  // always

if (isWrite) {
  it->second.first.dirty = true;                                  // only writes
}
```

If the `splice` had been placed *inside* the `if`, then a page read a thousand times but never written would drift to the back of the list and be evicted, while a page written once would be safe. The cache would be tracking "recently written" instead of "recently used". It is a one-line difference with a large behavioural consequence, and this code gets it right.

**So when the review says "the LRU is wrong", it never means the algorithm.** It means the accounting around it.

---

## 3. Bug 1: The Hit Rate Was Measuring the Warm-Up

### The symptom

`randread_io4G_cmt2MB_d32` reported a **7.84%** hit rate. Theory said it should be about 16.7%. Being off by a factor of two is too big to be noise and too small to be obviously broken — the worst kind of wrong.

### The cause

Before the real workload runs, the simulator has to fill the drive with data, otherwise every read would hit an empty page. That is `initialize()`:

```cpp
for (uint64_t i = 0; i < nPagesToWarmup; i++) {
  req.lpn = i;
  writeInternal(req, tick, false);   // ← goes through accessCMT()
}
```

Every one of those prefill writes goes through the CMT. And because the fill is *sequential* — LPN 0, 1, 2, 3, … each touched exactly once — **every single one is a guaranteed miss**. There is no reuse to hit on.

Nothing reset the counters afterwards. So the measured workload's statistics started life already buried under a million compulsory misses.

### The arithmetic

This is worth doing by hand, because it confirms the diagnosis exactly rather than approximately.

```
Total logical pages       = 1,572,864
FillRatio                 = 0.75
Prefill pages             = 0.75 × 1,572,864 = 1,179,648   ← all misses

Reported hits             =   174,753
Reported misses           = 2,053,471
Reported hit rate         = 174,753 / 2,228,224 = 7.84%

Misses after removing prefill = 2,053,471 − 1,179,648 = 873,823
Read-phase lookups            =   174,753 + 873,823 = 1,048,576
```

That 1,048,576 is exactly the number of read requests the workload issued. The books balance perfectly, which means the prefill accounts for the entire discrepancy.

And the corrected rate:

$$\frac{174{,}753}{1{,}048{,}576} = 16.67\%$$

Now compare that against theory. For uniform random access with LRU, the steady-state hit rate is just the fraction of the address space the cache covers:

$$\frac{\text{capacity}}{\text{total logical pages}} = \frac{262{,}144}{1{,}572{,}864} = 16.67\%$$

An exact match to four significant figures. This is a satisfying result: it simultaneously proves the statistics bug is real *and* proves the LRU is behaving exactly as theory predicts.

### The fix

```cpp
// end of PageMapping::initialize()
resetCMTStats();
```

Only the counters are zeroed. The cache **contents** stay warm, which is deliberate — a real SSD that has been in use has a populated translation cache, so clearing it would be less realistic, not more.

> [!TIP]
> The general lesson: a benchmark that measures its own setup will report a wrong answer that looks plausible. Whenever there is a warm-up phase, there must be an explicit line that separates it from the measurement phase.

---

## 4. Bug 2: The Half-Applied Policy Switch

### The setup

There were originally two ways to switch from LRU to LFU: follow nine hand-editing steps, or run `activate_lfu.py`, a script that patched the source with string replacements.

Both had the same flaw. Switching policy required changes in **six different places**, and nothing checked that you made all six.

### What actually happened

`activate_lfu.py` was run on 31 July. It applied some of its replacements and silently skipped others, because the source had drifted and its search strings no longer matched. This is what the file looked like afterwards:

| Function | Which cache it used |
|---|---|
| `accessCMT()` | `cmt` / `cmtOrder` (**LRU**) |
| `flushCMT()` | `cmtLFU` (**LFU**) |
| `format()` | `cmtLFU` (**LFU**) |
| `getStatValues()` | `cmtLFU` (**LFU**) |
| `trimInternal()` | `cmt` / `cmtOrder` (**LRU**) |

Every access went into the LRU containers. Three other functions were reading the LFU containers, **which were always empty**.

### Why the compiler said nothing

This is the important part. Both sets of containers were declared as members, so `cmtLFU.find(...)` is perfectly valid C++. Iterating an empty map is legal and does nothing. There is no error, no warning, no crash — just three functions quietly doing nothing at all.

The three consequences:

1. **`flushCMT()` never flushed.** At shutdown, dirty entries were supposed to be written back to the GMT. The loop ran over an empty map, so every dirty mapping was silently discarded.
2. **`format()` left stale entries.** After formatting an LPN range, those LPNs stayed in the LRU cache. A later read would get a **hit** and receive a mapping to data that had been erased.
3. **`cmt.occupancy` always reported 0**, because it returned `cmtLFU.size()`.

### The saving grace

The compiled binary was older than the source edits:

```
libsimplessd.a         17:16   ← binary
page_mapping.cc        17:39   ← source, edited later
```

The July results were produced by the older, coherent binary, so **they are not affected by this bug**. But the next person to type `make` would have silently gotten corrupt results with no indication anything had changed.

### The fix

Replaced entirely by a config key. See [section 8](#8-the-redesign-one-switch-instead-of-six-edits).

---

## 5. Bug 3: The Cache Was 8x Bigger Than Its Label

### The reasoning that looked right

```cpp
// DFTL paper: each mapping entry is 4B LPN + 4B PPN = 8 bytes
cmtCapacity = cmtBytes / 8;
```

The comment is correct about DFTL. A mapping really is 8 bytes. The problem is that in *this* simulator, one CMT entry is not one mapping.

### What an entry actually holds

```cpp
struct CMTEntry {
  std::vector<std::pair<uint32_t, uint32_t>> mapping;  // ← bitsetSize of them
  bool dirty;
};
```

The FTL maps at **superpage** granularity. A superpage is striped across several channels and planes, and each of its sub-pages needs its own physical location. So one entry holds `bitsetSize` mappings, where:

```cpp
bitsetSize = bRandomTweak ? param.ioUnitInPage : 1;
```

`EnableRandomIOTweak = 1` in the config, so `bitsetSize = ioUnitInPage`.

### Measuring it instead of guessing

Rather than trace the superpage geometry by hand, I added a startup log line and read the answer off:

```
CMT | Policy LRU | 32768 entries | 64 B/entry (bitsetSize 8) | 2097152 B total
```

`bitsetSize` is **8**. So an entry models 64 bytes, not 8.

### The damage

| | Old | New |
|---|---|---|
| Bytes charged per entry | 8 | 64 |
| Entries for `CMTCapacityBytes = 2097152` | 262,144 | 32,768 |
| **Actual cache size** | **16 MB** | 2 MB |
| Label on the graph | "2 MB" | "2 MB" |

Every point on the CMT-size axis of the sweep was eight times larger than its label. The *shape* of the curve was roughly preserved, since all points were wrong by the same factor, but every absolute claim of the form "a 2 MB cache achieves X%" was wrong.

### The fix

```cpp
cmtEntryBytes = 8 * bitsetSize;
cmtCapacity   = cmtBytes / cmtEntryBytes;
```

Plus two new stats, `cmt.entry_bytes` and `cmt.capacity_bytes`, so every result file records the true size and nobody has to reconstruct this reasoning again.

> [!TIP]
> This bug had already been "fixed" once (see `ftl_guide.md` §7.2) and the fix was still wrong. The earlier lesson was "cross-check `cmt.capacity` against your config" — but that check *passes* here, because the config and the capacity were consistent with each other. The error was in what the word "entry" meant. When a derived number depends on a unit, print the unit alongside it.

---

## 6. Bug 4: Reads Were Creating Mappings

### The difference from upstream

Stock SimpleSSD's `readInternal` does nothing when an LPN has never been written:

```cpp
auto mappingList = table.find(req.lpn);
if (mappingList != table.end()) {   // not found → do nothing at all
  ...
}
```

The CMT version replaced that lookup with `accessCMT()`, which on a miss does this:

```cpp
if (gmtIt == table.end()) {
  auto ret = table.emplace(lpn, std::vector<...>(bitsetSize, {...}));
  gmtIt = ret.first;
}
// ...then inserts it into the CMT too
```

It **creates** a placeholder mapping. That is right for a write — a write genuinely does establish a mapping. It is wrong for a read.

### Why it matters

Reading a logical page that was never written is a normal thing for a host to do. On a drive filled to 75%, a quarter of the address space is unwritten. With this bug, every such read:

- added a permanent entry to the GMT, so the mapping table grew without bound;
- consumed a CMT slot with an entry that can **never** produce a hit, evicting a real entry to make room.

So the bug both inflated memory and actively depressed the hit rate it was being used to measure.

### The fix

An `allocate` flag, defaulting to true:

```cpp
// readInternal and trimInternal pass allocate = false
if (gmtIt == table.end() && !allocate) {
  return nullptr;      // still counted as a miss, but nothing is created
}
```

`accessCMT` now returns a **pointer** rather than a reference, so it has a way to express "there is nothing here". `writeInternal` and GC keep the allocating behaviour, which is correct for them.

---

## 7. Bug 5: Trim Judged a Superpage by One Sub-Page

```cpp
bool hasMappingData = mappingData.at(0).first < param.totalPhysicalBlocks;
```

This asks "is sub-page 0 mapped?" and then treats the answer as true for the whole superpage. With random I/O tweak enabled a superpage can be **partially** mapped, so this is wrong in both directions:

- **Sub-page 0 unmapped, others mapped** → the trim is skipped entirely and real mappings leak.
- **Sub-page 0 mapped, others not** → the loop below runs over *all* sub-pages and calls `blocks.find(mapping.first)` on an unmapped one, whose block index is the sentinel `totalPhysicalBlocks`. That is not a real block, so `blocks.find` returns `end()` and the code calls `panic("Block is not in use")` — a hard stop.

The fix scans all sub-pages to decide, and skips unmapped ones inside the loop:

```cpp
for (uint32_t idx = 0; idx < bitsetSize; idx++) {
  if (mappingData->at(idx).first >= param.totalPhysicalBlocks) {
    continue;                       // never mapped — nothing to invalidate
  }
  ...
}
```

---

## 8. The Redesign: One Switch Instead of Six Edits

Bug 2 was not really a bug in the LFU code. The LFU algorithm was fine. It was a bug in the **process** for switching policies: a six-place manual edit with no safety net.

Fixing the individual six places would have left the next person exactly one careless edit away from the same silent corruption. So the switch itself was redesigned.

### Now

```ini
CMTPolicy = 0    # LRU
CMTPolicy = 1    # LFU
```

No recompile, no source edits, no script.

### How it is made safe

`accessCMT()` became a dispatcher:

```cpp
std::vector<std::pair<uint32_t, uint32_t>> *
PageMapping::accessCMT(uint64_t lpn, bool isWrite, uint64_t &tick,
                       bool isGC, bool allocate) {
  if (cmtPolicy == CMT_POLICY_LFU) {
    return accessCMT_LFU(lpn, isWrite, tick, isGC, allocate);
  }
  return accessCMT_LRU(lpn, isWrite, tick, isGC, allocate);
}
```

But the dispatcher alone would not have prevented bug 2 — the problem was the *other* five places. So two more helpers were added, and every remaining container access was routed through them:

| Helper | What it does | Callers |
|---|---|---|
| `accessCMT()` | look up / insert | `readInternal`, `writeInternal`, `trimInternal`, GC |
| `cmtErase(lpn)` | drop an entry, no write-back | `trimInternal`, `format` |
| `cmtSize()` | current entry count | `getStatValues`, warm-up log |

`flushCMT()` branches internally and clears both container sets unconditionally.

The result is a structural guarantee: **only five functions in the entire file touch `cmt`, `cmtOrder`, `cmtLFU`, or `cmtFreqBuckets` directly.** Everything else goes through a helper that cannot pick the wrong policy, because it reads the same `cmtPolicy` member the dispatcher does.

A config key cannot be applied halfway. `activate_lfu.py` and `lfu_code.txt` were deleted.

### One real bug found while enabling the LFU path

The LFU eviction originally did:

```cpp
auto &minBucket = cmtFreqBuckets[cmtMinFreq];   // operator[]
uint64_t evictLpn = minBucket.back();
```

`operator[]` on a `std::unordered_map` **creates** the element if it is missing. If `cmtMinFreq` ever pointed at a bucket that no longer existed, this would silently insert an empty list and then call `.back()` on it — undefined behaviour. It was rewritten to look the bucket up and check:

```cpp
auto minBucket = cmtFreqBuckets.find(cmtMinFreq);
if (minBucket != cmtFreqBuckets.end() && !minBucket->second.empty()) {
  ...
}
```

### And one shared with LRU

Both eviction paths can write back a dirty entry with `table[evictLpn] = ...`. That is an **insert** into `table`, which can rehash it and invalidate every outstanding iterator — including the `gmtIt` the function is about to dereference. Both paths now re-find after eviction:

```cpp
// A dirty write-back can insert into `table` and rehash it, which
// invalidates every iterator including gmtIt.  Re-find before use.
gmtIt = table.find(lpn);
```

---

## 9. Why LRU and LFU Score Almost the Same

Running the same workload under both policies gives:

| Policy | Hits | Misses | Hit rate |
|---|---|---|---|
| LRU | 32,588 | 98,484 | 24.86% |
| LFU | 32,570 | 98,502 | 24.85% |

A difference of 18 hits out of 131,072 accesses. They are genuinely both running — the eviction decisions differ — but the outcome is nearly identical. Two reasons, and both are results worth reporting rather than problems to fix.

**Uniform random access has no frequency information to exploit.** LFU's whole advantage is keeping genuinely hot pages that LRU would flush during a scan. If every page is equally likely, there are no hot pages, so there is nothing to protect and nothing to gain.

**After a sequential fill, LFU *is* LRU.** This one is more subtle and worth working through. The prefill writes each LPN exactly once, so every cached entry ends with frequency 1. LFU therefore has just one non-empty bucket. Its eviction rule is "take the back of the lowest-frequency bucket" — but with only bucket 1 populated, and entries pushed to the front as they arrive, the back of bucket 1 is precisely the least recently inserted entry. That is the LRU victim. The two policies degenerate to the same algorithm until enough hits accumulate to populate bucket 2, and at a 25% hit rate over a 49,152-entry cache that barely begins to happen.

> [!TIP]
> To separate the policies you need a workload with genuine hot/cold skew — a Zipf or hotspot distribution rather than uniform random. The current request generator only does uniform random, so demonstrating LFU's advantage would need a generator change. That the two policies tie under uniform random is the theoretically expected result, and stating it that way is a stronger finding than an unexplained tie.

---

## 10. What Is Still Not Modelled

Two simplifications remain. Neither is a bug, but both should be stated as limitations rather than left for a reader to discover.

**The GMT never leaves RAM.** In real DFTL the full mapping table lives on NAND and only the CMT is in memory. Here `table` is an in-memory `unordered_map` that is always fully resident. A "miss" is a hash lookup plus `tick += cmtMissLatency` — a latency penalty added to the clock, not an actual flash read issued to the PAL layer. The timing is modelled; the data movement is not.

**There are no translation pages.** Real DFTL stores mappings in 4 KB translation pages, each holding about 512 mappings. One miss loads the whole page, so 512 nearby mappings arrive together. Here one CMT entry is one LPN, so a miss loads one mapping and pays the full 40 µs NAND read for it.

The second is the more significant distortion. It removes all spatial locality from the translation cache, so sequential workloads look far worse than they would on real hardware, where one translation-page read serves the next 512 sequential accesses. Random workloads are affected much less, which is fortunate given that the sweep is mostly random — but it does mean the sequential results should be read as a lower bound.

---

## 11. Lessons Worth Keeping

**Silent bugs are the expensive ones.** Every bug here compiled cleanly and produced plausible numbers. A crash costs you an afternoon; a plausible wrong number costs you the conclusions you built on it.

**Check derived numbers against theory, not just against the config.** The 16.67% figure matching `capacity / totalLogicalPages` exactly is what turned "this looks a bit low" into "here is precisely what is wrong". A prediction you can check to four significant figures is worth more than any amount of code reading.

**When a fix requires edits in N places, fix the design instead.** Bug 2 existed because switching policies took six coordinated edits. Patching those six would have left the seventh person to make the same mistake. Making the switch a config key removed the entire class of error.

**Print your units.** Bug 3 survived a previous round of fixing because both the config and the computed capacity were internally consistent — the disagreement was about what "entry" meant, and nothing in the output exposed that. `cmt.entry_bytes` now does.

**Date your results.** Old outputs are not labelled with the code that produced them, so telling valid runs from invalid ones meant comparing file timestamps against `git log`. The new `cmt.policy`, `cmt.entry_bytes` and `cmt.capacity_bytes` stats embed the relevant configuration in every result file.

---

*Source: `simplessd/ftl/page_mapping.{cc,hh}`, `simplessd/ftl/config.{cc,hh}`.*
*Related: [`cmt_guide.md`](cmt_guide.md) for how the CMT works, [`ftl_guide.md`](ftl_guide.md) §7 for the earlier debugging history.*
