#!/usr/bin/env bash
# =============================================================================
# run.sh -- SimpleSSD CMT Window-Fill Experiment Runner
#
# USAGE
#   bash run.sh                  # single run with settings from SECTION 1
#   TEST_MODE=true bash run.sh   # window-fill validation test (sequential read)
#   SWEEP_MODE=true bash run.sh  # sweep all combinations from SECTION 2
#   bash run.sh kill             # forcefully terminate all running simulations
#   bash run.sh clean            # remove all orphaned .sim_tmp_ directories
#
# OUTPUT
#   outputs/<label>.txt   -- full subsystem stats + run summary
#   Sweep runtime planning: ../tutorial/10_Sweep_Runtime_Estimates.md
#   Window-fill naming:     ../tutorial/11_CMT_Window_Fill_Nomenclature.md
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# VALID CONFIGURATION PARAMETERS REFERENCE
# -----------------------------------------------------------------------------
# WORKLOAD         : "read", "write", "randread", "randwrite", "randrw"
# IO_SIZE          : Any size with suffix (e.g. "512M", "2G", "8G", "1T", "4T")
# BLOCK_SIZE       : Request size with suffix (e.g. "4K", "16K", "64K")
# IO_DEPTH         : Integer >= 1 (Async queue depth; 1 = synchronous)
# RW_MIX_READ      : Float between 0.0 and 1.0 (Fraction of reads for randrw)
# CMT_POLICY       : 0 (LRU), 1 (LFU)
# CMT_BYTES        : Integer size in bytes. (Mapping table is typically 1/1000th of SSD capacity)
#                    - 1048576     (1MiB)   -> Tiny cache for 2TB SSD
#                    - 2097152     (2MiB)
#                    - 4194304     (4MiB)
#                    - 8388608     (8MiB)
#                    - 16777216    (16MiB)
#                    - 33554432    (32MiB)
#                    - 67108864    (64MiB)
#                    - 134217728   (128MiB) -> 100% maps a 128GB SSD
#                    - 268435456   (256MiB) -> 100% maps a 256GB SSD (or 12.5% cache for 2TB)
#                    - 536870912   (512MiB) -> 100% maps a 512GB SSD (or 25% cache for 2TB)
#                    - 1073741824  (1GB)    -> 100% maps a 1TB SSD (or 50% cache for 2TB)
#                    - 2147483648  (2GB)    -> 100% maps a 2TB SSD (Standard enterprise)
#                    - 4294967296  (4GB)    -> 100% maps a 4TB SSD
#                    - 8589934592  (8GB)    -> 100% maps a 8TB SSD
#                    - 17179869184 (16GB)   -> 100% maps a 16TB SSD
# FILL_RATIO       : Float between 0.0 and 1.0 (SSD warm-up fill level)
# EVICT_POLICY     : 0 (Greedy), 1 (Cost-Benefit), 2 (Random), 3 (D-Choice)
# WINDOW_FILL      : "true" (enable CMT window fill), "false"
# WINDOW_SIZE      : Integer (LPNs per translation page, typically 512)
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# SECTION 1: SINGLE-RUN CONFIGURATION
# -----------------------------------------------------------------------------

WORKLOAD="${WORKLOAD:-randwrite}"     # randread | randwrite | randrw | read | write
IO_SIZE="${IO_SIZE:-4G}"             # total I/O to issue  (e.g. 512M, 2G, 4G, 8G)
BLOCK_SIZE="${BLOCK_SIZE:-4K}"       # request size        (e.g. 4K, 16K, 64K)
IO_DEPTH="${IO_DEPTH:-32}"           # async queue depth   (1 = synchronous)
RW_MIX_READ="${RW_MIX_READ:-0.5}"    # read fraction for randrw (ignored otherwise)

CMT_POLICY="${CMT_POLICY:-0}"        # 0 = LRU  |  1 = LFU
CMT_BYTES="${CMT_BYTES:-16777216}"   # CMT size in bytes  (16777216 = 16 MiB)
FILL_RATIO="${FILL_RATIO:-0.8}"      # warm-up fill level  (0.0 to 1.0)
EVICT_POLICY="${EVICT_POLICY:-0}"    # GC victim selection: 0=greedy 1=cost-benefit 2=random 3=d-choice
WINDOW_FILL="${WINDOW_FILL:-true}"   # CMT window fill: true | false
WINDOW_SIZE="${WINDOW_SIZE:-512}"   # LPNs per translation page (fixed)

