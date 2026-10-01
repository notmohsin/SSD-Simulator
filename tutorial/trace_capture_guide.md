# Capturing Real I/O Traces and Replaying Them in SimpleSSD

This guide explains the complete workflow for capturing real disk I/O from
your machine and replaying it in SimpleSSD. It covers how every part of the
pipeline works, why each step exists, and what the results mean.

---

## Table of Contents

1. [The Big Picture](#1-the-big-picture)
2. [How blktrace Works](#2-how-blktrace-works)
3. [How SimpleSSD Replays a Trace](#3-how-simplessd-replays-a-trace)
4. [What Happens to One I/O Inside SimpleSSD](#4-what-happens-to-one-io-inside-simplessd)
5. [Step-by-Step: Capture a Trace](#5-step-by-step-capture-a-trace)
6. [Step-by-Step: Run the Simulation](#6-step-by-step-run-the-simulation)
7. [Understanding Your Results](#7-understanding-your-results)
8. [Real Example: Idle vs Compile Workload](#8-real-example-idle-vs-compile-workload)
9. [Config Reference for Trace Replay](#9-config-reference-for-trace-replay)
10. [Common Issues and Fixes](#10-common-issues-and-fixes)
11. [File Map](#11-file-map)

---

## 1. The Big Picture

SimpleSSD lets you take I/O that actually happened on your real NVMe drive
and replay it through a fully software-simulated SSD. This means you can
answer questions like:

- "How would this workload perform on an SSD with twice the cache?"
- "What happens to compile latency if I switch from MLC to TLC NAND?"
- "How much does GC hurt my compile workload under heavy write pressure?"

The pipeline looks like this:

```
YOUR LAPTOP                           SIMPLESSD
─────────────────────────────         ────────────────────────────────────

  App (compiler, browser...)
       │  read()/write() syscalls
       ▼
  Linux Kernel I/O Stack
       │
       │ ◄── blktrace hooks here
       │     records every I/O with nanosecond timestamp
       ▼
  nvme0n1 (real hardware)
                                      trace_filtered.txt  (your trace)
                                            │
                                            │  TraceReplayer reads line by line
                                            │  regex extracts: op, offset,
                                            │  length, timestamp
                                            ▼
                                      BIL → HIL/NVMe → ICL → FTL → PAL
                                            │
                                      latency.log  (results)
```

Two separate config files control the simulation:

```
config/sample.cfg                    simplessd/config/sample.cfg
─────────────────────────────        ─────────────────────────────────────
"What test am I running?"            "What SSD am I simulating?"

Mode, Interface, Latencies           CPU, NVMe, ICL, FTL, PAL, DRAM
Trace file path, regex               Cache size, NAND geometry, GC policy
Timing mode, queue depth             Channel count, page timing
```

---

## 2. How blktrace Works

blktrace is a Linux kernel tool that hooks into the block layer — the lowest
software layer before the hardware driver. It captures every I/O event with
nanosecond precision.

Every I/O passes through several stages. blktrace records each one:

```
Application calls write()
       │
       ▼
  Q — Queued:      kernel created the I/O request
       │
       ▼
  G — Got:         kernel allocated a request struct
       │
       ▼
  I — Inserted:    added to the I/O scheduler
       │
       ▼
  D — Dispatched:  ◄── THIS IS WHAT WE WANT
       │            sent to the hardware driver
       ▼
  C — Complete:    hardware finished the I/O
```

We filter for D (Dispatched) events because those represent exactly what the
real SSD hardware received — after all kernel scheduling decisions were made.
These are the events SimpleSSD needs to replay.

### blkparse output format

After converting with blkparse, each dispatched event looks like:

```
259,0    8    19    0.000033002    401    D    WM    299666368    +    32    [dmcrypt_write/2]
│        │    │     │              │      │    │     │                 │     │
│        │    │     │              │      │    │     │                 │     └── process name
│        │    │     │              │      │    │     │                 └──────── length (sectors)
│        │    │     │              │      │    │     └────────────────────────── start LBA
│        │    │     │              │      │    └──────────────────────────────── operation code
│        │    │     │              │      └───────────────────────────────────── event type (D)
│        │    │     │              └──────────────────────────────────────────── process ID
│        │    │     └─────────────────────────────────────────────────────────── timestamp (s.ns)
│        │    └───────────────────────────────────────────────────────────────── sequence number
│        └────────────────────────────────────────────────────────────────────── CPU core
└─────────────────────────────────────────────────────────────────────────────── device (major,minor)
```

### Operation codes

SimpleSSD looks only at the first character of the operation code:

| Code   | First char | SimpleSSD action |
|--------|-----------|-----------------|
| R      | R         | BIO_READ        |
| RM     | R         | BIO_READ        |
| RA     | R         | BIO_READ (read-ahead) |
| W      | W         | BIO_WRITE       |
| WM     | W         | BIO_WRITE       |
| WS     | W         | BIO_WRITE       |
| WSM    | W         | BIO_WRITE       |
| D      | D         | BIO_TRIM        |
| F      | F         | BIO_FLUSH       |

This is handled in `igl/trace/trace_replayer.cc` lines 254-280.

---

## 3. How SimpleSSD Replays a Trace

The TraceReplayer (`igl/trace/trace_replayer.cc`) works as follows:

```cpp
// Pseudocode of the main loop:
while (not end of file) {
    line = read next line from trace file
    
    if (std::regex_match(line, match, regex)) {   // FULL LINE MATCH
        tick      = parse timestamp from match groups
        offset    = parse LBA * LBASize (or byte offset directly)
        length    = parse LBA length * LBASize
        type      = parse operation (first character: R/W/F/D)
        
        submit BIO to BIL at the right simulated tick
    }
    // Lines that don't match are silently skipped
}
```

IMPORTANT: SimpleSSD uses `std::regex_match()` which requires the regex to
match the ENTIRE line, not just a substring. This is different from grep
which does partial matching. This is why the regex must end with `.*` to
consume the trailing process name like `[dmcrypt_write/2]`.

The three timing modes change when I/Os are submitted:

```
TimingMode = 0  (Sync)
  submit I/O #1 → wait for completion → submit I/O #2 → ...
  Timestamps from trace are IGNORED.
  Best for: measuring pure latency of each individual I/O.

TimingMode = 1  (Async)
  submit I/O #1, #2, #3 ... up to QueueDepth simultaneously
  Timestamps from trace are IGNORED.
  Best for: throughput testing, stressing the SSD queue.

TimingMode = 2  (Strict)
  submit I/O #1 at t=0.000033s (from trace)
  submit I/O #2 at t=0.000034s (from trace)
  Timestamps are REPLAYED EXACTLY.
  Best for: most realistic reproduction of real workload.
```

---

## 4. What Happens to One I/O Inside SimpleSSD

Here is the complete journey of one write from our compile trace:

```
Trace line:
259,0  8  19  0.000033002  401  D  WM  299666368 + 32  [dmcrypt_write/2]
= WRITE, LBA 299666368, 32 sectors = 16,384 bytes, at t=33µs

STEP 1: TraceReplayer
  Regex extracts: type=WRITE, offset=299666368×512=153,429,180,416 bytes,
                  length=16,384 bytes
  Creates BIO object and submits to BIL

STEP 2: BIL (Block I/O Layer)
  Adds SubmissionLatency = 5µs (host software overhead)

STEP 3: SIL (Software Interface Layer — NVMe driver simulation)
  Packages BIO into a 64-byte NVMe Write command
  Calculates PCIe DMA transfer time (PCIe 3.0 x4 = ~3.94 GB/s)
  Places command in Submission Queue (SQ)

STEP 4: HIL (NVMe Controller)
  Polls SQ every WorkInterval = 50ns
  Picks up up to MaxRequestCount = 4 commands per poll
  CPU executes command processing: ~2µs at 400 MHz
  Routes to ICL

STEP 5: ICL (Internal Cache Layer — 512 MiB, 8-way LRU)
  WRITE CACHE ENABLED → data written to DRAM cache, marked dirty
  → returns completion quickly (data is safe in DRAM)
  
  Background eviction (when cache fills up):
    dirty cache line selected by LRU policy
    → sent to FTL for actual NAND write

STEP 6: FTL (Flash Translation Layer)
  L2P table lookup: which physical page does this logical page map to?
  Find a free physical page in the write frontier
  
  If free_block_ratio < GCThreshold (5%):
    → GARBAGE COLLECTION TRIGGERED
    → select victim block (Greedy: most invalid pages)
    → read all valid pages from victim → write to new block
    → erase victim block (3.5ms!)
    → now free space available

STEP 7: PAL (Physical Array Layer)
  Schedule NAND program operation across channels/dies
  Channel 0, Package 2, Die 1, Plane 0, Block 347, Page 201
  
  Timing:
    DMA0 (controller → NAND):   ~39µs
    NAND program (LSB page):     500µs
    NAND program (MSB page):    1300µs
    DMA1 (status back):          ~2µs

STEP 8: Completion
  Completion travels back up: PAL → FTL → ICL → HIL → SIL → BIL
  BIL adds CompletionLatency = 5µs
  TraceReplayer records: id, offset, length, total_latency
  Writes one line to latency.log
```

---

## 5. Step-by-Step: Capture a Trace

### Prerequisites

- sudo/root access (blktrace requires kernel privileges)
- blktrace and blkparse installed
- Know your device name: run `lsblk` to find it

On this machine the device is `nvme0n1`.

### Step 1 — Create output directory

```bash
mkdir -p ~/traces/my_workload
cd ~/traces/my_workload
```

### Step 2 — Start capture (Terminal 1)

```bash
# -d = device, -o = output prefix, -w = duration in seconds
sudo blktrace -d /dev/nvme0n1 -o trace -w 60
```

While this is running, do your workload in Terminal 2.
blktrace will stop automatically after 60 seconds.

### Step 3 — Do your workload (Terminal 2)

During the capture window, run whatever you want to measure:

```bash
# Example: compile SimpleSSD
cd "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone"
make clean && make -j$(nproc)

# Example: database-like workload
# sysbench fileio --file-test-mode=rndwr run

# Example: file copy
# cp -r ~/some_large_folder ~/Desktop/copy
```

### Step 4 — Convert binary to text

```bash
cd ~/traces/my_workload
blkparse -i trace -o trace_parsed.txt
```

### Step 5 — Filter dispatched events only

```bash
grep " D " trace_parsed.txt > trace_filtered.txt

# Check the count
wc -l trace_filtered.txt

# Verify the format
head -5 trace_filtered.txt
```

### Step 6 — Copy to SimpleSSD config directory

```bash
cp trace_filtered.txt \
   "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone/config/my_trace.txt"
```

---

## 6. Step-by-Step: Run the Simulation

### Step 1 — Create output directory

```bash
mkdir -p ~/traces/my_workload/sim_output
```

### Step 2 — Edit config/sample.cfg

Set these values in the [global] section:

```ini
[global]
Mode = 1                    # trace replay mode
Interface = 1               # NVMe
LogFile = STDOUT            # stats to terminal
DebugLogFile =              # leave empty (very verbose if enabled)
LatencyLogFile = /home/mohsin/traces/my_workload/sim_output/latency.log
SubmissionLatency = 5us
CompletionLatency = 5us
```

Set these values in the [trace] section:

```ini
[trace]
File = ./config/my_trace.txt
TimingMode = 0              # start with sync for first test
QueueDepth = 32
IOLimit = 0                 # 0 = replay all I/Os

# This regex matches blkparse D-event lines WITH trailing process name
Regex = "\d+,\d+ +\d+ +\d+ +(\d+).(\d+) +\d+ +D +(\w+) +(\d+) \+ (\d+) .*"

Operation  = 3
LBAOffset  = 4
LBALength  = 5
Second     = 1
Nanosecond = 2
LBASize    = 512
UseHexadecimal = 0
```

NOTE: The `.*` at the end of the Regex is REQUIRED. SimpleSSD uses
`std::regex_match()` which must match the full line. The trailing
process name like `[dmcrypt_write/2]` will not match without `.*`.

### Step 3 — Run

```bash
cd "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone"

./simplessd-standalone \
    ./config/sample.cfg \
    ./simplessd/config/sample.cfg \
    ~/traces/my_workload/sim_output
```

SimpleSSD requires exactly 3 arguments:
1. Standalone config file
2. SimpleSSD hardware config file
3. Output directory (can be empty, used for any file outputs)

### Step 4 — Read the results

```
*** Statistics of Trace Replayer ***
I/O (bytes): 0 (0.000000 B/s)
I/O (counts): 24660 (Read: 3699, Write: 20961)
*** Statistics of Block I/O Entry ***
Latency (ns): min=39564.2, max=11616553.3, avg=586788.6, stdev=771343.5
*** Statistics of Event Engine ***
End of simulation @ tick 469110246959
```

### Step 5 — Analyse the latency log

```bash
LOGFILE=~/traces/my_workload/sim_output/latency.log

# Format: id, byte_offset, length_bytes, latency_picoseconds
head -5 $LOGFILE

# Average latency in microseconds
awk -F',' '{sum+=$4; n++} END {printf "Avg: %.1f us\n", sum/n/1000000}' $LOGFILE

# Percentile breakdown
sort -t',' -k4 -n $LOGFILE | awk -F',' '
  NR==1 {min=$4}
  {a[NR]=$4}
  END {
    printf "Min:  %.1f us\n", min/1000000
    printf "p50:  %.1f us\n", a[int(NR*0.50)]/1000000
    printf "p95:  %.1f us\n", a[int(NR*0.95)]/1000000
    printf "p99:  %.1f us\n", a[int(NR*0.99)]/1000000
    printf "Max:  %.1f us\n", a[NR]/1000000
  }'
```

---

## 7. Understanding Your Results

### Latency components

Every I/O's total latency is the sum of:

```
Total = SubmissionLatency
      + NVMe command processing (HIL CPU time)
      + PCIe DMA time (depends on PCIEGeneration + PCIELane)
      + ICL cache lookup (DRAM tag check)
      + [if cache MISS] FTL L2P lookup (DRAM read)
      + [if cache MISS] NAND read/write (PAL timing)
      + [if GC triggered] GC overhead (read + write + erase)
      + CompletionLatency
```

### What causes high max latency

If max latency >> avg latency, GC is firing. Signs:
- Max latency > 3.5ms = at least one erase operation involved
- Max latency > 10ms = multiple GC operations queued

### What causes high avg latency

- Cache too small → too many cache misses → every I/O hits NAND
- Queue depth too low → not enough parallelism across channels
- Too many writes filling NAND → GC running continuously

### Write amplification

Every user write may cause multiple NAND writes due to GC. Check:
- `ftl.page_mapping.gc.page_copies` in the stats output
- A high value relative to total writes means high write amplification

---

## 8. Real Example: Idle vs Compile Workload

We captured two traces on this machine and compared them:

### Capture conditions

| | Idle Laptop | Compile (make clean && make) |
|---|---|---|
| Duration | 30 seconds | 90 seconds |
| Device | nvme0n1 | nvme0n1 |
| Dominant process | various | dmcrypt_write/2 |

### Raw trace stats

| | Idle | Compile |
|---|---|---|
| Total lines captured | 688 | 25,897 |
| Simulated I/Os | 676 | 24,660 |
| Skipped (regex mismatch) | 12 | 1,237 |

Skipped lines are usually flush/discard events with a different format.

### Simulation results (same SSD config for both)

| Metric | Idle Laptop | Compile |
|---|---|---|
| Total I/Os | 676 | 24,660 |
| Reads | 22 (3%) | 3,699 (15%) |
| Writes | 654 (97%) | 20,961 (85%) |
| Min latency | 40.2 µs | 39.6 µs |
| Max latency | 1,922 µs | **11,617 µs** |
| Avg latency | 571.8 µs | 586.8 µs |
| Std deviation | 362 µs | **771 µs** |

### What the difference tells us

MAX LATENCY: 1.9ms → 11.6ms (6x spike)
  The compile hammered the write cache so hard that:
    1. Cache filled up → evictions to NAND started
    2. Free NAND blocks drained → GC triggered
    3. GC erase takes 3.5ms alone
    4. Writes queued behind GC → total wait 11ms+

STD DEVIATION: 362µs → 771µs (2x more unpredictable)
  Some I/Os hit the cache (39µs), others waited for GC (11ms).
  This is called latency tail — a real problem for applications
  that need consistent response times.

MORE READS in compile (3% → 15%):
  The linker reading .o files shows up here, even through dmcrypt.
  Most source file reads are served from the Linux page cache (RAM)
  and never reach the disk, which is why reads are still a minority.

WHY MOSTLY WRITES:
  Your /home partition is LUKS-encrypted. Every write to any file
  in /home goes through dmcrypt_write which re-encrypts and writes
  to nvme0n1. Reads are served from the Linux page cache after the
  first access, so they rarely hit the disk during a compile.

---

## 9. Config Reference for Trace Replay

### config/sample.cfg — [global] section

| Parameter | Recommended | Effect |
|---|---|---|
| `Mode` | `1` | Enable trace replay mode |
| `Interface` | `1` | NVMe (most realistic for your laptop) |
| `LogFile` | `STDOUT` | Print stats to terminal |
| `DebugLogFile` | *(empty)* | Leave empty — extremely verbose if enabled |
| `LatencyLogFile` | full path | Where per-I/O latency is saved |
| `SubmissionLatency` | `5us` | Host OS submission overhead |
| `CompletionLatency` | `5us` | Host OS interrupt handling overhead |

### config/sample.cfg — [trace] section

| Parameter | Value | What it does |
|---|---|---|
| `File` | path | Path to your filtered trace file |
| `TimingMode` | `0`/`1`/`2` | Sync / Async / Strict timing |
| `QueueDepth` | `32` | Max outstanding I/Os in async mode |
| `IOLimit` | `0` | 0 = replay all; N = stop after N I/Os |
| `Regex` | see below | Full-line regex to parse trace |
| `Operation` | `3` | Regex group for R/W/F/D |
| `LBAOffset` | `4` | Regex group for LBA start |
| `LBALength` | `5` | Regex group for LBA count |
| `Second` | `1` | Regex group for timestamp seconds |
| `Nanosecond` | `2` | Regex group for timestamp nanoseconds |
| `LBASize` | `512` | Bytes per sector on your drive |

### The correct regex for blkparse output

```
Regex = "\d+,\d+ +\d+ +\d+ +(\d+).(\d+) +\d+ +D +(\w+) +(\d+) \+ (\d+) .*"
```

Breaking it down:

```
\d+,\d+          device (e.g. 259,0)     — ignored
 +\d+             CPU core               — ignored
 +\d+             sequence number        — ignored
 +(\d+)           timestamp seconds      → GROUP 1
\.(\d+)           timestamp nanoseconds  → GROUP 2
 +\d+             process ID             — ignored
 +D               literal "D" event type — must match
 +(\w+)           operation code         → GROUP 3 (R/W/RM/WM/etc.)
 +(\d+)           LBA start              → GROUP 4
 \+               literal "+"
 +(\d+)           LBA length             → GROUP 5
 .*               process name [xxx]     — consumed, not captured
```

---

## 10. Common Issues and Fixes

| Problem | Cause | Fix |
|---------|-------|-----|
| `Invalid number of argument!` | Missing output directory | Add 3rd argument: `./simplessd-standalone cfg1 cfg2 /output/dir` |
| `Failed to open trace file` | Wrong path in `File =` | Use absolute path or path relative to where you run the binary |
| `I/O (counts): 0` | Regex not matching lines | Check that regex ends with `.*` to consume trailing `[process]` name |
| `Invalid regular expression` | Regex syntax error | Test at regex101.com with ECMAScript mode |
| Very few I/Os simulated | `IOLimit` too low | Set `IOLimit = 0` to replay all |
| All values 0.000000 in stats | `Mode = 0` still set | Change to `Mode = 1` |
| Simulation very slow | 25k+ I/Os + strict timing | Use `TimingMode = 0` or `IOLimit = 5000` for quick tests |
| SSD out of space error | LBA range exceeds simulated capacity | Increase `Block` count in `[pal]` or reduce `OverProvisioningRatio` |
| Max latency very high (>10ms) | GC firing under write pressure | Increase `CacheSize`, lower `GCThreshold`, or add more channels |

---

## 11. File Map

After completing this workflow, your files are organised as:

```
~/traces/
├── my_workload/                  ← first capture
│   ├── trace.blktrace.0-11       ← raw binary blktrace output (one per CPU core)
│   ├── trace_parsed.txt          ← full blkparse text (all event types)
│   ├── trace_filtered.txt        ← only D events — this is what SimpleSSD reads
│   └── sim_output/
│       └── latency.log           ← per-I/O results from SimpleSSD
│                                    format: id, byte_offset, length, latency_ps
│
└── compile_workload/             ← second capture
    ├── trace.blktrace.0-11
    ├── trace_parsed.txt
    ├── trace_filtered.txt        ← 25,897 D events
    └── sim_output/
        └── latency.log           ← 24,660 I/Os simulated

SimpleSSD-Standalone/
├── config/
│   ├── sample.cfg                ← workload config (edit this for each run)
│   ├── my_trace.txt              ← copy of idle trace used by SimpleSSD
│   └── compile_trace.txt         ← copy of compile trace used by SimpleSSD
├── simplessd/config/
│   └── sample.cfg                ← SSD hardware config (NVMe, ICL, FTL, PAL, DRAM)
└── tutorial/
    ├── config_guide.md           ← all 170 config parameters documented
    └── trace_capture_guide.md    ← this file
```

### Switching between traces

To switch which trace SimpleSSD replays, change one line in config/sample.cfg:

```ini
# To replay the idle trace:
File = ./config/my_trace.txt

# To replay the compile trace:
File = ./config/compile_trace.txt
```

Then re-run:
```bash
./simplessd-standalone ./config/sample.cfg ./simplessd/config/sample.cfg /output/dir
```

---

## Quick Reference — Full Workflow

```bash
# 1. CAPTURE
mkdir -p ~/traces/my_workload && cd ~/traces/my_workload
sudo blktrace -d /dev/nvme0n1 -o trace -w 60   # Terminal 1
# ... do your workload in Terminal 2 ...

# 2. CONVERT
blkparse -i trace -o trace_parsed.txt
grep " D " trace_parsed.txt > trace_filtered.txt
wc -l trace_filtered.txt                        # check I/O count
head -5 trace_filtered.txt                      # verify format

# 3. COPY
cp trace_filtered.txt \
   "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone/config/my_trace.txt"

# 4. CONFIGURE — edit config/sample.cfg:
#   Mode = 1
#   File = ./config/my_trace.txt
#   Regex = "\d+,\d+ +\d+ +\d+ +(\d+).(\d+) +\d+ +D +(\w+) +(\d+) \+ (\d+) .*"

# 5. RUN
mkdir -p ~/traces/my_workload/sim_output
cd "/home/mohsin/Mohsin/Second Year/SIP 2026/SimpleSSD-Standalone"
./simplessd-standalone \
    ./config/sample.cfg \
    ./simplessd/config/sample.cfg \
    ~/traces/my_workload/sim_output

# 6. ANALYSE
sort -t',' -k4 -n ~/traces/my_workload/sim_output/latency.log | awk -F',' '
  {a[NR]=$4}
  END {
    printf "p50: %.1f us\n", a[int(NR*0.50)]/1000000
    printf "p99: %.1f us\n", a[int(NR*0.99)]/1000000
    printf "Max: %.1f us\n", a[NR]/1000000
  }'
```
