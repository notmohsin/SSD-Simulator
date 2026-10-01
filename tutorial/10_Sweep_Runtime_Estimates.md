# Sweep Runtime Estimates (Post GC-Fix)

How to predict **real wall-clock and CPU time** for `SimpleSSD-Standalone/run.sh` sweeps. Constants below were calibrated on the post-fix binary (`getLiveMapping` GC path, `nth_element` victim selection, `-O3 -march=native`) in September 2026.

See also: [09_Simulation_Runtime_And_GC_Bottlenecks.md](09_Simulation_Runtime_And_GC_Bottlenecks.md) for why the pre-fix simulator was slow.

---

## 1. Job count

`run.sh` builds jobs from nested loops (Section 2). For the **default sweep**:

| Parameter | Default values | Count |
| --- | --- | --- |
| `SWEEP_IO_SIZES` | `4G` | 1 |
| `SWEEP_FILL_RATIOS` | `0.8` | 1 |
| `SWEEP_WORKLOADS` | `randread`, `randwrite`, `randrw` | 3 |
| `SWEEP_CMT_BYTES` | 16 MiB, 32 MiB | 2 |
| `SWEEP_CMT_POLICIES` | LRU (0), LFU (1) | 2 |
| `SWEEP_WINDOW_FILL` | `false`, `true` | 2 |
| `SWEEP_BLOCK_SIZES` | `4K` | 1 |

\[
N_{\text{jobs}} = 1 \times 1 \times 3 \times 2 \times 2 \times 2 = 24
\]

Each job at `IO_SIZE=4G`, `blocksize=4K` issues:

\[
N_{io} = \frac{4\,\text{GiB}}{4\,\text{KiB}} = 1{,}048{,}576 \text{ requests}
\]

**Always verify completion** in the output log: `I/O (bytes)` in the run summary must equal the requested `io_size`. Partial runs invalidate timing data.

---

## 2. Calibrated per-job times (seconds)

Measured on post-fix builds with `fill=0.8`, `CMTCapacityBytes=16777216` (16 MiB), `EvictPolicy=0`, `iodepth=32`:

| Workload | Window fill | Wall time (4G) | Source log |
| --- | --- | ---: | --- |
| `randread` | OFF | **340** | `outputs/randread_LRU_WF_OFF_16MiB_4K_4G_fill0.8_evict0.txt` |
| `randwrite` | OFF | **155** | `outputs/randwrite_LRU_WF_OFF_16MiB_4K_4G_fill0.8_evict0.txt` |
| `randrw` (50% read) | OFF | **325** | `outputs/randrw_mix0.5_LRU_WF_OFF_16MiB_4K_4G_fill0.8_evict0.txt` |
| `randread` | OFF | **135** (512M) | `outputs/randread_LRU_WF_OFF_16MiB_4K_512M_fill1.0_evict0.txt` |
| `randread` | ON | **110** (512M) | `outputs/randread_LRU_WF_ON_W512_16MiB_4K_512M_fill1.0_evict0.txt` |

At `fill=0.8`, measured `randwrite` 4G had **`gc.count = 0`** (no garbage collection during the workload).

### Invalid reference data (do not use)

Some September 2026 sweep logs labeled `4G` only transferred **~250 MiB** (~61k requests) but still ran ~90 s. Those timings **cannot** be scaled to 4G. Example: `outputs/sweep_Sep07_11-49PM/randread_*_4G_*.txt` with `I/O (bytes): 250470400`.

---

## 3. Affine IO scaling

Host time is **sublinear** in `IO_SIZE` because of fixed warm-up / setup cost. Fit two points for `randread` WF_OFF:

\[
T_{\text{read,OFF}}(B_{\text{GiB}}) = a + b \cdot B_{\text{GiB}}, \quad a = 105.9\,\text{s},\; b = 58.5\,\text{s/GiB}
\]

Check: \(105.9 + 58.5 \times 4 = 339.9\,\text{s} \approx 340\,\text{s}\).

For WF_ON, reuse slope \(b\) and calibrate intercept from the 512M measurement:

\[
T_{\text{read,ON}}(B_{\text{GiB}}) = 80.5 + 58.5 \cdot B_{\text{GiB}}
\Rightarrow T_{\text{read,ON}}(4\,\text{G}) \approx 314\,\text{s}
\]

