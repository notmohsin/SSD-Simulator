# /reviewSSD — Full Branch Handoff Prompt

**Purpose:** Copy-paste this entire file (or `@agents/review-ssd-handoff-2026-09-09.md`) to a fresh agent session and invoke `/reviewSSD`. The agent should load `agents/review-ssd.md`, `agents/review-ssd-reference.md`, and `agents/review-ssd-memory.md`, then execute everything below.

**Author context:** Post-GC/CMT performance fixes on `my-modifications`. Prior review (2026-09-09) found GC CMT pollution (`accessCMT` during GC) — fixed with `getLiveMapping()`. User wants zero-trust re-validation: CMT + window-fill implemented correctly, no bugs, stats honest. No thesis claims yet.

---

## Mission

You are reviewing the SimpleSSD fork on branch `my-modifications` to confirm:

1. **CMT implementation** (LRU/LFU, dirty write-back, capacity accounting) is correct.
2. **Window-fill** (translation-page read granularity on demand miss) is correct.
3. **Reported stats** match the code paths taken — nothing silently broken.

**Complement Bugbot** with modeling-fidelity review per `agents/review-ssd.md`. **Do not apply fixes** unless the user asks separately in a follow-up message.

**Fidelity bar:** Publication-ready — flag only **Incorrect** or **Misleading** issues that would invalidate behavior or stats. Document **Acceptable simplifications** clearly. Do not nitpick style.

**Deliverables:**

1. Full structured report per template in `agents/review-ssd.md`.
2. Overwrite `agents/review-ssd-memory.md` (keep ≤80 lines).
3. Reference the sweep output directory and 3–5 representative job labels you validated.

**Do not:** apply code fixes, update `PROGRESS.md`, or dismiss sweep anomalies as "host noise" without checking simulated stats first.

---

## Repository layout

| Item | Path |
|------|------|
| Project root | `/home/mohsin/Mohsin/Second Year/SIP 2026` |
| Simulator wrapper | `SimpleSSD-Standalone/` |
| FTL submodule | `SimpleSSD-Standalone/simplessd/` |
| Agent spec | `agents/review-ssd.md` |
| Rubric / papers | `agents/review-ssd-reference.md` |
| Prior review state | `agents/review-ssd-memory.md` |
| Sweep runner | `SimpleSSD-Standalone/run.sh` |
| Output analyzer | `SimpleSSD-Standalone/analyze_outputs.py` |

---

## Scope

| Item | Value |
|------|-------|
| Branch | `my-modifications` |
| Base branch | `origin/2.0` |
| Diff scope | **Full branch** — all committed, staged, and unstaged changes in standalone + submodule |

### Step 1: Compute diff scope

Run from `SimpleSSD-Standalone/`:

```bash
cd "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone"
git branch --show-current
git merge-base HEAD origin/2.0
git diff $(git merge-base HEAD origin/2.0)...HEAD
git diff
git diff --cached
```

Run from submodule:

```bash
cd "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone/simplessd"
git log --oneline origin/2.0..HEAD
git status --short
git diff
```

If diff is empty, say so in one sentence and still run the architectural invariant check.

### Submodule commits in scope (all since `origin/2.0`)

Non-exhaustive list — review **all** commits on the branch:

| Commit (approx.) | Summary |
|------------------|---------|
| `9fcadf1` | CMT implementation with LRU + config parameters |
| `1b668cc` / `50d0c1b` | Spatial prefetch → window-fill precursor |
| `5f9bc82` | Window-fill rename + accounting bug fixes |
| `3810825` | `fill_accuracy` calculation fix |
| `24d7c19` | FTL over-provisioning / GC threshold tuning |
| `e316a6d` | FillRatio update; GC victim `nth_element`; **`getLiveMapping` GC path** |
| `976fe9b` | CMT config nomenclature standardization (`CMTWindowFill`, `WF_ON`/`WF_OFF`) |

Wrapper changes (`run.sh`, `CMakeLists.txt`, tutorials) are also in scope when they touch CMT/GC knobs or reported metrics.

