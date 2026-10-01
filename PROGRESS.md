# Project Progress

Last updated: 2026-08-11

SIP 2026 — CMT (Cached Mapping Table) study on a SimpleSSD fork.
Working tree: `SimpleSSD-Standalone/`, with the simulator itself in the `simplessd/` submodule.

## Deliverables

| Deliverable | State | Evidence |
| --- | --- | --- |
| CMT with runtime-selectable LRU/LFU policy | Done | `CMTPolicy` in `simplessd/ftl/config.cc`; `accessCMT_LRU` / `accessCMT_LFU` in `simplessd/ftl/page_mapping.cc` |
| Hit rate that excludes warm-up | Done | `resetCMTStats()` at the end of `PageMapping::initialize()` |
| Correct CMT size accounting | Done | `cmtCapacity = cmtBytes / cmtEntryBytes`; `cmt.entry_bytes` and `cmt.capacity_bytes` stats |
| Destroy paths use live mappings | Done | `getLiveMapping()` used by `format()` and `trimInternal()`; LFU `cmtMinFreq` repaired in `cmtErase` |
| Simulator builds and both policies run | Done | `make -j$(nproc)` exits 0; 2026-08-07 smoke under `CMTPolicy = 0` and `1` |
| Clean output tree for review | Done | `outputs/` keeps only `sweep_2h_20260806_185300/` + `sweep_console.log` (~940K) |
| CMT documentation for a second-year reader | Done | `tutorial/07_CMT_Review_And_Fixes.md`, `tutorial/08_CMT_Mentor_Census.md` |
| Annotated `page_mapping.{hh,cc}` guide | Done | `tutorial/page_mapping/` — README + chapters 01–08 (full FTL + CMT, annotated blocks) |
| Whole-simulator architecture guide with FTL depth | Done | `tutorial/architecture/` — README + chapters 01–08 (event model, boot, layer contracts, `ftl.cc` / `block.cc` / `config.cc` annotated, two end-to-end traces) |
| Sweep results under corrected accounting | In progress | `outputs/sweep_2h_20260806_185300/` — `randread` complete; write/mixed incomplete |
| Report reflects corrected results | Not started | `Report/SIP_Final_Report_IIT_Ropar.md` |
| Presentation reflects corrected results | Not started | `Presentation/presentation.tex` |
| SSD fidelity review agent (`/reviewSSD`) | Done | `agents/review-ssd.md`, `agents/review-ssd-reference.md`, `.cursor/skills/reviewSSD/SKILL.md` |

## Done