OUTPUT_DIR="${OUTPUT_DIR:-outputs}"         # directory to write .log files into
PROGRESS_INTERVAL="${PROGRESS_INTERVAL:-5}" # Live progress update interval in seconds

# -----------------------------------------------------------------------------
# SECTION 2: SWEEP & TEST CONFIGURATION
# -----------------------------------------------------------------------------

SWEEP_MODE="${SWEEP_MODE:-false}"
TEST_MODE="${TEST_MODE:-false}"

# MAX_PARALLEL: Number of simulator instances to run simultaneously.
# Options: 1 (Sequential), 4-16 (Depending on available CPU cores and RAM).
MAX_PARALLEL="${MAX_PARALLEL:-4}"

# SWEEP_WORKLOADS: The I/O access patterns to simulate.
# Options: "read" (Sequential Read), "write" (Sequential Write),
#          "randread" (Random Read), "randwrite" (Random Write), "randrw" (Mixed Random).
if [[ -z "${SWEEP_WORKLOADS+x}" ]]; then
  SWEEP_WORKLOADS=( "randread" "randwrite" "randrw" )
fi

# SWEEP_CMT_BYTES: Capacity of the Cached Mapping Table in bytes.
# Options: Any integer. Common: 524288 (512KiB), 2097152 (2MiB), 16777216 (16MiB), 33554432 (32MiB).
if [[ -z "${SWEEP_CMT_BYTES+x}" ]]; then
  SWEEP_CMT_BYTES=( 16777216 33554432 )
fi

# SWEEP_BLOCK_SIZES: Request size of the host I/O.
# Options: "4K", "8K", "16K", "32K", "64K", "128K", etc. (Must be multiplier of NAND page).
if [[ -z "${SWEEP_BLOCK_SIZES+x}" ]]; then
  SWEEP_BLOCK_SIZES=( "4K" )
fi

# SWEEP_CMT_POLICIES: Eviction policy for the Cached Mapping Table.
# Options: 0 (LRU - Least Recently Used), 1 (LFU - Least Frequently Used).
if [[ -z "${SWEEP_CMT_POLICIES+x}" ]]; then
  SWEEP_CMT_POLICIES=( 0 1 )
fi

# SWEEP_WINDOW_FILL: Enable or disable CMT window fill on a demand miss.
# Options: "false" (Disabled), "true" (Enabled).
if [[ -z "${SWEEP_WINDOW_FILL+x}" ]]; then
  SWEEP_WINDOW_FILL=( "false" "true" )
fi

# SWEEP_WINDOW_SIZES: LPNs to install from one translation-page read.
# Fixed at 512 (one mapping page). Do not derive from PAL PageSize.
if [[ -z "${SWEEP_WINDOW_SIZES+x}" ]]; then
  SWEEP_WINDOW_SIZES=( 512 )
fi

# SWEEP_FILL_RATIO: The initial capacity utilization of the SSD before the test begins.
# Options: 0.0 (Empty SSD) to 1.0 (Completely full, forces immediate GC and steady-state).
if [[ -z "${SWEEP_FILL_RATIOS+x}" ]]; then
  SWEEP_FILL_RATIOS=( 0.8 )
fi

# SWEEP_IO_SIZES: Total amount of I/O data to issue during the simulation.
# Options: "1G", "4G", "16G", "64G", etc. Larger sizes ensure steady-state cache behavior.
if [[ -z "${SWEEP_IO_SIZES+x}" ]]; then
  SWEEP_IO_SIZES=( "4G" )
fi

# SWEEP_IO_DEPTH: Number of outstanding asynchronous I/O requests.
# Options: 1 (Synchronous), 32 (Standard NVMe), 128 (Heavy enterprise load).
SWEEP_IO_DEPTH="${SWEEP_IO_DEPTH:-32}"

# SWEEP_RW_MIX_READ: Percentage of read operations (only applies if workload is "randrw").
# Options: 0.0 to 1.0. (e.g., 0.7 = 70% Reads, 30% Writes).
if [[ -z "${SWEEP_RW_MIX_READ+x}" ]]; then
  SWEEP_RW_MIX_READ=( 0.5 )