Write (two-point fit from 64M and 4G):

\[
T_{\text{write}}(B_{\text{GiB}}) = 14.8 + 35.1 \cdot B_{\text{GiB}}
\Rightarrow T_{\text{write}}(4\,\text{G}) \approx 155\,\text{s}
\]

`randrw` with WF_ON (read half penalized):

\[
T_{\text{randrw,ON}} = T_{\text{randrw,OFF}} \left(1 + 0.5\left(\frac{T_{\text{read,ON}}}{T_{\text{read,OFF}}} - 1\right)\right) \approx 312\,\text{s at 4G}
\]

Minor unmeasured adjustments used in full sweep sums: 32 MiB CMT \(\times 0.92\), LFU \(\times 1.05\).

### IO size quick table (`randread` WF_OFF)

| `IO_SIZE` | Estimated time |
| --- | ---: |
| 1G | ~2.7 min |
| 4G | ~5.7 min |
| 16G | ~17 min |
| 64G | ~64 min |

---

## 4. Total CPU time

\[
T_{\text{CPU}} = \sum_{i=1}^{N_{\text{jobs}}} T_i \approx 6{,}300\,\text{core-seconds} \approx 1.75\,\text{CPU-hours}
\]

for the default 24-job sweep at 4G / fill=0.8. Re-sum after changing any sweep dimension.

---

## 5. Wall-clock with parallelism

Jobs are launched in workload order: all `randread` (8), then `randwrite` (8), then `randrw` (8). With `MAX_PARALLEL = P`:

\[
T_{\text{wall}} = \sum_{wl \in \{\text{read},\text{write},\text{randrw}\}} \sum_{w=1}^{\lceil 8/P \rceil} \max_{j \in \text{wave } w} T_j
\]

### Default sweep (`P = 4`)

| Workload group | Dominant job time | Waves (8÷4) | Group wall |
| --- | ---: | ---: | ---: |
| `randread` | ~340 s | 2 | ~680 s |
| `randwrite` | ~155 s | 2 | ~310 s |
| `randrw` | ~325 s | 2 | ~650 s |

\[
T_{\text{wall}} \approx 680 + 310 + 650 = 1{,}640\,\text{s} \approx \mathbf{27\,\text{minutes}}
\]

| `MAX_PARALLEL` | Approx. wall-clock |
| --- | ---: |
| 1 | ~105 min |
| **4** (default) | **~27 min** |
| 8 | ~14 min |
| 16 | ~14 min (no gain past 8 jobs per workload group) |

---

## 6. `fill=1.0` and `TEST_MODE`

Default sweep uses **`fill=0.8`**. At `fill=1.0`:

- Free blocks sit near `GCThreshold`; GC runs continuously on writes.
- Post-fix cost is **PAL relocation** (simulated NAND I/O), not CMT thrashing.
- Order-of-magnitude: `randwrite` 4G may be **~2–3×** the fill=0.8 time, not hours.

`TEST_MODE=true` uses `fill=1.0` and includes WF_ON `randread` — intentionally slow for regression checks. Use targeted single runs for quick validation:

```bash
WORKLOAD=randwrite IO_SIZE=4G FILL_RATIO=0.8 WINDOW_FILL=false bash run.sh
```

---

## 7. Recalibrating after code or hardware changes

1. Rebuild: `cmake --build SimpleSSD-Standalone --target simplessd-standalone`
2. Run three anchor jobs (WF_OFF, 16 MiB LRU, fill=0.8, 4G): `randread`, `randwrite`, `randrw`
3. Confirm `I/O (bytes)` equals requested size in each log
4. Refit \(a, b\) for read/write affine models; update the table in Section 2
5. Recompute Section 4–5 sums

**Machine note:** `-march=native` binaries are not portable across CPU generations; recalibrate when moving to a new server.

---

## 8. RAM usage

`run.sh` **does not** report peak memory. Earlier VmRSS polling from `/proc/<pid>/status` produced meaningless values (~2 MiB) and has been removed. For capacity planning on the server, use `/usr/bin/time -v` or `ps` on a representative job manually if needed.