- [x] 2026-08-06 — Reviewed the CMT implementation and confirmed the active LRU is correct: O(1) splice on hit, recency updated on read and write hits, victim from `cmtOrder.back()`, evicted entry erased from both the list and the map. The commented-out block was LFU, not LRU.
- [x] 2026-08-06 — Fixed the half-applied LFU migration. `flushCMT()`, `format()` and the occupancy stat were reading `cmtLFU` while `accessCMT()` used `cmt`, so dirty entries were never flushed, formatted LPNs returned stale hits, and occupancy always read 0. It compiled, so it failed silently. — `simplessd/ftl/page_mapping.cc`
- [x] 2026-08-06 — Replaced the manual LRU/LFU swap with a `CMTPolicy` config key (0 = LRU, 1 = LFU). All cache access now goes through `accessCMT()`, `cmtErase()` and `cmtSize()`, so no call site touches the containers directly and the two policies cannot fall out of sync. — `simplessd/ftl/config.{hh,cc}`, `simplessd/ftl/page_mapping.{hh,cc}`
- [x] 2026-08-06 — Zeroed the CMT counters after warm-up. Prefill drove every mapping through the CMT as a compulsory miss, roughly halving every reported hit rate. — `PageMapping::initialize()`
- [x] 2026-08-06 — Stopped reads and trims allocating mappings for never-written LPNs, via an `allocate` flag on `accessCMT()`. Upstream `readInternal` did nothing on a miss; the CMT version was growing the GMT without bound and filling the cache with entries that can never hit. — `readInternal`, `trimInternal`
- [x] 2026-08-06 — Fixed `trimInternal`, which decided a superpage was mapped from sub-page 0 alone and then invalidated every sub-page including unmapped ones.
- [x] 2026-08-06 — Fixed CMT capacity accounting. One entry holds `bitsetSize` mappings, measured at 8 on this config, so `bytes / 8` was 8x too generous: the sweep's "2 MB" cache was really 16 MB. Now `bytes / (8 * bitsetSize)`. — confirmed by debug run: `64 B/entry (bitsetSize 8)`
- [x] 2026-08-06 — Added `cmt.policy`, `cmt.entry_bytes` and `cmt.capacity_bytes` stats so every result file records the policy and true cache size it was produced with.
- [x] 2026-08-06 — Made `CMTPolicy`, `CMTMissLatency` and `CMTWriteBackLatency` explicit in `simplessd/config/sample.cfg` and `gc_test.cfg` rather than relying on code defaults.
- [x] 2026-08-06 — Rebuilt and validated: `make` clean, both policies run, and they genuinely diverge on a high-reuse workload (LRU 32,588 hits vs LFU 32,570 over 131,072 accesses).
- [x] 2026-08-06 — Added a policy dimension to `run_sweep_2h.sh` (`-p 0,1`), with the policy in every filename and header, and fixed sub-megabyte sizes rendering as `0MB`.
- [x] 2026-08-06 — Repo cleanup: untracked `outputs/io64.txt` and `outputs/io64debugOn.txt` (kept on disk), removed 4 empty run dirs, the aborted `sweep_2h_20260723_121944`, and the one-off `activate_lfu.py` and `lfu_code.txt`.
- [x] 2026-08-06 — Wrote `tutorial/07_CMT_Review_And_Fixes.md`, a walkthrough of all five bugs aimed at a second-year reader, and corrected the now-wrong capacity and LFU-activation sections in `cmt_guide.md`, `ftl_guide.md` and `06_CMT_Deep_Dive.md`.
- [x] 2026-08-06 — Taught `compare_stats.py` to report `CMT Policy` and `CMT Size (B)` so LRU/LFU comparisons are unambiguous.
- [x] 2026-08-06 — Created the `/plan` skill at `.cursor/skills/plan/SKILL.md` and seeded this file.
- [x] 2026-08-06 — Fixed output file layout in `run_sweep_2h.sh`, `run_sim.sh`, and `run_parallel.sh`: subsystem stats first, then run summary. Root cause was `LogFile = sim_stats.log` plus scripts appending stdout before `cat` of the log. Also stripped the `\33[2K\r` progress erase escape from captured stdout.
- [x] 2026-08-06 — Removed the post-hoc WAF line from `run_sim.sh` (it was script-computed, not a simulator stat, and matched `dram.write.bytes` by accident).
- [x] 2026-08-06 — Confirmed BIL spam (`[BIL] submitIO ...`) was a hardcoded `std::cerr` in `bil/entry.cc` (added for tracing, removed in `2b6f4ef`). Not a config knob. Current binary has no `[BIL]` string.
- [x] 2026-08-07 — Deleted ~25G of junk under `outputs/` and `results/prefill_95.txt`. Kept only `outputs/sweep_2h_20260806_185300/` and `outputs/sweep_console.log` (tree now ~940K). Removed BIL-spam dirs, superseded Jul 2h sweeps, smoketests, and ad-hoc leftovers.
- [x] 2026-08-07 — Fixed `format()` to invalidate from the live mapping via `getLiveMapping()` (CMT if resident/dirty, else GMT) and to skip unmapped sub-pages. Previously GMT alone could still hold the allocate sentinel or a pre-writeback PPN → panic or valid-page leak, then `cmtErase` dropped the true mapping. — `simplessd/ftl/page_mapping.cc`
- [x] 2026-08-07 — Fixed LFU `cmtErase` to call `repairLFUMinFreq()` when the emptied bucket was `cmtMinFreq`. Full-cache eviction now repairs once and panics if still empty, instead of silently skipping and overflowing capacity. — `cmtErase`, `accessCMT_LFU`
- [x] 2026-08-07 — Stopped `trimInternal` from load-then-erase: it peeks with `getLiveMapping()` so a miss no longer dirty-evicts a victim, pays miss latency, inserts the doomed LPN, then erases it. — `trimInternal`
- [x] 2026-08-07 — Rebuild + dual-policy smoke (`64M randrw`, both policies): 117-line clean layout, `bil=0`, `cmt.capacity_bytes=2097152`, no panic. Smoke temps deleted; `outputs/` unchanged.
- [x] 2026-08-07 — Wrote mentor-facing CMT census: `tutorial/08_CMT_Mentor_Census.md` (expanded 2026-08-07 into a full-picture guide: glossary, SSD/FTL background, end-to-end R/W/trim/GC, worked LRU/LFU examples, capacity math, output reading, study checklist, Q&A).
- [x] 2026-08-09 — Wrote annotated `page_mapping` series: `tutorial/page_mapping/` (README + 01–08 covering header, ctor/init, public I/O, free blocks, GC, CMT access, internal I/O, wear/stats). Linked from census and `FTL Line-by-Line Notes.md`.
- [x] 2026-08-11 — Wrote the simulator-architecture series: `tutorial/architecture/` (README + 01–08, 2862 lines). Covers the two time domains, boot and construction order, every non-FTL subsystem as a black-box contract, the nine-file FTL map, and annotated `ftl.{hh,cc}` + `abstract_ftl.hh`, `common/block.{hh,cc}`, `config.{hh,cc}`, closing with two end-to-end traces. Pointer lines added to tutorials 01/04/05, `FTL Line-by-Line Notes.md`, `page_mapping/README.md`, and the census.