---

## Step 2: Load agent spec and memory

Read these files before reviewing code:

1. `agents/review-ssd.md` — role, workflow, report template, invariants, rules
2. `agents/review-ssd-reference.md` — papers-first rubric (DFTL ASPLOS '09, LFU Shah et al., WL SIGMETRICS '13)
3. `agents/review-ssd-memory.md` — prior findings (2026-09-09: Sound verdict; GC CMT pollution resolved)

Follow `agents/review-ssd.md` workflow exactly. Track the checklist:

```
Review progress:
- [ ] Step 1: Read agents/review-ssd-memory.md
- [ ] Step 2: Read agents/review-ssd-reference.md
- [ ] Step 3: Determine diff scope (branch vs origin/2.0)
- [ ] Step 4: Read changed files in FTL scope
- [ ] Step 5: Re-check prior open items — fixed, still open, or regressed?
- [ ] Step 6: Audit changed behavior against full rubric
- [ ] Step 7: Audit core architectural invariants
- [ ] Step 8: Run local sweep (SWEEP_MODE=true) and validate stats
- [ ] Step 9: Produce structured report
- [ ] Step 10: Update agents/review-ssd-memory.md
- [ ] Step 11: Do NOT apply fixes
```

---

## Step 3: Build prerequisite

Confirm release build before running sweeps. Debug builds (`DEBUG_BUILD=ON`, `-O0`) inflate wall time and are **not** fidelity bugs.

```bash
cd "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone"
grep DEBUG_BUILD CMakeCache.txt
grep CXX_FLAGS simplessd/CMakeFiles/simplessd.dir/flags.make
grep CXX_FLAGS CMakeFiles/simplessd-standalone.dir/flags.make
```

**Expected:**

| Target | Expected `CXX_FLAGS` |
|--------|----------------------|
| `simplessd` (FTL library) | `-O2 -g` (no `-O0`) |
| `simplessd-standalone` | `-O3 -march=native` (no `-O0`) |
| `CMakeCache.txt` | `DEBUG_BUILD:BOOL=OFF` |

If wrong, reconfigure and rebuild:

```bash
cmake -DDEBUG_BUILD=OFF .
cmake --build . --target simplessd-standalone
rm -f .run-build-initialized
```

---

## Step 4: Required — run local sweep for evidence

**You must run** a local sweep. Do not rely on code review alone.

### Default sweep (24 jobs)

```bash
cd "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone"
SWEEP_MODE=true bash run.sh
```

**Default parameter grid** (from `run.sh` SECTION 2):

| Parameter | Values | Count |
|-----------|--------|-------|
| `SWEEP_IO_SIZES` | `4G` | 1 |
| `SWEEP_FILL_RATIOS` | `0.8` | 1 |
| `SWEEP_WORKLOADS` | `randread`, `randwrite`, `randrw` | 3 |
| `SWEEP_CMT_BYTES` | 16 MiB, 32 MiB | 2 |
| `SWEEP_CMT_POLICIES` | 0 (LRU), 1 (LFU) | 2 |
| `SWEEP_WINDOW_FILL` | `false`, `true` | 2 |
| `SWEEP_WINDOW_SIZES` | 512 | 1 |
| `SWEEP_BLOCK_SIZES` | `4K` | 1 |

**Total jobs:** 1 × 1 × 3 × 2 × 2 × 2 × 1 × 1 = **24**

**Output directory:** `outputs/sweep_<MonDD_HH-MMAM|PM>/`

**Per-job artifacts:**

- `outputs/sweep_*/<label>.txt` — full subsystem stats + run summary
- `outputs/sweep_*/sweep_summary.txt` — tabular summary with `CMT Hit%`, `Fill Acc%`, wall time, status

**Parallelism:** default `MAX_PARALLEL=4`. Use `MAX_PARALLEL=1` if debugging job failures.

### Optional GC-active sweep (if time permits)

Validates GC path and `gc.count > 0` — not required for CMT/window-fill focus but useful for invariant check #4:

```bash
SWEEP_MODE=true \
  SWEEP_FILL_RATIOS=(0.95) \
  SWEEP_IO_SIZES=("16G") \
  SWEEP_WORKLOADS=("randwrite") \
  bash run.sh
```

Expect long wall times (80+ min for 16G fill=0.95 on server hardware).

### Post-sweep analysis

```bash
# Summary table
cat outputs/sweep_*/sweep_summary.txt

# Optional Python analysis
python3 analyze_outputs.py outputs/sweep_<timestamp>/
```

Spot-check at least these job categories from the default 24-job sweep:

| Category | Why |
|----------|-----|
| `randwrite` + `WF_OFF` + LRU + 16MiB | Baseline CMT without window-fill churn |
| `randwrite` + `WF_ON` + LRU + 16MiB | High eviction / fill_insertions on random writes |
| `randread` + `WF_ON` vs `WF_OFF` | Window-fill overhead contrast |
| `randread` + LRU vs LFU | Policy divergence |
| 16 MiB vs 32 MiB same workload | Capacity scaling of hit rate |

### Pre-existing local log (reference)

If present, compare against your sweep results:

**File:** `outputs/randwrite_LRU_WF_ON_W512_16MiB_4K_4G_fill0.8_evict0.txt` (release build)

| Stat | Expected value | Notes |
|------|----------------|-------|
| `write.bytes` | 4,294,967,296 | 4 GiB |
| `write.request_count` | 1,048,576 | 4G / 4K |
| `ftl.page_mapping.gc.count` | 0 | No GC at fill=0.8 |
| `ftl.page_mapping.cmt.evictions` | ~329,000,000 | WF_ON on random writes |
| `ftl.page_mapping.cmt.fill_insertions` | ~328,000,000 | Window-fill churn |
| `ftl.page_mapping.cmt.fill_accuracy_percent` | ~0% | Expected on rand* |
| Wall time | ~1–2 min | Release build; host-dependent |

---

## Step 5: Primary focus areas (user priorities)

The user explicitly wants deep review of these three areas. Everything else is secondary unless the diff touches it.

### Focus A — Stats honesty

Verify every counter and derived metric matches the code path taken.

**CMT core stats** (`ftl.page_mapping.cmt.*`):

| Stat key | What to verify |
|----------|----------------|
| `cmt.hits` / `cmt.misses` / `cmt.hit_rate` | Warm-up excluded via `resetCMTStats()` after `initialize()` |
| `cmt.evictions` | Increments on every eviction; excludes warm-up |
| `cmt.dirty_evictions` / `cmt.writebacks` | Dirty entries write back to GMT before eviction; latency charged |
| `cmt.gc_hits` / `cmt.gc_misses` | GC path uses `getLiveMapping()` — should **not** allocate/evict via `accessCMT(allocate=true)` |
| `cmt.capacity` / `cmt.entry_bytes` / `cmt.capacity_bytes` | `capacity_bytes = capacity × entry_bytes`; matches config `CMT_BYTES` |
| `cmt.occupancy` | End-of-sim entries used ≤ capacity |

**Window-fill stats** (`ftl.page_mapping.cmt.fill_*`):

| Stat key | What to verify |
|----------|----------------|
| `fill_insertions` | One demand miss can insert up to `CMTWindowSize` (512) entries |
| `fill_hits` | Window-filled entry used at least once before eviction |
| `fill_evicted_unused` | Window-filled entry evicted without ever being hit |
| `fill_triggers` | Count of demand misses that initiated a fill window |
| `fill_accuracy_percent` | Formula correct after commit `3810825` |
| `fill_waste_rate_percent` | Complement / consistent with accuracy |
| `fill_coverage_percent` | Definition matches code comments |
| `fill_avg_batch_size` | Average valid LPNs per fill window ≤ window size |

**I/O integrity:**

