# Chapter 4 — Free Blocks: Ratio, Conversion, Allocation, Write Pointer

[← Back to `page_mapping` guide](README.md)

**Source:** [`page_mapping.cc`](../../SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc) lines **481–563**

**Prerequisites:** [02_constructor_init.md](02_constructor_init.md) (constructor calls `getFreeBlock`), [01_page_mapping_hh.md](01_page_mapping_hh.md) (`freeBlocks`, `blocks`, `lastFreeBlock`)

**Related:** GC triggers when free blocks drop — [05_gc.md](05_gc.md). Writes consume pages via `getLastFreeBlock` in [07_internal_io.md](07_internal_io.md).

---

## Overview

Flash writes need a **free physical block** with an empty page slot. This chapter covers:

1. **`freeBlockRatio()`** — telemetry: fraction of blocks still in the free pool.
2. **`convertBlockIdx()`** — map absolute block index → parallel **stream** index.
3. **`getFreeBlock(idx)`** — move one block from `freeBlocks` list to in-use `blocks` map, picking a block whose index ≡ `idx` mod `pageCountToMaxPerf`.
4. **`getLastFreeBlock(iomap)`** — rotate write streams and return the current open block for the next program, allocating a new block when the current one is full.

These functions maintain `nFreeBlocks` and the **write pointer** state used on every `writeInternal` call.

---

## Section A — `freeBlockRatio` (lines 481–483)

### Line range

`page_mapping.cc` **481–483**

### Purpose

Return the fraction of physical blocks that are still **free** (in `freeBlocks`, not in `blocks`).

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 481 | `float PageMapping::freeBlockRatio() {` | Simple query helper (also used for GC threshold checks elsewhere). |
| 482 | `  return (float)nFreeBlocks / param.totalPhysicalBlocks;` | `nFreeBlocks` maintained on every `getFreeBlock`; total from geometry. |
| 483 | `}` | |

### Invariants

- `0.0f ≤ return ≤ 1.0f` when counters consistent.
- Does not include “partially filled in-use blocks” as free — only blocks in `freeBlocks`.

### Links

- [05_gc.md](05_gc.md) — GC when ratio falls below `GCThresholdRatio`.

---

## Section B — `convertBlockIdx` (lines 485–487)

### Line range

`page_mapping.cc` **485–487**

### Purpose

Map a physical **block index** to its **parallel write stream** id `0 … pageCountToMaxPerf - 1`.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 485 | `uint32_t PageMapping::convertBlockIdx(uint32_t blockIdx) {` | Block index from mapping or allocation. |
| 486 | `  return blockIdx % param.pageCountToMaxPerf;` | Stream = block index mod parallelism count (interleaved stripes). |
| 487 | `}` | |

### Invariants

- Same stream id for all blocks whose indices differ by multiples of `pageCountToMaxPerf`.
- Used when selecting a free block matching a write stream in `getFreeBlock`.

### Links

- PAL geometry `pageCountToMaxPerf` — number of parallel units (dies/planes) for max performance.

---

## Section C — `getFreeBlock` (lines 489–531)

### Line range

`page_mapping.cc` **489–531**

### Purpose

