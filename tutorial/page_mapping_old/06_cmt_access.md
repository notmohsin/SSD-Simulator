# Chapter 06 — CMT Access: Dispatcher, LRU, LFU

**Source:** [`page_mapping.cc`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc) lines **799–1094**

**Companion docs:**

- [README.md](README.md) — study path, open questions (#1 unmapped read, #3 GC path)
- [08_CMT_Mentor_Census.md](../08_CMT_Mentor_Census.md) — full DFTL theory, §§15–16 (dirty/clean), §§21–24 (worked examples & walkthroughs), §25 (latency), §28 (fidelity limits)

**Functions in this chapter:** `accessCMT`, `accessCMT_LRU`, `accessCMT_LFU`

This is the **densest** chapter: every host read/write, GC relocation, and mapping lookup funnels through these functions.

---

## API contract

```cpp
std::vector<std::pair<uint32_t, uint32_t>> *
PageMapping::accessCMT(uint64_t lpn, bool isWrite, uint64_t &tick,
                       bool isGC = false, bool allocate = true);
```

| Parameter | Meaning |
| --- | --- |
| `lpn` | Logical page number (one CMT entry = one LPN’s mapping vector) |
| `isWrite` | If true, mark entry **dirty** on hit or insert |
| `tick` | Simulated time; miss/write-back latencies added here |
| `isGC` | If true, count `cmtGCHits` / `cmtGCMisses` instead of user stats |
| `allocate` | If false and LPN not in GMT → return `nullptr` (read/trim path) |

**Return value:** pointer to the `vector<pair<block,page>>` mapping for this LPN (live CMT copy), or `nullptr` when lookup-only and unmapped.

**Policy selection:** `cmtPolicy` from config (`CMT_POLICY_LRU` = 0, `CMT_POLICY_LFU` = 1).

---

## Data structures (quick reference)

### LRU

| Structure | Type | Role |
| --- | --- | --- |
| `cmt` | `unordered_map<uint64_t, pair<CMTEntry, list::iterator>>` | LPN → entry + position in order list |
| `cmtOrder` | `list<uint64_t>` | MRU at **front**, LRU at **back** |

`CMTEntry` holds `{ mapping vector, dirty bool }`.

### LFU

| Structure | Type | Role |
| --- | --- | --- |
| `cmtLFU` | `unordered_map<uint64_t, CMTEntryLFU>` | LPN → entry with freq + list iterator |
| `cmtFreqBuckets` | `unordered_map<uint64_t, list<uint64_t>>` | Frequency → LPNs at that freq (front = MRU within bucket) |
| `cmtMinFreq` | `uint64_t` | Smallest frequency with ≥1 entry |

`CMTEntryLFU` holds `{ mapping, dirty, freq, listIt }`.

---

## Invariants

### Shared (LRU & LFU)

1. **Capacity:** `cmt.size()` or `cmtLFU.size()` ≤ `cmtCapacity` after any call completes successfully.
2. **Allocate=false:** never create GMT entries; return `nullptr` if LPN absent from `table`.
3. **Dirty write-back:** on eviction, if `dirty`, copy `mapping` to `table[lpn]`, increment `cmtDirtyEvictions` and `cmtWritebacks`, `tick += cmtWriteBackLatency`.
4. **Rehash safety:** after dirty write-back into `table`, re-`find` `gmtIt` before use (insert may rehash).
5. **Miss latency:** paid only when LPN exists in GMT before the miss; brand-new LPN emplace pays **no** `cmtMissLatency`.
6. **GC vs user stats:** `isGC` only changes which counter increments; algorithm is identical.

### LRU-specific

7. **Order sync:** every key in `cmt` appears exactly once in `cmtOrder`; `it->second.second` points to its list node.
8. **Victim:** when full, evict `cmtOrder.back()` (LRU).
9. **Promotion:** every hit splices to `cmtOrder.begin()` regardless of read vs write.

### LFU-specific

10. **Bucket membership:** each LPN appears in exactly one `cmtFreqBuckets[f]` list; `entry.listIt` points to its node.
11. **Min frequency:** `cmtMinFreq` is the minimum `f` such that `cmtFreqBuckets[f]` is non-empty (repaired by `repairLFUMinFreq` when stale).
12. **Victim:** when full, evict `cmtFreqBuckets[cmtMinFreq].back()` (LFU, LRU tie-break within bucket).
13. **Insertion:** every new entry starts at `freq = 1`; `cmtMinFreq = 1` after insert.
14. **Hit promotion:** remove from bucket `f`, insert at **front** of bucket `f+1`; if old bucket was min and now empty, `cmtMinFreq = f+1`.

---

## `accessCMT` — dispatcher (lines 799–807)

| Line | Code | Meaning |
| --- | --- | --- |
| 799–801 | Return type `vector<pair<uint32_t,uint32_t>> *` | Pointer to mapping vector for caller to read/update |
| 800 | `accessCMT(lpn, isWrite, tick, isGC, allocate)` | Single entry point for all CMT policies |
| 802–804 | `if (cmtPolicy == CMT_POLICY_LFU) return accessCMT_LFU(...)` | Config switch |
| 806 | `return accessCMT_LRU(...)` | Default path |

No logic beyond dispatch — keeps `readInternal` / `writeInternal` / GC policy-agnostic.

---

## `accessCMT_LRU` (lines 816–922)

### Hit branch (lines 819–841)

| Line | Code | Meaning |
| --- | --- | --- |
| 816–818 | Function signature | Same parameters as dispatcher |
| 819 | `auto it = cmt.find(lpn);` | O(1) hash lookup |
| 824 | `if (it != cmt.end())` | **Cache hit** |
| 826–830 | `if (isGC) cmtGCHits++ else cmtHits++` | Separate accounting |
| 833 | `cmtOrder.splice(cmtOrder.begin(), cmtOrder, it->second.second)` | Move LPN to MRU (O(1)) |
| 836–838 | `if (isWrite) it->second.first.dirty = true` | Writes dirty the entry |
| 840 | `return &it->second.first.mapping` | Caller mutates mapping in place |

**Design note:** splice runs on **every** hit, including reads. Otherwise LRU would mean “recently written,” not “recently used.”

### Miss branch — counting & allocate guard (lines 846–860)

| Line | Code | Meaning |
| --- | --- | --- |
| 847–851 | GC vs user miss counters | `cmtGCMisses` / `cmtMisses` |
| 853 | `gmtIt = table.find(lpn)` | Check Global Mapping Table |
| 858–860 | `if (gmtIt == end && !allocate) return nullptr` | Read to never-written LPN: count miss, no allocation, no latency |

### Miss branch — eviction (lines 862–892)

| Line | Code | Meaning |
| --- | --- | --- |
| 863 | `if (cmt.size() >= cmtCapacity)` | Cache full → must evict |
| 864 | `evictLpn = cmtOrder.back()` | LRU victim |
| 869 | `evictIt = cmt.find(evictLpn)` | Map lookup **before** list pop (desync guard) |
| 870–871 | if found: `pop_back()`, `cmtEvictions++` | Remove LRU only if map agrees |
| 876–884 | if `dirty`: write-back to GMT, stats, `tick += cmtWriteBackLatency` | DFTL translation page program |
| 886 | `cmt.erase(evictIt)` | Remove from cache map |
| 890 | `gmtIt = table.find(lpn)` | Re-find after possible rehash |

### Miss branch — load & insert (lines 894–921)

| Line | Code | Meaning |
| --- | --- | --- |
| 896–907 | `if (gmtIt == end)` emplace sentinel vector | First write to LPN: create GMT with “invalid” PPNs; **no** miss latency |
| 909–913 | `else tick += cmtMissLatency` | Existing GMT entry: NAND translation read cost |
| 916 | `cmtOrder.push_front(lpn)` | New entry is MRU |
| 917–919 | `cmt.emplace(lpn, {CMTEntry{gmtIt->second, isWrite}, begin()})` | Insert with dirty = isWrite |
| 921 | `return &insertResult.first->second.first.mapping` | Pointer to new cache copy |

---

## `accessCMT_LFU` (lines 951–1094)

### Hit branch — frequency promotion (lines 954–991)

| Line | Code | Meaning |
| --- | --- | --- |
| 954 | `auto it = cmtLFU.find(lpn)` | LFU map lookup |
| 959 | `if (it != cmtLFU.end())` | **Cache hit** |
| 961 | GC/user hit stats | Same as LRU |
| 963 | `CMTEntryLFU &entry = it->second` | Mutable reference |
| 968 | `oldFreq = entry.freq` | Current frequency |
| 969 | `cmtFreqBuckets[oldFreq].erase(entry.listIt)` | Remove from old bucket |
| 972–977 | if old bucket empty: erase map key; if was min, `cmtMinFreq = oldFreq+1` | Min can only rise by 1 on a hit |
| 981–984 | `newFreq = oldFreq+1`; insert at **front** of new bucket; update `listIt` | MRU within new frequency |
| 988 | `if (isWrite) entry.dirty = true` | Dirty on write |
| 990 | `return &entry.mapping` | |

### Miss branch — allocate guard (lines 996–1004)

| Line | Code | Meaning |
| --- | --- | --- |
| 996 | `if (isGC) cmtGCMisses++ else cmtMisses++` | Count miss **before** deciding whether to allocate |
| 998 | `gmtIt = table.find(lpn)` | Look up GMT |
| 1002–1004 | `if (gmtIt == end && !allocate) return nullptr` | Read/trim to never-written LPN: miss counted, no latency, no insert (same as LRU) |

### Miss branch — LFU eviction (lines 1013–1058)

| Line | Code | Meaning |
| --- | --- | --- |
| 1013 | `if (cmtLFU.size() >= cmtCapacity)` | Full cache |
| 1018 | `minBucket = cmtFreqBuckets.find(cmtMinFreq)` | Avoid `operator[]` creating empty bucket |
| 1020–1023 | if missing/empty → `repairLFUMinFreq()` and retry | Stale min after `cmtErase` |
| 1025–1027 | still empty → `panic` | Never silently overflow |
| 1029 | `evictLpn = minBucket->second.back()` | LFU + LRU tie-break |
| 1030 | `pop_back()` | Remove victim from bucket |
| 1032–1036 | if bucket empty, erase from `cmtFreqBuckets` | Cleanup (insert resets min to 1) |
| 1038 | `cmtEvictions++` | |
| 1041–1053 | dirty write-back + erase from `cmtLFU`; panic if map miss | Same as LRU |
| 1057 | `gmtIt = table.find(lpn)` | Rehash safety |

### Miss branch — load & insert at freq 1 (lines 1061–1093)

| Line | Code | Meaning |
| --- | --- | --- |
| 1062–1070 | New GMT entry if needed | No miss latency |
| 1071–1074 | Else `tick += cmtMissLatency` | |
| 1081 | `cmtMinFreq = 1` | New entry always at minimum frequency |
| 1082 | `cmtFreqBuckets[1].push_front(lpn)` | MRU within freq-1 bucket |
| 1084–1088 | Build `CMTEntryLFU` with `freq=1`, `dirty=isWrite` | |
| 1090 | `cmtLFU.emplace(lpn, move(newEntry))` | |
| 1093 | `return &insertResult.first->second.mapping` | |

---

## Latency & statistics cheat sheet

| Event | `tick` change | Counter |
| --- | --- | --- |
| Hit (LRU or LFU) | none | `cmtHits` or `cmtGCHits` |
| Miss, new LPN | none | `cmtMisses` / `cmtGCMisses` |
| Miss, existing GMT | `+= cmtMissLatency` | miss counter |
| Miss, unmapped read (`allocate=false`) | none | miss counter, then `nullptr` |
| Dirty eviction | `+= cmtWriteBackLatency` | `cmtEvictions`, `cmtDirtyEvictions`, `cmtWritebacks` |
| Clean eviction | none | `cmtEvictions` only |

Full table: [Census §25](../08_CMT_Mentor_Census.md#25-latency-model--what-adds-to-tick).

---

## Worked trace — LRU (capacity = 3)

Notation: **CMT order** is MRU → LRU. `*` = dirty. `evict(X)` means LRU victim at back; `WB` = write-back latency if dirty.

Assume all LPNs already exist in GMT (so every miss pays `cmtMissLatency` except step 1’s first-touch emplace).

| Step | Operation | Hit/Miss | Action | CMT (MRU→LRU) | dirty? | tick extras |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | W A | miss | insert | [A*] | A* | — (new GMT) |
| 2 | W B | miss | insert | [B*, A*] | both | +miss |
| 3 | W C | miss | insert | [C*, B*, A*] | all | +miss |
| 4 | R A | hit | splice A→front | [A*, C*, B*] | unchanged | — |
| 5 | W D | miss | evict B* (LRU back), WB B, insert D | [D*, A*, C*] | D*,A*,C* | +miss, +WB |
| 6 | R C | hit | splice C→front | [C*, D*, A*] | — | — |
| 7 | R B | miss | evict A* (back), WB A, load B | [B*, C*, D*] | B* | +miss, +WB |

**Step 5 detail:** after step 4, order is `[A*, C*, B*]`; back = B*. B is dirty → write-back before erase from CMT.

**Step 7 detail:** B was evicted at step 5 but remains in GMT (written back). Miss reloads B from GMT (+miss latency).

---

## Worked trace — LFU (capacity = 3, same operations)

Notation: `fN: [list]` = frequency bucket, front = MRU within bucket. Victim = `back()` of `cmtMinFreq` bucket.

| Step | Op | Hit/Miss | Promotion / eviction | Buckets after | cmtMinFreq |
| --- | --- | --- | --- | --- | --- |
| 1 | W A | miss | insert f1 | f1: [A*] | 1 |
| 2 | W B | miss | insert f1 | f1: [B*, A*] | 1 |
| 3 | W C | miss | insert f1 | f1: [C*, B*, A*] | 1 |
| 4 | R A | hit | A: f1→f2 (front of f2) | f1: [C*, B*] ; f2: [A*] | 1 |
| 5 | W D | miss | victim = f1.back() = B*; WB B; insert D at f1 | f1: [D*, C*] ; f2: [A*] | 1 |
| 6 | R C | hit | C: f1→f2 | f1: [D*] ; f2: [C*, A*] | 1 |
| 7 | R B | miss | victim = f1.back() = D*; WB D; B at f1 | f1: [B*] ; f2: [C*, A*] | 1 |

**Contrast with LRU at step 5:** LRU evicted B because B was LRU in the list. LFU also evicted B because B was still at frequency 1 and was the LRU among freq-1 entries (back of f1). A survived at freq 2 even though it was “older” in wall-clock than C.

**Step 6 contrast:** C promotes to freq 2. In LRU, C went to the front; in LFU, C joins f2 at the front (ahead of A in that bucket).

**Cache pollution scenario (LFU advantage):** trace `R H, R H, R H, R X, R Y, R Z, R H` with capacity 3. LRU evicts H when X,Y,Z fill the cache; LFU keeps H at freq 4 while one-time X,Y,Z stay at freq 1 and get evicted first.

**Cache poisoning scenario (LFU disadvantage):** H was hot early (freq 100) but is now cold. LFU keeps H until 99 other entries catch up; LRU would have evicted H long ago. See [Census §28](../08_CMT_Mentor_Census.md#28-fidelity-limits--say-these-out-loud).

---

## Side-by-side: eviction at capacity

| | LRU | LFU |
| --- | --- | --- |
| Victim pick | `cmtOrder.back()` | `cmtFreqBuckets[cmtMinFreq].back()` |
| Hit update | splice to front | freq++, move to front of next bucket |
| New insert position | `push_front` on `cmtOrder` | `push_front` on `cmtFreqBuckets[1]` |
| Tie-break | implicit (list order) | LRU within same frequency |
| Stale metadata risk | list/map desync | stale `cmtMinFreq` → `repairLFUMinFreq` |

---

## Call-site matrix

| Caller | isWrite | isGC | allocate | Typical outcome |
| --- | --- | --- | --- | --- |
| `writeInternal` | true | false | true | hit/miss, dirty |
| `readInternal` | false | false | false | hit, or miss→nullptr if unmapped |
| `doGarbageCollection` | true | true | true | update relocated mapping |
| `getLiveMapping` | — | — | — | does **not** call `accessCMT` (peek CMT/GMT) |

---

## Edge cases (exam favourites)

### Edge Case 1 — CMT full (both policies)

Evict one entry before insert. LRU: back of list. LFU: back of min-freq bucket.

### Edge Case 2 — Dirty eviction

`table[evictLpn] = mapping` synchronizes GMT. Without this, a later miss loads stale data from GMT.

### Edge Case 3 — Brand-new LPN (first write)

`table.emplace` with sentinel invalid PPNs `{totalPhysicalBlocks, pagesInBlock}`. No flash read — nothing on NAND yet.

### Edge Case 4 — Existing LPN miss

`tick += cmtMissLatency` models reading a translation page from NAND (DFTL double-read).

### Edge Case 5 — LFU stale `cmtMinFreq`

After `cmtErase` empties the min bucket, `repairLFUMinFreq` scans for the next occupied frequency. Without repair, `operator[]` on a missing bucket could create empty buckets and undefined `.back()` behaviour — fixed path panics instead of silent overflow.

### Edge Case 6 — Unmapped read

`readInternal` → `accessCMT(..., allocate=false)`: **miss counter increments**, returns `nullptr`, **no** latency, **no** GMT growth. Documented quirk in [README open questions](README.md).

---

## Complexity

| Operation | LRU | LFU |
| --- | --- | --- |
| Hit | O(1) find + O(1) splice | O(1) find + O(1) bucket move |
| Miss insert | O(1) push_front + emplace | O(1) bucket insert + emplace |
| Eviction | O(1) back + erase | O(1) min bucket back + erase |

LFU uses the frequency-bucket technique (Shah, Mitra, Matani, 2010) cited in source comments.

---

## Flowchart (miss path, common skeleton)

```text
accessCMT(lpn, ...)
        │
        ├─ policy == LFU? ──yes──► accessCMT_LFU
        │                    no
        └────────────────────► accessCMT_LRU

Inside LRU/LFU:
  find(lpn)
    ├─ HIT ──► stats, promote, maybe dirty, return &mapping
    └─ MISS ─► stats
              ├─ !allocate && !in GMT ──► nullptr
              ├─ full? ──► evict (dirty WB?), erase
              ├─ !in GMT? ──► emplace sentinel (no miss lat)
              └─ else ──► tick += missLatency
              insert new entry
              return &mapping
```

---

## Self-quiz (10 questions)

1. What is the only behavioural difference between `accessCMT` and its `_LRU` / `_LFU` implementations?
2. On an LRU **read hit**, does the entry become dirty? Does it move in `cmtOrder`?
3. When does `accessCMT` return `nullptr`?
4. Why is `gmtIt` re-assigned with `table.find(lpn)` after a dirty eviction?
5. For a brand-new LPN on first write, which latencies and counters apply?
6. How does `isGC` affect the replacement algorithm vs statistics?
7. In LFU, where is a new entry inserted, and what happens to `cmtMinFreq`?
8. On an LFU hit at frequency `f` that empties the minimum bucket, how does `cmtMinFreq` change?
9. Why does LFU insert promoted entries at the **front** of the new frequency bucket?
10. Under uniform random reads after warm-up, why might LFU show similar hit rate to LRU but fewer dirty evictions?

---

## Self-quiz — answers

1. **Dispatcher only** routes by `cmtPolicy`; all cache logic lives in `_LRU` or `_LFU`.
2. **Not dirty** on read hit; **yes**, it splices to the front (MRU) on every hit.
3. When `allocate == false` and the LPN is not in `table` (never written / trimmed away).
4. Dirty write-back does `table[evictLpn] = ...`, which may **rehash** `unordered_map` and invalidate `gmtIt`.
5. `cmtMisses++` (or GC variant); **no** `cmtMissLatency` (emplace new GMT); entry inserted dirty if `isWrite`.
6. **Algorithm unchanged**; only `cmtGCHits`/`cmtGCMisses` vs `cmtHits`/`cmtMisses` differ. User `hit_rate` ignores GC.
7. Front of `cmtFreqBuckets[1]`; `cmtMinFreq` set to **1** (new entry is always minimum frequency).
8. If emptied bucket was `cmtMinFreq`, then `cmtMinFreq = oldFreq + 1` (only the promoted entry left the min bucket).
9. **LRU tie-break within frequency:** among entries with the same count, evict the least recently used (back of list).
10. Warm-up writes dirtied many entries at freq 1. One read hit promotes an entry to freq 2, protecting it from freq-1 eviction; fewer dirty victims evicted while overall hit rate stays near capacity/working-set ratio. See [Census §22](../08_CMT_Mentor_Census.md#22-lfu-worked-example-same-first-five-ops).

---

**Previous:** [05_gc.md](05_gc.md) — GC victim selection and `accessCMT` in relocation.

**Next:** [07_internal_io.md](07_internal_io.md) — `readInternal`, `writeInternal`, trim, erase.