fi

# SWEEP_EVICT_POLICY: Victim block selection policy for NAND Garbage Collection.
# Options: 0 (Greedy), 1 (Cost-Benefit), 2 (Random), 3 (d-Choice).
SWEEP_EVICT_POLICY="${SWEEP_EVICT_POLICY:-0}"

# -----------------------------------------------------------------------------
# SECTION 3: RUN LOGIC
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Utilities ---
if [[ "${1:-}" == "kill" ]]; then
  echo "Killing all active SimpleSSD simulators and background sweeps..."
  pkill -9 -f "simplessd-standalone" 2>/dev/null || true
  killall -9 simplessd-standalone 2>/dev/null || true
  
  # Kill all other run.sh scripts except this one
  for pid in $(pgrep -f "bash.*run.sh" 2>/dev/null); do
    if [[ "$pid" != "$$" ]]; then
      kill -9 "$pid" 2>/dev/null || true
    fi
  done
  echo "Done."
  exit 0
fi

if [[ "${1:-}" == "clean" ]]; then
  echo "Removing orphaned .sim_tmp_* directories..."
  rm -rf "$SCRIPT_DIR"/.sim_tmp_*
  echo "Done."
  exit 0
fi

BINARY="$SCRIPT_DIR/simplessd-standalone"
BUILD_STAMP="$SCRIPT_DIR/.run-build-initialized"
BUILD_LOCK="$SCRIPT_DIR/.run-build.lock"

exec 9>"$BUILD_LOCK"
flock -x 9
if [[ ! -f "$BUILD_STAMP" ]]; then
  echo "First run: removing the old binary and building SimpleSSD..."
  rm -f "$BINARY"
  BUILD_DIR="$SCRIPT_DIR"
  if [[ -f "$SCRIPT_DIR/build/CMakeCache.txt" ]]; then
    BUILD_DIR="$SCRIPT_DIR/build"
  fi
  cmake --build "$BUILD_DIR" --target simplessd-standalone
  if [[ "$BUILD_DIR" != "$SCRIPT_DIR" && -f "$BUILD_DIR/simplessd-standalone" ]]; then
    cp "$BUILD_DIR/simplessd-standalone" "$BINARY"
  fi
  [[ -x "$BINARY" ]] || {
    echo "ERROR: build completed without creating executable: $BINARY"
    exit 1
  }
  printf 'Initialized: %s\n' "$(date)" > "$BUILD_STAMP"
fi
flock -u 9

BASE_CFG="$SCRIPT_DIR/config/sample.cfg"
SSD_CFG="$SCRIPT_DIR/simplessd/config/sample.cfg"

# Sanity checks
[[ -x "$BINARY"   ]] || { echo "ERROR: binary not found: $BINARY"; exit 1; }
[[ -f "$BASE_CFG" ]] || { echo "ERROR: missing: $BASE_CFG"; exit 1; }
[[ -f "$SSD_CFG"  ]] || { echo "ERROR: missing: $SSD_CFG"; exit 1; }

mkdir -p "$OUTPUT_DIR"


make_label() {
  local p="LRU"; [ "$4" = "1" ] && p="LFU"
  local pf="WF_OFF"; [ "$5" = "true" ] && pf="WF_ON_W$6"
  local sz="$(( $2 / 1048576 ))MiB"; (( $2 < 1048576 )) && sz="$(( $2 / 1024 ))KiB"
  local w="$1"; [ "$1" = "randrw" ] && w="${1}_mix${10}"
  echo "${w}_${p}_${pf}_${sz}_$3_$9_fill$7_evict$8"
}