Allocate one physical block from the **free list** for stream `idx`: prefer a free block whose index satisfies `blockIndex % pageCountToMaxPerf == idx`, move it into `blocks`, decrement `nFreeBlocks`, return block index. **Panic** if no free blocks remain.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 489 | `uint32_t PageMapping::getFreeBlock(uint32_t idx) {` | `idx` must be a valid stream id (&lt; `pageCountToMaxPerf`). |
| 490 | `  uint32_t blockIndex = 0;` | Will hold chosen block index. |
| 491 | *(blank)* | |
| 492 | `  if (idx >= param.pageCountToMaxPerf) {` | Invalid stream. |
| 493 | `    panic("Index out of range");` | Fatal. |
| 494 | `  }` | |
| 495 | *(blank)* | |
| 496 | `  if (nFreeBlocks > 0) {` | Allocation possible. |
| 497 | `    // Search block which is blockIdx % param.pageCountToMaxPerf == idx` | Comment: stream-aligned pick. |
| 498 | `    auto iter = freeBlocks.begin();` | Start of `std::list<Block>`. |
| 499 | *(blank)* | |
| 500 | `    for (; iter != freeBlocks.end(); iter++) {` | Scan entire free list (O(n) per allocation). |
| 501 | `      blockIndex = iter->getBlockIndex();` | Physical index of this free `Block` object. |
| 502 | *(blank)* | |
| 503 | `      if (blockIndex % param.pageCountToMaxPerf == idx) {` | Matches requested stream. |
| 504 | `        break;` | Stop search — use this iterator. |
| 505 | `      }` | |
| 506 | `    }` | End search loop. |
| 507 | *(blank)* | |
| 508 | `    // Sanity check` | Comment. |
| 509 | `    if (iter == freeBlocks.end()) {` | No stream-aligned block found (should be rare if geometry consistent). |
| 510 | `      // Just use first one` | Comment: fallback. |
| 511 | `      iter = freeBlocks.begin();` | Take arbitrary free block. |
| 512 | `      blockIndex = iter->getBlockIndex();` | Record its index. |
| 513 | `    }` | |
| 514 | *(blank)* | |
| 515 | `    // Insert found block to block list` | Comment: transition free → in-use. |
| 516 | `    if (blocks.find(blockIndex) != blocks.end()) {` | Block already in use map — corruption. |
| 517 | `      panic("Corrupted");` | Fatal double allocation. |
| 518 | `    }` | |
| 519 | *(blank)* | |
| 520 | `    blocks.emplace(blockIndex, std::move(*iter));` | Move `Block` into `unordered_map` keyed by index. |
| 521 | *(blank)* | |
| 522 | `    // Remove found block from free block list` | Comment. |
| 523 | `    freeBlocks.erase(iter);` | Remove from free list. |
| 524 | `    nFreeBlocks--;` | Decrement free counter. |
| 525 | `  }` | End `nFreeBlocks > 0` branch. |
| 526 | `  else {` | No free blocks. |
| 527 | `    panic("No free block left");` | FTL cannot proceed — GC should have run earlier. |
| 528 | `  }` | |
| 529 | *(blank)* | |
| 530 | `  return blockIndex;` | Return allocated block index to caller. |
| 531 | `}` | |

### Invariants

- After success: `blocks.count(blockIndex) == 1`, block not in `freeBlocks`, `nFreeBlocks` decreased by 1.
- Constructor calls this `pageCountToMaxPerf` times to fill `lastFreeBlock` ([02_constructor_init.md](02_constructor_init.md)).
- Stream alignment improves parallel write throughput in the PAL model.

### Links

- [02_constructor_init.md](02_constructor_init.md) — ctor allocation.
- [05_gc.md](05_gc.md) — returns blocks to `freeBlocks` after erase.

---

## Section D — `getLastFreeBlock` (lines 533–563)

### Line range

`page_mapping.cc` **533–563**

### Purpose

Return the **current open block** for the active write stream so `writeInternal` can program the next page. Optionally **rotate** the stream index based on `iomap` and `bRandomTweak`. If the open block is **full**, allocate a replacement via `getFreeBlock` and set `bReclaimMore` to encourage GC.

### Line-by-line

| Line | Code | Meaning |
| --- | --- | --- |
| 533 | `uint32_t PageMapping::getLastFreeBlock(Bitset &iomap) {` | `iomap` = which sub-pages this write touches. |
| 534 | `  if (!bRandomTweak \|\| (lastFreeBlockIOMap & iomap).any()) {` | Rotate stream if: tweak off **or** this write overlaps previous superpage sub-pages. |
| 535 | `    // Update lastFreeBlockIndex` | Comment. |
| 536 | `    lastFreeBlockIndex++;` | Advance round-robin stream selector. |
| 537 | *(blank)* | |
| 538 | `    if (lastFreeBlockIndex == param.pageCountToMaxPerf) {` | Wrapped past last stream. |
| 539 | `      lastFreeBlockIndex = 0;` | Wrap to stream 0. |
| 540 | `    }` | |
| 541 | *(blank)* | |
| 542 | `    lastFreeBlockIOMap = iomap;` | Replace tracked sub-page mask (new superpage stripe). |
| 543 | `  }` | |
| 544 | `  else {` | Random tweak on and write touches **disjoint** sub-pages from last write. |
| 545 | `    lastFreeBlockIOMap \|= iomap;` | Accumulate sub-pages in same superpage — **no** stream rotation. |
| 546 | `  }` | |
| 547 | *(blank)* | |
| 548 | `  auto freeBlock = blocks.find(lastFreeBlock.at(lastFreeBlockIndex));` | Lookup metadata for current stream's open block. |
| 549 | *(blank)* | |
| 550 | `  // Sanity check` | Comment. |
| 551 | `  if (freeBlock == blocks.end()) {` | `lastFreeBlock` points to block not in `blocks`. |
| 552 | `    panic("Corrupted");` | Fatal inconsistency. |
| 553 | `  }` | |
| 554 | *(blank)* | |
| 555 | `  // If current free block is full, get next block` | Comment. |
| 556 | `  if (freeBlock->second.getNextWritePageIndex() == param.pagesInBlock) {` | No empty pages left in this block. |
| 557 | `    lastFreeBlock.at(lastFreeBlockIndex) = getFreeBlock(lastFreeBlockIndex);` | Allocate new block for **same** stream index. |
| 558 | *(blank)* | |
| 559 | `    bReclaimMore = true;` | Hint GC logic that reclaim pressure increased ([05_gc.md](05_gc.md)). |
| 560 | `  }` | |
| 561 | *(blank)* | |
| 562 | `  return lastFreeBlock.at(lastFreeBlockIndex);` | Block index to write into. |
| 563 | `}` | |

