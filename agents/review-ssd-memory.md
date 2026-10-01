# SSD Fidelity Review — Memory

_Last updated: 2026-09-29 (/reviewSSD after window-fill budget + trace byte parse)_

## Last review

- **Date:** 2026-09-29
- **Scope:** `SimpleSSD-Standalone` + `simplessd` `my-modifications` vs `origin/2.0`, plus uncommitted fill budget, `run.sh` WF default, `trace_stg_0` byte fields, `config/ssd_trace_replay.cfg`.
- **Verdict:** **Sound with documented simplifications.** No Incorrect FTL findings. Window-fill is no longer a full-page install on every miss.

## Open action items

1. Align `sample.cfg` window-fill comment with `windowFillBudget` (full window only on same-window follow-up miss, or free slots).
2. Thesis: coalesced 1× dirty write-back per fill batch; GMT still in RAM.
3. Run sequential `TEST_MODE` once: second miss in a window may still evict up to `windowSize-1` entries.

## Resolved since last review

- Random full-CMT mass eviction capped (`cmt_fill_budget.hh`, `page_mapping.cc` ~1173).
- `stg_0` byte offset/length; trace cfg FillRatio 0 (experiment, not FTL).
- Coalesced write-back stated in `evictForFillBatch` and `tutorial/11_CMT_Window_Fill_Nomenclature.md`.
- GC `getLiveMapping` still in place (`page_mapping.cc:777`).

## Architectural invariant snapshot

| Invariant | Status | Last checked |
| --- | --- | --- |
| Out-of-place write | Sound | 2026-09-29 |
| Mapping coherence | Sound | 2026-09-29 |
| CMT vs GMT | Sound | 2026-09-29 |
| GC before erase | Sound | 2026-09-29 |
| Stats honesty | Sound | 2026-09-29 |
| Simplification honesty | At risk — sample.cfg still says every miss loads a window | 2026-09-29 |

## Re-check on next review

- [ ] `windowFillBudget` if sequential detection changes
- [ ] `evictForFillBatch` latency if charging model changes
- [ ] `getLiveMapping` if GC path changes