| Check | Expected |
|-------|----------|
| `write.request_count` × block size ≈ `write.bytes` | For write workloads |
| `read.request_count` × block size ≈ `read.bytes` | For read workloads |
| `pal.program.count` / `pal.read.count` | Consistent with workload (no skipped PAL ops) |
| `run.sh` `sweep_summary.txt` `CMT Hit%` | Matches `cmt.hit_rate` in per-job log |
| `run.sh` `sweep_summary.txt` `Fill Acc%` | Matches `fill_accuracy_percent` in per-job log |

**Red flags (potential Incorrect):**

- Hit rate > 100% or negative
- `fill_insertions` > `fill_triggers × window_size` without explanation
- `dirty_evictions` > `evictions`
- `gc_hits + gc_misses` growing on GC-heavy runs while CMT evictions spike from GC path (CMT pollution regression)
- `write.bytes` ≠ expected IO size for completed jobs

### Focus B — Window-fill model

Window-fill models DFTL translation-page read granularity: one NAND read of a mapping page returns many adjacent LPN mappings.

**Code locations** (read these):

- `simplessd/ftl/page_mapping.{cc,hh}` — miss handler, fill window installation
- `simplessd/config/sample.cfg` — `CMTWindowFill`, `CMTWindowSize`
- `tutorial/11_CMT_Window_Fill_Nomenclature.md` — canonical naming

**Questions to answer in the report:**

1. On CMT miss with `CMTWindowFill=true`, does the code install a contiguous window of LPNs (default 512)?
2. Is **one** synthetic miss latency (`CMTMissLatency`) charged per window, not per LPN in the window?
3. Are already-resident LPNs in the window skipped (no duplicate insertion)?
4. Does window-fill interact correctly with LRU/LFU (filled entries participate in normal eviction)?
5. Is `fill_accuracy ≈ 0%` on `randread`/`randwrite`/`randrw` **expected** (no spatial locality) — not a bug?
6. For **sequential read** (`read` workload or `TEST_MODE`), does fill accuracy rise? (Optional spot check — not in default 24-job sweep.)

**Verdict guidance:**

- Charging N× miss latency for N LPNs in window → **Incorrect**
- Installing window but not counting fill stats → **Misleading**
- ~0% accuracy on random workloads with correct formulas → **Correct** (document why)

### Focus C — CMT policies (LRU / LFU)

**LRU (policy 0):**

- Hit promotes entry to MRU position
- Eviction selects LRU entry when cache full
- Recency updated on every `accessCMT` hit

**LFU (policy 1):**

- Shah et al. O(1) bucket structure (referenced in `page_mapping.cc`)
- Hit increments frequency; eviction picks least frequent
- **Known limitation:** no frequency aging → cache poisoning possible on shifting workloads
- Verdict: **Acceptable simplification** if documented; **Incorrect** only if bucket logic is broken

**Shared behavior:**

| Path | Expected |
|------|----------|
| Write miss | `accessCMT(lpn, allocate=true)` — may evict |
| Read miss (unmapped) | `accessCMT(lpn, allocate=false)` — no allocation |
| Dirty entry eviction | Copy to GMT `table` + `tick += CMTWriteBackLatency` |
| GC relocation | `getLiveMapping()` — update mapping if CMT-resident; no allocate |
| `flushCMT()` at sim end | Writes dirty entries; **does not** charge write-back latency (pre-existing) |

**Compare LRU vs LFU in sweep:** under identical `randread` 4G fill=0.8, hit rates and eviction counts should **differ**, not be identical.

---

## Step 6: Core architectural invariants (mandatory)

On every review, mark each invariant **Sound**, **At risk**, or **Broken** in the report table.

| # | Invariant | What to check |
|---|-----------|---------------|
| 1 | **Out-of-place write** | NAND pages not overwritten; writes go to free pages; old copies invalidated |
| 2 | **Mapping coherence** | `getLiveMapping()` / CMT+GMT consistent across read, write, trim, format, GC, destroy |
| 3 | **CMT is cache, GMT authoritative** | `table` (GMT) is source of truth; dirty evictions write back; miss path charges cost |
| 4 | **GC before erase** | Valid pages relocated before block erase; victim policy respected |
| 5 | **Stats honesty** | Warm-up excluded; capacity bytes correct; counters match code path |
| 6 | **Simplification honesty** | Comments claiming DFTL-faithful behavior match known baseline gaps |