### Invariants

- `lastFreeBlock[lastFreeBlockIndex]` always refers to a block in `blocks` with free page slots **after** return (unless `getFreeBlock` panics).
- When `bRandomTweak` is true, disjoint sub-page writes within one superpage share one stream; overlapping or tweak-off rotates streams.
- `bReclaimMore` set when a block boundary crossed — not cleared in this function.

### Links

- [07_internal_io.md](07_internal_io.md) — every write calls `getLastFreeBlock`.
- [02_constructor_init.md](02_constructor_init.md) — `bitsetSize`, `bRandomTweak` from ctor.

---

## Free-block state machine (conceptual)

```text
  freeBlocks (list)          blocks (map)
  ─────────────────          ──────────────
  Block 7  Block 12 ...  →   Block 3 (open, pages used)
                             Block 8 (open, stream 1)
       ↑ getFreeBlock        ↑ getLastFreeBlock returns index
       ↓ GC erase returns
```

| Counter / field | Updated by |
| --- | --- |
| `nFreeBlocks` | `getFreeBlock` (−1), GC erase (+1) |
| `lastFreeBlock[i]` | ctor, `getLastFreeBlock` when block full |
| `lastFreeBlockIndex` | `getLastFreeBlock` rotation |
| `lastFreeBlockIOMap` | `getLastFreeBlock` |
| `bReclaimMore` | `getLastFreeBlock` on block rollover |

---

## Self-quiz

1. What is `freeBlockRatio()` and when might the FTL care about it?
2. If `pageCountToMaxPerf = 4` and `blockIdx = 17`, what does `convertBlockIdx` return?
3. Why does `getFreeBlock` search for `blockIndex % pageCountToMaxPerf == idx`?
4. What happens if no stream-aligned block exists in `freeBlocks`?
5. What are the two panic paths in `getFreeBlock`?
6. When does `getLastFreeBlock` increment `lastFreeBlockIndex` vs only OR `lastFreeBlockIOMap`?
7. What does `getNextWritePageIndex() == param.pagesInBlock` mean?
8. Why is `bReclaimMore = true` set when allocating a new block in `getLastFreeBlock`?
9. After constructor, how many blocks are in `freeBlocks` vs `blocks`?
10. Does `getFreeBlock` touch the CMT or GMT?

### Answers

<details>
<summary>Click to reveal answers</summary>

1. **Ratio** = `nFreeBlocks / totalPhysicalBlocks`. GC and write paths compare it to `GCThresholdRatio` to start reclaiming before `getFreeBlock` panics ([05_gc.md](05_gc.md)).

2. **1** — `17 % 4 = 1` (stream index 1).

3. **Parallelism:** Keeps each write stream on blocks aligned to the same die/plane stripe so the PAL model can exploit parallel units.

4. **Fallback:** Uses `freeBlocks.begin()` — first available free block regardless of alignment (lines 509–512).

5. **`idx >= pageCountToMaxPerf`**, **`blocks` already has `blockIndex`**, and **`nFreeBlocks == 0`**.

6. **Increment** when `!bRandomTweak` OR `(lastFreeBlockIOMap & iomap).any()` — new superpage stripe or tweak disabled. **OR only** when tweak on and write sub-pages are disjoint from previous mask — stay on same stream, widen mask.

7. **Block full:** Next write page index equals `pagesInBlock` — no empty pages; must allocate a new physical block.

8. **GC pressure:** Closing a block adds invalid-page pressure elsewhere; flag tells GC path to reclaim more aggressively.

9. **`blocks`:** `pageCountToMaxPerf` (write pointers). **`freeBlocks`:** `totalPhysicalBlocks - pageCountToMaxPerf`. **`nFreeBlocks`** matches free list size ([02_constructor_init.md](02_constructor_init.md)).

10. **No** — pure block metadata / free-list management. Mapping updates happen in `writeInternal` via [06_cmt_access.md](06_cmt_access.md).

</details>