## In progress

- [ ] Write-workload half of the sweep. `randwrite` is 16/60 and `randrw` is 0/60. Resume with `bash run_sweep_2h.sh -p 0,1` after trimming `WORKLOADS` to the missing workloads, so the finished `randread` block is not recomputed.

## Not started

- [ ] Update `Report/SIP_Final_Report_IIT_Ropar.md` with corrected hit rates and the true cache sizes (needs write-side data for the LFU dirty-eviction story).
- [ ] Update `Presentation/presentation.tex` to match.
- [ ] Commit the reviewable surface (submodule FTL/config + standalone scripts/tutorials) when ready — not done automatically.

## Notes

**Every result before 2026-08-06 is stale, for two independent reasons.**

1. Warm-up contamination. Prefill ran through the CMT and its compulsory misses were never cleared. On `randread_io4G_cmt2MB_d32` the reported rate was 7.84%; removing the 1,179,648 prefill misses gives 174,753 / 1,048,576 = 16.67%, which is exactly `capacity / totalLogicalPages`, the textbook LRU hit rate for uniform random access. Roughly a 2x understatement.
2. Cache size mislabelling. Capacity was `bytes / 8`, but an entry holds 8 sub-page mappings, so it was really `bytes / 64`. Every point on the size axis was 8x larger than its label.

The two errors push in opposite directions, so old numbers cannot be rescued by scaling. That is why the Jul BIL-spam sweeps were deleted rather than kept for comparison.

**Why the LRU/LFU gap is small.** Under uniform random access there is no frequency skew for LFU to exploit, and after a sequential fill every entry has frequency 1, which makes LFU's eviction order identical to LRU's. The measured ~0.06% hit-rate difference is the expected theoretical result, not a bug. A workload with genuine hot/cold skew would be needed to separate the policies on hit rate.

**Fidelity limits, documented rather than fixed.** The GMT is always resident in RAM, so a CMT miss is a hash lookup plus a synthetic `tick` penalty with no PAL I/O. There are no translation pages either: one CMT entry is one LPN, so a miss cannot amortise across the ~512 mappings a real 4 KB translation page would carry. Both understate hit rate for sequential workloads and should be stated as limitations in the report.