### Prior review open items — re-check status

From `agents/review-ssd-memory.md` (2026-09-09):

| # | Item | Prior verdict | Re-check |
|---|------|---------------|----------|
| 1 | Document window-fill as approximation | Open | Still needed? Code vs comments? |
| 2 | PF Acc 0% on rand* is expected | Open (context) | Confirm with sweep evidence |
| 3 | Peak RAM column unreliable | Open | `run.sh` no longer reports it? |
| 4 | GC latency not on triggering write | Open (pre-existing) | Still true? Flag as simplification |

### Resolved items — confirm not regressed

| Item | Fix | Regression check |
|------|-----|------------------|
| GC CMT pollution | `getLiveMapping()` at ~line 772 in `page_mapping.cc` | `gc_hits`/`gc_misses` sane; no eviction storm from GC on fill=0.95 run |
| O(N log N) victim sort | `std::nth_element` at ~line 705 | GC victim semantics unchanged (same greedy policy result) |
| FillRatio default | `sample.cfg` = 0.8 | Sweeps use intended fill level |
| Release build flags | `-O3 -march=native` standalone, `-O2` simplessd | Verified in Step 3 |

---

## Step 7: Files to read

### Must read (if in diff or directly relevant)

```
SimpleSSD-Standalone/simplessd/ftl/page_mapping.cc
SimpleSSD-Standalone/simplessd/ftl/page_mapping.hh
SimpleSSD-Standalone/simplessd/ftl/config.cc
SimpleSSD-Standalone/simplessd/ftl/config.hh
SimpleSSD-Standalone/simplessd/ftl/common/block.cc
SimpleSSD-Standalone/simplessd/ftl/common/block.hh
SimpleSSD-Standalone/simplessd/config/sample.cfg
SimpleSSD-Standalone/simplessd/config/gc_test.cfg
SimpleSSD-Standalone/run.sh
SimpleSSD-Standalone/analyze_outputs.py
SimpleSSD-Standalone/CMakeLists.txt
SimpleSSD-Standalone/simplessd/CMakeLists.txt
```

### Context / tutorials (read as needed)

```
tutorial/06_CMT_Deep_Dive.md
tutorial/07_CMT_Review_And_Fixes.md
tutorial/08_CMT_Mentor_Census.md
tutorial/09_Simulation_Runtime_And_GC_Bottlenecks.md
tutorial/10_Sweep_Runtime_Estimates.md
tutorial/11_CMT_Window_Fill_Nomenclature.md
agents/review-ssd-reference.md
PROGRESS.md
```

### Out of scope unless diff affects FTL contracts

- HIL, ICL, PAL internals
- mcpat power modeling
- General C++ style (defer to Bugbot)

---

## Step 8: Known context — NOT bugs

**Important:** Include these in **Pre-existing limitations** or **Notes**. Do **not** file as **Incorrect** unless you find **new contradicting evidence**.

| Item | Context | How to report |
|------|---------|---------------|
| `fill_accuracy ≈ 0%` on `randread`/`randwrite`/`randrw` | Random access has no spatial locality; window-fill installs entries that are immediately evicted unused | **Correct** behavior; note in report |
| `gc.count = 0` at `fill=0.8`, 4G IO | Spare blocks above `GCThreshold`; default sweep intentionally isolates CMT from GC | **Expected**; not "skipped GC" |
| GC latency not added to triggering write | `writeInternal` uses local `beginAt`; on-demand GC tick not folded into write latency | **Acceptable simplification** (pre-existing) |
| Wall-time variance, same stats | Host CPU load; simulated ticks and subsystem stats identical across runs | **Not a fidelity bug** |
| GMT always in RAM | SimpleSSD keeps full map in `table`; DFTL stores map on NAND | **Documented baseline limitation** |
| LFU no frequency aging | Shah structure without decay; poisoning on shifting workloads | **Acceptable simplification** if documented |
| `flushCMT()` no latency at sim end | Dirty entries flushed without `CMTWriteBackLatency` charge | **Pre-existing**; note if relevant |
| Synthetic `CMTMissLatency` / `CMTWriteBackLatency` | Not full PAL translation-page I/O | **Documented simplification** |
| ICL `EnableReadPrefetch` | Separate subsystem from FTL CMT window-fill | Do not conflate |

