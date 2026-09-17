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