run_one() {
  local wl="$1" cmt_b="$2" bs="$3" pol="$4" pref="$5" win="$6" \
        fill="$7" ios="$8" iodepth="$9" rwmix="${10}" evict="${11}"

  local label
  label=$(make_label "$wl" "$cmt_b" "$bs" "$pol" "$pref" "$win" "$fill" "$evict" "$ios" "$rwmix")
  local outfile="$OUTPUT_DIR/${label}.txt"

  # Skip if this simulation was already completed in a previous run
  if [[ "$SWEEP_MODE" == "true" && -s "$outfile" && -n "$(grep "cmt\.hit_rate" "$outfile" 2>/dev/null)" ]]; then
    if [[ -n "${SWEEP_SUMMARY_FILE:-}" ]]; then
      flock "$SWEEP_SUMMARY_FILE" \
        printf "%-70s  %7s  %8s  %7s  %s\n" \
        "$label" "-" "-" "-" "SKIPPED" >> "$SWEEP_SUMMARY_FILE"
    fi
    return 0
  fi

  local tmp
  tmp=$(mktemp -d "$SCRIPT_DIR/.sim_tmp_XXXXXX")
  local statsfile="$tmp/stats.log"

  # Patch LogPeriod=5000 in standalone config so we get live stats updates
  sed \
    -e "s|^readwrite *=.*|readwrite = $wl|" \
    -e "s|^blocksize *=.*|blocksize = $bs|" \
    -e "s|^io_size *=.*|io_size = $ios|" \
    -e "s|^iodepth *=.*|iodepth = $iodepth|" \
    -e "s|^rwmixread *=.*|rwmixread = $rwmix|" \
    -e "s|^LogFile *=.*|LogFile = $statsfile|" \
    -e "s|^LogPeriod *=.*|LogPeriod = 5000|" \
    -e "s|^LatencyLogFile *=.*|LatencyLogFile =|" \
    "$BASE_CFG" > "$tmp/standalone.cfg"

  sed \
    -e "s|^Block *=.*|Block = 512|" \
    -e "s|^CMTCapacityBytes *=.*|CMTCapacityBytes = $cmt_b|" \
    -e "s|^CMTCapacityRatio *=.*|CMTCapacityRatio = 0.0|" \
    -e "s|^CMTPolicy *=.*|CMTPolicy = $pol|" \
    -e "s|^CMTWindowFill *=.*|CMTWindowFill = $pref|" \
    -e "s|^CMTWindowSize *=.*|CMTWindowSize = $win|" \
    -e "s|^FillRatio *=.*|FillRatio = $fill|" \
    -e "s|^EvictPolicy *=.*|EvictPolicy = $evict|" \
    -e "s|^EnableReadCache *=.*|EnableReadCache = 0|" \
    -e "s|^EnableWriteCache *=.*|EnableWriteCache = 0|" \
    "$SSD_CFG" > "$tmp/simplessd.cfg"

  if [[ "$SWEEP_MODE" != "true" ]]; then echo "  -> $label"; fi

  local summary="$tmp/summary.log"
  local start_time end_time elapsed_s

  # Run the simulator in the background at lowest priority to prevent CPU lockouts
  nice -n 19 "$BINARY" "$tmp/standalone.cfg" "$tmp/simplessd.cfg" "$tmp/statprefix" \
    > "$summary" 2>&1 &
  local sim_pid=$!
  start_time=$(date +%s)

  local sim_status=0
  wait "$sim_pid" || sim_status=$?
  end_time=$(date +%s)
  elapsed_s=$(( end_time - start_time ))

  {
    echo "=== SimpleSSD Simulation ==="
    echo "Started         : $(date)"
    echo ""
    echo "--- Configuration ---"
    echo "Workload        : $wl"
    echo "IO Size         : $ios"
    echo "Block Size      : $bs"
    echo "CMT Policy      : $( [ "$pol" = "0" ] && echo "LRU" || echo "LFU" )"
    echo "CMT Capacity    : $cmt_b Bytes"
    echo "Window Fill     : $( [ "$pref" = "true" ] && echo "ON" || echo "OFF" )"
    if [ "$pref" = "true" ]; then
      echo "Window Size     : $win"
    else
      echo "Window Size     : N/A"
    fi
    echo "Eviction Policy : $evict"
    echo "Fill Ratio      : $fill"
    echo "============================="
    echo ""
    echo "--- Performance ---"
    printf  "Wall Time       : %dm %02ds\n" $((elapsed_s/60)) $((elapsed_s%60))
    echo ""
    echo "=== SUBSYSTEM STATS ==="
    if [[ -f "$statsfile" && -s "$statsfile" ]]; then
      # Strip out the periodic log banners to only show final stats
      awk '/Periodic log printout/{flag=1; buf=""}
           !/Periodic log printout/ && !/End of log/{if(flag) buf = buf $0 "\n"}
           /End of log/{flag=0}
           END{print buf}' "$statsfile" || cat "$statsfile"
    else
      echo "(WARNING: stats file empty or missing)"
    fi
    echo ""
    echo "=== RUN SUMMARY ==="
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$summary"
    echo ""
    echo "Finished: $(date)"
  } > "$outfile"

  rm -rf "$tmp"

  local final_hit final_acc elapsed_fmt
  final_hit=$(grep "cmt\.hit_rate" "$outfile" 2>/dev/null | tail -n1 | awk '{printf "%.2f", $2}' || true)
  final_acc=$(grep "fill_accuracy_percent" "$outfile" 2>/dev/null | tail -n1 | awk '{printf "%.1f", $2}' || true)

  local job_status="DONE"
  if [[ $sim_status -ne 0 || -z "$final_hit" || "$final_hit" == "N/A" ]]; then
    job_status="FAILED"
    final_hit="${final_hit:-N/A}"
    final_acc="${final_acc:-N/A}"
  fi

  # Append one row to the sweep summary (flock for safe concurrent writes from parallel jobs)
  if [[ -n "${SWEEP_SUMMARY_FILE:-}" ]]; then
    elapsed_fmt=$(printf "%dm%02ds" $((elapsed_s/60)) $((elapsed_s%60)))
    flock "$SWEEP_SUMMARY_FILE" \
      printf "%-70s  %7s  %8s  %7s  %s\n" \
      "$label" "$elapsed_fmt" "${final_hit}%" "${final_acc}%" "$job_status" \
      >> "$SWEEP_SUMMARY_FILE"
  fi

  if [[ "$job_status" == "FAILED" ]]; then
    echo "  [ERROR] Simulation failed for $label (exit code $sim_status). Log: $outfile"
  elif [[ "$SWEEP_MODE" != "true" ]]; then
    if [[ "$final_hit" != "N/A" ]]; then
      printf "     CMT hit rate: %s%%   window-fill accuracy: %s%%\n" "$final_hit" "$final_acc"
    fi
    echo "     Log: $outfile"
  fi
}