---

## Step 9: Evidence validation checklist

After `SWEEP_MODE=true` completes, work through this list. Check each box in your report.

### Sweep integrity

- [ ] `sweep_summary.txt` exists; `Total Jobs` matches completed count
- [ ] All jobs show `COMPLETE` status (or explain any `SKIPPED`/`FAILED`)
- [ ] Output dir path recorded in report

### Per-job invariants (spot-check ≥5 representative jobs)

- [ ] `write.bytes` or `read.bytes` matches `IO_SIZE` for workload type
- [ ] `write.request_count` or `read.request_count` = IO_SIZE / BLOCK_SIZE
- [ ] No `panic` or assert messages in log tail
- [ ] `cmt.capacity_bytes` matches sweep `CMT_BYTES` parameter

### CMT policy contrast

- [ ] Same workload, LRU vs LFU: different `cmt.hit_rate` and/or `cmt.evictions`
- [ ] 16 MiB vs 32 MiB: larger cache → higher hit rate (same workload, WF_OFF)

### Window-fill contrast

- [ ] Same workload, WF_OFF vs WF_ON: WF_ON has higher `cmt.evictions`
- [ ] WF_ON: `fill_insertions` > 0; `fill_triggers` > 0
- [ ] WF_OFF: `fill_insertions` = 0 (or negligible)
- [ ] `fill_accuracy_percent` near 0% on rand* — explicitly noted as expected

### GC path (optional high-fill run)

- [ ] `gc.count` > 0 when fill=0.95 and IO large enough
- [ ] `cmt.gc_hits` + `cmt.gc_misses` reflect GC mapping lookups without CMT pollution storm
- [ ] `gc.page_copies` > 0 when GC runs

### Summary column accuracy

- [ ] `sweep_summary.txt` `CMT Hit%` matches per-log `cmt.hit_rate`
- [ ] `sweep_summary.txt` `Fill Acc%` matches per-log `fill_accuracy_percent`

---

## Step 10: Pass / fail criteria

### PASS — verdict **Sound**

- No **Incorrect** findings in CMT, window-fill, or stats accounting
- All six architectural invariants **Sound** or **At risk** with documented, acceptable reason
- Sweep evidence consistent with code (checklist above satisfied)
- Prior resolved items (GC `getLiveMapping`, `nth_element`) not regressed

### FAIL — any of:

- **Incorrect** mapping update on GC, read, or write path
- Window-fill charges wrong latency (per-LPN instead of per-window) or double-counts
- LRU/LFU victim selection does not match policy semantics
- Stat counters increment on wrong path or disagree with sweep logs
- `accessCMT(allocate=true)` still called from GC relocation path (CMT pollution regression)
- I/O bytes / request count mismatch indicating skipped work

### AT RISK — acceptable if documented

- GMT in RAM vs NAND-resident map
- Synthetic miss/write-back latency vs full PAL translation I/O
- LFU without frequency aging
- GC latency not charged to triggering write
- `flushCMT()` without end-of-sim latency

---

## Step 11: Report template

Produce this structure (from `agents/review-ssd.md`):

