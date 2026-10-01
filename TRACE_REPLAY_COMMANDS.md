# Trace Replay Commands

Run these commands from the repository root (`/home/mohsin/Projects/SimpleSSD`).
The trace contains 2,030,915 requests, 22.42 GiB of cumulative I/O, and reaches
byte offset 10.82 GiB. The original NAND geometry models about 512 GiB, so it
does much more device initialization than this workload needs.

## 1. Build once

```bash
cmake --build build --target simplessd-standalone -j2
```

The executable is `build/simplessd-standalone`. The simulator always requires
three arguments: a simulation config, a SimpleSSD config, and an output
directory.

## 2. Check the trace scale

```bash
awk 'BEGIN {n=0; bytes=0; max=0} {
  for (i=1; i<=NF; i++) if ($i == "+") {
    off=$(i-1); len=$(i+1); n++; bytes+=len
    if (off+len > max) max=off+len
    break
  }
} END {
  printf "requests=%d\nI/O=%.2f GiB\nend_offset=%.2f GiB\n",
         n, bytes/1073741824, max/1073741824
}' Traces/stg_0.txt
```

## 3. Fast smoke test

This parses and simulates only the first 1,000 requests. It is the cheapest
check after changing either configuration.

```bash
rm -rf out_trace_smoke
mkdir -p out_trace_smoke
./build/simplessd-standalone \
  config/trace_stg_0_smoke.cfg \
  config/ssd_trace_replay.cfg \
  out_trace_smoke
cat out_trace_smoke/sim_stats.log
```

## 4. Create a realistic scaled profile

The profile below uses 64 GiB of raw NAND (`Block = 64`). That leaves enough
room for the trace's 10.82 GiB address range while avoiding a 512 GiB model.
The other capacities use values that are plausible for a small DRAM-backed SSD:

| Component | Value | Reason |
|---|---:|---|
| Raw NAND | 64 GiB | 64 channels/packages geometry equivalent in capacity; large headroom over the trace span |
| CMT | 64 MiB | 1/1000 of raw SSD capacity, a plausible mapping-cache budget |
| ICL cache | 64 MiB | Keeps the modeled controller cache in the same scale |
| DRAM chip | 64 MiB | Conservative controller DRAM budget |
| Fill ratio | 0.0 | Avoids writing the whole device before replay |

```bash
rm -rf /tmp/simplessd-trace-64g
mkdir -p /tmp/simplessd-trace-64g
sed \
  -e 's/^Block = .*/Block = 64/' \
  -e 's/^CMTCapacityBytes = .*/CMTCapacityBytes = 67108864/' \
  -e 's/^CacheSize = .*/CacheSize = 67108864/' \
  -e 's/^ChipSize = .*/ChipSize = 67108864/' \
  -e 's/^FillRatio = .*/FillRatio = 0.0/' \
  config/ssd_trace_replay.cfg > /tmp/simplessd-trace-64g/ssd.cfg
```

`CMTCapacityRatio` must remain `0.0`; otherwise it overrides
`CMTCapacityBytes`. Do not change `PageSize`, `Page`, or `LBASize` for this
trace: the trace fields are byte offsets and byte lengths, not 512-byte LBA
counts.

## 5. Run the full trace with the scaled profile

`TimingMode = 0` is intentional for a throughput-oriented replay. It preserves
request order and queue behavior without reproducing the original capture's
wall-clock idle gaps. Use `TimingMode = 1` only when timing fidelity is the
experiment being measured.

```bash
rm -rf out_trace_64g
mkdir -p out_trace_64g
sed 's/^TimingMode = .*/TimingMode = 0/' \
  config/trace_stg_0.cfg > /tmp/simplessd-trace-64g/trace.cfg
./build/simplessd-standalone \
  /tmp/simplessd-trace-64g/trace.cfg \
  /tmp/simplessd-trace-64g/ssd.cfg \
  out_trace_64g
cat out_trace_64g/sim_stats.log
```

For a bounded performance trial, replace `IOLimit = 0` in the temporary trace
config with `IOLimit = 100000`. Increase this in stages (`100000`, `500000`,
then `0`) and record wall time for each run.

## 6. Important runtime controls

- Keep `FillRatio = 0.0` for trace replay unless steady-state GC is the subject
  of the experiment. An 80% warm-up writes millions of modeled pages first.
- Keep `DebugLogFile` empty. Debug logging can dominate runtime and disk usage.
- Keep `LatencyLogFile` empty for throughput trials; per-request output adds
  substantial I/O for a two-million-request trace.
- Use `QueueDepth = 32` or `64` for a normal NVMe-style workload. Raising it
  does not make the simulator finish sooner by itself.
- Do not use `run.sh` for this trace. `run.sh` launches synthetic workloads
  from `config/sample.cfg`; the commands above use `TraceReplayer` directly.

## 7. Validate trace units

```bash
python3 tests/test_trace_units.py
```

The expected result is `test_trace_units: PASS`. A failure here means the
trace parser or units were changed and the workload may be addressing the
wrong part of the simulated SSD.