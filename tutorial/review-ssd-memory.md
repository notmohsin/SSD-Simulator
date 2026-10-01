# SSD Fidelity Review — Memory

_Last updated: 2026-09-10 (post 24-job sweep validation)_

## Last review

- **Date:** 2026-09-10
- **Scope:** Full branch `my-modifications` vs `origin/2.0`. All committed, staged, unstaged changes in standalone + submodule. 24-job sweep `sweep_Sep10_12-12AM`.
- **Verdict:** **Sound (PASS).** No Incorrect or Misleading findings. CMT counters honest. Window-fill functionally correct. GC pollution fix (`getLiveMapping`) intact.

## Open action items

1. **Document evictForFillBatch latency coalescing** — `page_mapping.cc:901-922` caps dirty write-back latency to 1× per fill batch. Gives window-fill optimistic speed advantage. Must document in thesis. Verdict if omitted: Misleading.
2. **Document window-fill as approximation** — One miss latency buys a window of LPNs without PAL translation-page I/O (`page_mapping.cc:1137+1154`). Code comments exist but thesis-facing docs do not.
3. **Pre-existing GC latency gap** — `writeInternal` local `beginAt`; on-demand GC tick not added to triggering write latency. Document as simplification.
4. **Test sequential workloads** — fill_accuracy ≈ 0% on rand* is confirmed correct. Need sequential/strided workload to validate fill_accuracy > 0%.
5. **Test GC under high fill** — Run `fill=0.95, 16G, randwrite` to verify `gc_hits/gc_misses` sane under GC pressure.

## Resolved since last review

- **PF Acc 0% on rand* is expected** — Confirmed with 24-job sweep evidence. Not a bug.
- **Peak RAM column unreliable** — VmRSS polling removed from `run.sh`. Resolved.
- **GC CMT pollution** — `getLiveMapping()` at `page_mapping.cc:772` intact; `gc_hits = gc_misses = 0` in all fill=0.8 jobs.
- **O(N log N) victim sort** — `std::nth_element` at `page_mapping.cc:705`; semantics unchanged.
- **sample.cfg FillRatio** → `0.8` confirmed.
- **Build flags** — `DEBUG_BUILD=OFF`, `-O3 -march=native` standalone, `-O2 -g` simplessd.

## Validation snapshot (2026-09-10 sweep)

| Pattern | Hit% | Evictions | fill_ins | Notes |
| --- | --- | --- | --- | --- |
| randwrite LRU WF_OFF 16MiB | 13.40% | 908K | 0 | Baseline |
| randwrite LRU WF_ON 16MiB | 13.40% | 329M | 328M | WF churn; dirty_evict=908K |
| randread LRU WF_OFF 16→32MiB | 13.40%→26.87% | — | 0 | Capacity scaling ✅ |
| randread LRU vs LFU WF_OFF 16MiB | 13.40% vs 13.39% | — | 0 | Near-identical on uniform random |

## Architectural invariant snapshot

| Invariant | Status | Last checked |
| --- | --- | --- |
| Out-of-place write | Sound | 2026-09-10 |
| Mapping coherence | Sound | 2026-09-10 |
| CMT vs GMT | Sound — GC uses `getLiveMapping`, no CMT pollution | 2026-09-10 |
| GC before erase | Sound — gc.count=0 at fill=0.8 expected | 2026-09-10 |
| Stats honesty | Sound — all counters on correct paths; warm-up excluded | 2026-09-10 |
| Simplification honesty | At risk — evictForFillBatch latency coalescing needs thesis docs | 2026-09-10 |

## Re-check on next review

- [ ] `evictForFillBatch` if write-back latency model changes
- [ ] Any diff touching `doGarbageCollection` or `getLiveMapping`
- [ ] `selectVictimBlock` if GC policy changes
- [ ] Sequential workload fill_accuracy validation
- [ ] GC stress test at fill=0.95

## Sweep output used

- `outputs/sweep_Sep10_12-12AM/` (24 jobs, 24 complete)
