# Original User Request

## 2026-10-07T17:41:58Z

Diagnose and fix a severe performance regression in a SimpleSSD fork's FTL (Flash Translation Layer). A full trace replay of 2,030,915 requests ran for 3 days and stalled. The suspected root cause is `CMTWindowFill = true` in the CMT (Cached Mapping Table) subsystem, which was enabled during the stalling run. The goal is to: (1) confirm the root cause with a baseline-vs-regression comparison, (2) fix the bottleneck, and (3) verify the full trace completes in reasonable time.

Working directory: /home/mohsin/Projects/SimpleSSD
Integrity mode: development

---

## Background

The repository is a SimpleSSD fork with a custom CMT (Cached Mapping Table) layer added on top of the FTL page mapping. The key file is `simplessd/ftl/page_mapping.cc`. Custom additions include:

- **LRU and LFU replacement policies** (`CMTPolicy = 0 or 1`)
- **CMT window fill** (`CMTWindowFill`): on a CMT miss, scans up to `CMTWindowSize` (512) neighboring LPNs and bulk-inserts their mappings into the CMT
- **CMT statistics** tracking (hits, misses, GC hits, fill insertions, fill evictions, etc.)
- **Fill origin tracking** (`fillOrigin`, `fillUnused` fields on every CMT entry)

The stalling run had `CMTWindowFill = true`. The current config (`config/ssd_trace_replay.cfg`) has `CMTWindowFill = false`. The trace is `Traces/stg_0.txt`.

The trace replay commands are documented in `TRACE_REPLAY_COMMANDS.md`.

---

## Requirements

### R1. Establish a clean baseline

Run the full trace (`Traces/stg_0.txt`, 2,030,915 requests) with **all custom CMT features disabled**:
- `CMTWindowFill = false`
- `CMTMissLatency = 0` (removes synthetic tick inflation)
- `CMTWriteBackLatency = 0`
- `CMTPolicy = 0` (LRU, simpler path)
- `CMTCapacityBytes = 2097152` (2 MiB)

Record wall-clock time and the final stats from `sim_stats.log`.

### R2. Identify the root cause of the regression

Re-run the trace with `CMTWindowFill = true` (and the same CMT size/policy as R1). Measure wall-clock time. If it does not complete within 30 minutes, stop it and profile (e.g. with `perf top` or `gprof`) to identify the hot path. Provide a written explanation of why the window-fill code is slow on this workload.

**Suspected bottleneck (for the team to validate or disprove):** `collectFillCandidates()` scans up to 512 neighboring LPNs via `table.find()` on every CMT miss. With a 2 MiB CMT against a 10 GiB trace address space, the CMT miss rate is near 100%, so this is ~512 × 2M = ~1 billion hash lookups just for fill scanning, plus eviction loops per miss.

### R3. Fix or bypass the bottleneck

After confirming the root cause, implement the minimal fix. Options, in order of preference:

1. **Config bypass (preferred if the window fill is algorithmically correct but just needs to be off for large traces):** Ensure `CMTWindowFill = false` is robustly respected with zero overhead when disabled — no scanning, no eviction, no stat updates.
2. **Algorithmic fix (if the window fill itself is worth keeping):** Limit `collectFillCandidates()` to a budget proportional to available CMT slack (not a fixed 512-scan on every miss). Do not scan at all when `cmtSize ≈ cmtCapacity`. 
3. **Full removal:** If window fill is not needed for the study (it was an experimental extension, not in the original SimpleSSD), remove it entirely from `page_mapping.cc` and `page_mapping.hh`.

Do **not** change the core LRU/LFU policy logic or the CMT statistics tracking — those are required for the study.

### R4. Full trace verification

After the fix, run the full trace to completion (all 2,030,915 requests) with `CMTWindowFill = false` (and optionally with `= true` if fixed). Confirm that:
- The run completes without `panic()` or `warn()` calls in the output
- `sim_stats.log` contains valid `ftl.page_mapping.cmt.*` statistics
- Wall-clock time is under 60 minutes for the full trace

---

## Acceptance Criteria

### Correctness
- [ ] Baseline run (R1) completes all 2,030,915 requests without crash or panic
- [ ] `sim_stats.log` contains non-zero `cmt.hit_rate`, `cmt.hits`, `cmt.misses`
- [ ] R4 run completes all 2,030,915 requests without crash or panic

### Performance
- [ ] Full trace with `CMTWindowFill = false` completes in under 60 minutes wall-clock time
- [ ] If window fill is fixed and re-enabled, full trace still completes in under 120 minutes

### Diagnosis
- [ ] R2 provides a written root-cause analysis explaining *why* the window fill caused the slowdown, with evidence (profiling data, request count math, or timing comparison)

### No regressions
- [ ] LRU and LFU policies (`CMTPolicy = 0` and `1`) still both run to completion on the smoke test (`IOLimit = 1000`)
- [ ] `make -j$(nproc)` in `/home/mohsin/Projects/SimpleSSD/build` exits 0 after all changes

---

## Verification Resources

The smoke test command (1000 requests, fast check):
```bash
rm -rf out_trace_smoke && mkdir -p out_trace_smoke
./build/simplessd-standalone config/trace_stg_0_smoke.cfg config/ssd_trace_replay.cfg out_trace_smoke
cat out_trace_smoke/sim_stats.log
```

The full trace run command (see `TRACE_REPLAY_COMMANDS.md` §5 for the full version):
```bash
rm -rf out_trace_64g && mkdir -p out_trace_64g
sed 's/^TimingMode = .*/TimingMode = 0/' config/trace_stg_0.cfg > /tmp/trace.cfg
./build/simplessd-standalone /tmp/trace.cfg config/ssd_trace_replay.cfg out_trace_64g
cat out_trace_64g/sim_stats.log
```

Build command: `cmake --build build --target simplessd-standalone -j$(nproc)`

---

Expecting this to run as a full project with a diagnosis + fix + verification team. Say so if you want it broken into a smaller focused run.
