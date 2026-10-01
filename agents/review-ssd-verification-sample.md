# SSD Fidelity Review — Verification Sample

**Date:** 2026-09-07  
**Scope:** branch changes vs `origin/2.0` merge-base (`ed25f53`) | **Focus:** FTL/CMT window-fill  
**Files reviewed:** `ftl/page_mapping.cc`, `ftl/page_mapping.hh`, `ftl/config.{cc,hh}`, `config/sample.cfg`

> This file documents the verification run performed when implementing `/reviewSSD`. Delete or archive if not needed; ongoing state lives in `review-ssd-memory.md`.

## Executive summary

CMT window-fill correctly approximates **spatial locality within a translation page** as a research simplification. It is not a full DFTL translation-page implementation. Core FTL invariants (out-of-place write, CMT/GMT coherence, GC-before-erase) remain sound on the reviewed branch.

## Prior review follow-up

First run — no prior items.

## Architectural invariant check

| Invariant | Status | Notes |
| --- | --- | --- |
| Out-of-place write | Sound | `writeInternal` unchanged in spirit |
| Mapping coherence | Sound | Demand LPN panic guard after prefetch eviction (~1143) |
| CMT vs GMT | Sound | Prefetch reads from `table`; dirty write-back unchanged |
| GC before erase | Sound | `doGarbageCollection` not modified by window-fill |
| Stats honesty | Sound | `fill_accuracy` fix in `3810825`; warm-up reset in place |
| Simplification honesty | At risk | Comments describe NAND translation-page read; code uses synthetic miss + DRAM charge |

## Findings

### Finding 1: Window-fill models translation-page spatial locality partially

**Real SSD behavior:** DFTL (Gupta et al., ASPLOS '09) reads one **translation page** from NAND on CMT miss, bringing ~hundreds of LPN mappings into SRAM in one flash read.

**Your code:** `page_mapping.cc:1135–1156` — on miss with `cmtWindowFill`, collects neighboring LPNs via `collectFillCandidates`, charges one `CMTMissLatency`, inserts batch at LRU end, charges DRAM via `chargeWindowFillDRAM`.

**Verdict:** Acceptable simplification

**Evidence:** DFTL §3 — demand-based caching; project baseline in `review-ssd-reference.md` (no translation pages on NAND).

**Suggested fix / documentation:** State in report: "window-fill approximates translation-page spatial fetch under GMT-in-RAM; not a PAL translation read."

### Finding 2: Prefetch disabled on GC path — correct

**Real SSD behavior:** GC relocation should not trigger speculative mapping prefetch that pollutes CMT under pressure.

**Your code:** `if (cmtWindowFill && !isGC && paidMissLatency)` (~1135, ~1348).

**Verdict:** Correct

**Evidence:** GC-induced mapping access is internal; prefetch during GC would not match DFTL demand-fetch semantics.

**Suggested fix / documentation:** None.

### Finding 3: GMT always in RAM — unchanged limitation

**Real SSD behavior:** Translation pages reside on NAND; CMT miss causes flash read.

**Your code:** Miss adds `CMTMissLatency` to `tick`; mappings loaded from in-memory `table`.

**Verdict:** Acceptable simplification (pre-existing)

**Evidence:** Census §28; `PROGRESS.md` Notes.

**Suggested fix / documentation:** Keep in fidelity limitations section of final report.

## Pre-existing limitations touched by this diff

- No translation-page packing on flash
- Synthetic miss/write-back latencies
- LFU no aging
- GC latency not on triggering write
- `EraseThreshold` effectively off

## Fidelity checklist

- [x] CMT miss models translation I/O cost appropriately (synthetic — documented)
- [x] Dirty eviction models translation write-back appropriately (unchanged)
- [x] Window-fill / prefetch matches translation-page read semantics (partial — acceptable with disclosure)
- [x] LRU/LFU semantics match policy literature
- [x] GC relocation follows out-of-place NAND rules
- [ ] GC latency accounting is honest (pre-existing gap — not introduced by window-fill)
- [x] Wear leveling claims match implementation (no change)
- [x] Experiment configs isolate CMT (ICL off in sweeps)
- [x] Reported stats cannot mislead (fill_accuracy fixed)

## Suggested next steps

1. Run `/reviewSSD` after each FTL commit; memory file updates automatically.
2. For Codex/Antigravity: @-mention `agents/review-ssd.md` + changed files.
3. Complete `randwrite`/`randrw` sweeps before LFU write-back claims in report.