# ── Test mode ─────────────────────────────────────────────────────────────────
# A/B invariants (same CMT size, fill, and I/O size):
#   sequential read: WF_ON misses drop vs WF_OFF; accuracy should be high
#   random read:     WF_ON may pollute more; writebacks must not explode
#   sequential write (fill=1.0): GC misses must not drive fill_triggers
if [[ "$TEST_MODE" == "true" ]]; then
  echo "SimpleSSD -- PF validation (sequential / random / GC-ish write)"
  echo ""

  TEST_WINDOW="${WINDOW_SIZE:-512}"
  TEST_CMT="${CMT_BYTES:-2097152}"
  TEST_IOS="${IO_SIZE:-512M}"

  run_one "read"     "$TEST_CMT" "4K" "0" "false" "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"
  run_one "read"     "$TEST_CMT" "4K" "0" "true"  "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"
  run_one "randread" "$TEST_CMT" "4K" "0" "false" "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"
  run_one "randread" "$TEST_CMT" "4K" "0" "true"  "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"
  run_one "read"     "$TEST_CMT" "4K" "1" "false" "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"
  run_one "read"     "$TEST_CMT" "4K" "1" "true"  "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"
  run_one "write"    "$TEST_CMT" "4K" "0" "false" "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"
  run_one "write"    "$TEST_CMT" "4K" "0" "true"  "$TEST_WINDOW" "1.0" "$TEST_IOS" "32" "0.5" "0"

  echo ""
  echo "Checking window-fill stat invariants..."
  for f in "$OUTPUT_DIR"/*.txt; do
    ins=$(awk '/fill_insertions/ {print $2}' "$f" | cut -d. -f1)
    if [[ "$f" == *"WF_OFF"* ]] && (( ins > 0 )); then
      echo "FAIL: $f (WF_OFF has insertions)"
    fi
  done
  seq_off=$(ls "$OUTPUT_DIR"/read_LRU_WF_OFF_*.txt 2>/dev/null | tail -n1 || true)
  seq_on=$(ls "$OUTPUT_DIR"/read_LRU_WF_ON_*.txt 2>/dev/null | tail -n1 || true)
  if [[ -n "$seq_off" && -n "$seq_on" ]]; then
    moff=$(awk '/cmt.misses/ {print $2}' "$seq_off" | cut -d. -f1)
    mon=$(awk '/cmt.misses/ {print $2}' "$seq_on" | cut -d. -f1)
    (( mon >= moff )) && echo "FAIL: sequential misses did not drop ($moff -> $mon)" || echo "PASS A/B (sequential)"
  fi

  echo ""
  echo "Test done."
  exit 0
fi

# ── Sweep mode ────────────────────────────────────────────────────────────────
if [[ "$SWEEP_MODE" == "true" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR}/sweep_$(date +%b%d_%I-%M%p)"
  mkdir -p "$OUTPUT_DIR"

  echo "SimpleSSD -- sweep mode"
  echo "  Output dir   : $OUTPUT_DIR"
  echo "  Max parallel : $MAX_PARALLEL"
  echo ""

  # Calculate total jobs and build jobs array
  jobs_to_run=()
  for ios in "${SWEEP_IO_SIZES[@]}"; do
    for fill in "${SWEEP_FILL_RATIOS[@]}"; do
      for wl in "${SWEEP_WORKLOADS[@]}"; do
        if [[ "$wl" == "randrw" ]]; then mixes=( "${SWEEP_RW_MIX_READ[@]}" ); else mixes=( "0.5" ); fi
        for rwmix in "${mixes[@]}"; do
          for cmt_b in "${SWEEP_CMT_BYTES[@]}"; do
            for bs in "${SWEEP_BLOCK_SIZES[@]}"; do
              for pol in "${SWEEP_CMT_POLICIES[@]}"; do
                for pref in "${SWEEP_WINDOW_FILL[@]}"; do
                  if [[ "$pref" == "false" ]]; then windows=( "${SWEEP_WINDOW_SIZES[0]}" ); else windows=( "${SWEEP_WINDOW_SIZES[@]}" ); fi
                  for win in "${windows[@]}"; do
                    jobs_to_run+=("$wl $cmt_b $bs $pol $pref $win $fill $ios $SWEEP_IO_DEPTH $rwmix $SWEEP_EVICT_POLICY")
                  done
                done
              done
            done
          done
        done
      done
    done
  done

  TOTAL_JOBS=${#jobs_to_run[@]}
  echo "  Total Jobs   : $TOTAL_JOBS"
  echo ""

  # Initialise the sweep summary file with a header
  SWEEP_SUMMARY_FILE="$OUTPUT_DIR/sweep_summary.txt"
  export SWEEP_SUMMARY_FILE
  SWEEP_START_TIME=$(date +%s)
  {
    echo "=== SimpleSSD Sweep Summary ==="
    echo "Started    : $(date)"
    echo "Output Dir : $OUTPUT_DIR"
    echo "Total Jobs : $TOTAL_JOBS"
    echo ""
    printf "%-70s  %7s  %8s  %7s  %s\n" \
      "Label" "Time" "CMT Hit%" "Fill Acc%" "Status"
    printf '%s\n' "$(printf '%.0s-' {1..120})"
  } > "$SWEEP_SUMMARY_FILE"

  # Start the progress poller in the background
  (
    sweep_start=$(date +%s)
    prev_completed=0
    while true; do
      sleep 5
      completed=$(find "$OUTPUT_DIR" -maxdepth 1 -name "*.txt" ! -name "sweep_summary.txt" 2>/dev/null | wc -l)
      pct=$(awk -v c="$completed" -v t="$TOTAL_JOBS" 'BEGIN {printf "%.1f", (c / t) * 100}')
      elapsed=$(( $(date +%s) - sweep_start ))

      eta_str="--:--"
      if [[ "$completed" -gt 0 && "$completed" -lt "$TOTAL_JOBS" ]]; then
        eta=$(( (elapsed / completed) * (TOTAL_JOBS - completed) ))
        eta_str=$(printf "%02dm %02ds" $((eta/60)) $((eta%60)))
      fi

      latest_hr="N/A"
      latest_file=$(find "$OUTPUT_DIR" -maxdepth 1 -name "*.txt" ! -name "sweep_summary.txt" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
      if [[ -n "$latest_file" && -f "$latest_file" ]]; then
        latest_hr=$(grep 'cmt\.hit_rate' "$latest_file" | tail -n1 | awk '{printf "%.2f", $2}')
        latest_hr="${latest_hr:-N/A}"
      fi

      printf "\r\033[K[ %3ds ] Sweep: %3d / %3d ( %5.1f%% ) | ETA: %-9s | Last HR: %s%%" \
             "$elapsed" "$completed" "$TOTAL_JOBS" "$pct" "$eta_str" "$latest_hr"

      if [[ "$completed" -ge "$TOTAL_JOBS" ]]; then break; fi
      prev_completed=$completed
    done
    printf "\n"
  ) &
  POLLER_PID=$!

  workers=()
  for job_args in "${jobs_to_run[@]}"; do
    if (( ${#workers[@]} >= MAX_PARALLEL )); then
      wait -n "${workers[@]}" 2>/dev/null || true
      alive=()
      for pid in "${workers[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
          alive+=("$pid")
        fi
      done
      workers=("${alive[@]}")
    fi
    # shellcheck disable=SC2086
    run_one $job_args &
    workers+=("$!")
  done

  # Wait for all remaining worker simulations to finish
  if (( ${#workers[@]} > 0 )); then
    wait "${workers[@]}" 2>/dev/null || true
  fi

  # Terminate and wait for progress poller
  kill "$POLLER_PID" 2>/dev/null || true
  wait "$POLLER_PID" 2>/dev/null || true

  # Write the sweep totals footer
  SWEEP_END_TIME=$(date +%s)
  SWEEP_ELAPSED=$(( SWEEP_END_TIME - SWEEP_START_TIME ))
  DONE_COUNT=$(grep -c " DONE$" "$SWEEP_SUMMARY_FILE" || echo 0)
  SKIP_COUNT=$(grep -c " SKIPPED$" "$SWEEP_SUMMARY_FILE" || echo 0)
  FAIL_COUNT=$(( TOTAL_JOBS - DONE_COUNT - SKIP_COUNT ))
  SLOWEST=$(grep " DONE$" "$SWEEP_SUMMARY_FILE" | awk 'BEGIN{max=0} {split($2,a,"m"); s=a[1]*60+a[2]; if(s>max){max=s; line=$0}} END{print line}')
  FASTEST=$(grep " DONE$" "$SWEEP_SUMMARY_FILE" | awk 'BEGIN{min=999999} {split($2,a,"m"); s=a[1]*60+a[2]; if(s<min){min=s; line=$0}} END{print line}')
  CPU_HOURS=$(grep " DONE$" "$SWEEP_SUMMARY_FILE" | awk '{split($2,a,"m"); s=a[1]*60+a[2]; sum+=s} END {printf "%.1f", sum/3600}')
  {
    printf '%s\n' "$(printf '%.0s-' {1..120})"
    echo ""
    echo "=== Sweep Totals ==="
    echo "Finished    : $(date)"
    printf "Wall Time   : %dh %02dm %02ds\n" $((SWEEP_ELAPSED/3600)) $(( (SWEEP_ELAPSED%3600)/60 )) $((SWEEP_ELAPSED%60))
    echo "Total Jobs  : $TOTAL_JOBS  ($DONE_COUNT done, $SKIP_COUNT skipped, $FAIL_COUNT failed)"
    echo "CPU-Hours   : $CPU_HOURS"
    echo "Slowest Job : $(echo "$SLOWEST" | awk '{print $1, $2}')"
    echo "Fastest Job : $(echo "$FASTEST" | awk '{print $1, $2}')"
    echo "================================"
  } >> "$SWEEP_SUMMARY_FILE"

  echo ""
  echo "All done. Logs in: $OUTPUT_DIR/"
  echo "Summary  : $SWEEP_SUMMARY_FILE"
  exit 0
fi

# ── Single-run mode ───────────────────────────────────────────────────────────
echo "SimpleSSD -- single run"
echo ""
run_one "$WORKLOAD" "$CMT_BYTES" "$BLOCK_SIZE" "$CMT_POLICY" \
        "$WINDOW_FILL" "$WINDOW_SIZE" "$FILL_RATIO" \
        "$IO_SIZE" "$IO_DEPTH" "$RW_MIX_READ" "$EVICT_POLICY"
echo ""
echo "Done."