```markdown
# SSD Fidelity Review

**Date:** YYYY-MM-DD
**Scope:** branch changes vs `origin/2.0` | **Focus:** CMT + window-fill + stats honesty
**Files reviewed:** ...
**Sweep evidence:** outputs/sweep_<timestamp>/ (N jobs, M complete)

## Executive summary
[2–3 sentences: overall fidelity verdict]

## Prior review follow-up
[From review-ssd-memory.md: fixed / still open / regressed]

## Architectural invariant check
| Invariant | Status | Notes |
| --- | --- | --- |
| Out-of-place write | Sound / At risk / Broken | ... |
| Mapping coherence | ... | ... |
| CMT vs GMT | ... | ... |
| GC before erase | ... | ... |
| Stats honesty | ... | ... |
| Simplification honesty | ... | ... |

## Findings

### Finding 1: <short title>
**Real SSD behavior:** ...
**Your code:** [`file:line` + behavior]
**Verdict:** Correct | Acceptable simplification | Misleading | Incorrect
**Evidence:** ...
**Suggested fix / documentation:** ...

### Finding 2: ...

## Pre-existing limitations touched by this diff
[Known simplifications this change interacts with]

## Known context (not bugs)
[Table or bullets from Step 8 — confirm still valid with sweep evidence]

## Fidelity checklist
- [ ] CMT miss models translation I/O cost appropriately
- [ ] Dirty eviction models translation write-back appropriately
- [ ] Window-fill matches translation-page read semantics
- [ ] LRU/LFU semantics match policy literature
- [ ] GC relocation follows out-of-place NAND rules
- [ ] GC latency accounting is honest (or documented as simplified)
- [ ] Wear leveling / block retirement claims match implementation
- [ ] Experiment configs isolate the variable under study
- [ ] Reported stats cannot mislead (warm-up, capacity, unmapped-read misses)

## Sweep validation summary
| Label | CMT Hit% | Fill Acc% | gc.count | evictions | Status |
| --- | --- | --- | --- | --- | --- |
| ... | ... | ... | ... | ... | OK / anomaly |

## Suggested next steps
1. ...
```

**Verdict severity:**

- **Incorrect** / **Misleading** — must address before claiming correct CMT/window-fill implementation
- **Acceptable simplification** — document; no code change required
- **Correct** — no action

---

## Step 12: Update memory file

After the report, **overwrite** `agents/review-ssd-memory.md` with:

- Date and diff scope
- Executive verdict (one line)
- Open action items (numbered, with file:line when known)
- Resolved items since last review
- Architectural invariant snapshot table
- Items to re-check on next `/reviewSSD`
- Sweep output dir path used for validation

Keep ≤80 lines. Do not append indefinitely.

---

## Quick reference: key code locations

| Concern | File | Approx. line |
|---------|------|--------------|
| `getLiveMapping()` | `page_mapping.cc` | ~207 |
| GC mapping update (no CMT pollution) | `page_mapping.cc` | ~772 |
| Victim selection `nth_element` | `page_mapping.cc` | ~705 |
| `accessCMT()` | `page_mapping.cc` | search |
| Window-fill on miss | `page_mapping.cc` | ~1154–1175 (per prior review) |
| `fill_accuracy` stats | `page_mapping.cc` | search `fill_accuracy` |
| CMT config names | `config.cc` | `CMTWindowFill`, `CMTWindowSize`, `FillRatio` |
| Sweep knobs | `run.sh` | SECTION 2, `SWEEP_MODE` block ~387 |

---

## Background: what was fixed before this review

For context only — verify these fixes are still present and not regressed:

### Problem 1: GC CMT pollution (was **Incorrect**)

During garbage collection, the old code called `accessCMT(lpn, allocate=true, isGC=true)` for every relocated page. That allocated/evicted CMT entries during GC — not DFTL-faithful and caused massive unnecessary eviction churn.

**Fix:** `getLiveMapping()` on GC path; update mapping if CMT-resident; track `cmt.gc_hits` / `cmt.gc_misses` without polluting cache.

### Problem 2: O(N log N) victim selection (perf, semantics preserved)

`std::sort` on victim blocks → `std::nth_element` for same greedy policy result.

### Problem 3: Debug build masking release performance

`DEBUG_BUILD=ON` → `-O0`; simulations ran hours instead of minutes. Not a fidelity bug but invalidated timing comparisons.

---

*End of handoff prompt. Invoke with `/reviewSSD` and attach this file.*