**On-demand GC does not slow the write that triggers it** (found 2026-08-11 while writing `tutorial/architecture/`). `writeInternal` copies the clock into a local at `page_mapping.cc:1283` (`uint64_t beginAt = tick`), runs `selectVictimBlock` and `doGarbageCollection` against that local, and never assigns it back. The relocation and erase cost therefore reaches results only indirectly, through PAL channel/die busy time slowing the *next* request, and through `gcCount` / `reclaimedBlocks` / `validPageCopies`. A GC-triggering write shows no latency spike. Worth stating alongside the CMT limits above; it also means write-latency tails cannot be used as a GC signal in this simulator.

**`EraseThreshold` is block retirement, and it is effectively off by default.** At `page_mapping.cc:1377`, `eraseInternal` returns an erased block to `freeBlocks` only while `eraseCount < EraseThreshold`; at or above it the block is dropped from both containers permanently. The default is 100 000 erases against realistic MLC endurance of ~3 000, so no block ever retires in a normal run, and no statistic counts retirements. Lower the key deliberately if end-of-life behaviour is ever in scope.

**`activate_lfu.py` is gone deliberately.** It patched source files by string replacement and had already been applied halfway, which is what caused the silent breakage. The `CMTPolicy` config key replaces it.

**Sweep stopped early at 21:21 on 2026-08-06, on purpose.** It ran 2h28m and completed 76 of 180 jobs. `outputs/sweep_2h_20260806_185300/` therefore holds a **partial** grid — do not treat it as a finished sweep:

| Block | Status |
| --- | --- |
| `randread` LRU | 30/30 complete |
| `randread` LFU | 30/30 complete |
| `randwrite` LRU | 16/30 |
| `randwrite` LFU | 0/30 |
| `randrw` LRU / LFU | 0/30 each |

The `randread` block is whole, so the read-side LRU-vs-LFU comparison is complete and usable on its own. The write and mixed workloads are not.

**Ten files had to be deleted after the kill.** Each job runs in a subshell that appends stats and writes a `Finished :` line *after* the simulator returns. Killing the simulators did not kill those subshells, so in-flight jobs wrote a normal-looking header and `Finished` footer around an empty `=== SUBSYSTEM STATS ===` section. They were identified by having a `Finished` line but no `cmt.hit_rate`, and removed.

**Results validated against theory.** Every `randread` point matches `capacity / totalLogicalPages` to three significant figures — 0.518% at 512 KB against a predicted 0.521%, and 16.69% at 16 MB against 16.67%. Hits plus misses equals the request count exactly, confirming no warm-up leakage.

**The real LFU finding is in write-backs, not hit rate.** Hit rate is a tie under uniform random. LFU cuts dirty evictions substantially, and monotonically in cache size: 0.4% at 512 KB … 12.1% at 16 MB. Mechanism: under LFU any warm-up dirty entry that receives one read hit is promoted to frequency 2 and becomes eviction-immune while victims come from the frequency-1 bucket. Caveat: in pure `randread` the dirty set is static from warm-up; `randrw` (not yet run) is where the effect matters most.

**Output layout (2026-08-06).** New runs assemble as: header → `=== SUBSYSTEM STATS ===` (from `LogFile`) → `=== RUN SUMMARY ===` (stdout) → `Finished`. Old files in the kept sweep still have the previous order (summary then stats); data is valid, only section order differs.

**Unmapped-read miss accounting.** `accessCMT(..., allocate=false)` still increments `cmtMisses` before returning nullptr for never-written LPNs. Fine for full-drive random reads; sparse workloads will understate hit rate. Left as a known stats quirk, not a functional bug.

**Build artifacts left in place** (`simplessd-standalone`, `lib*.a`, `CMake*`) so a reviewer can run without a full rebuild. They are gitignored.
