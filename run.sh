#!/usr/bin/env bash
# =============================================================================
# run.sh -- Simple, Easy-to-Edit Runner for SimpleSSD CMT Experiments
#
# HOW TO USE:
#   1. Edit the settings in SECTION 1 (or SECTION 2 for sweeps) below.
#   2. Set MODE="single", MODE="sweep", or MODE="test".
#   3. Run:
#        bash run.sh
#
#   You can also pass the mode directly on the command line:
#        bash run.sh single   # run one simulation using SECTION 1 settings
#        bash run.sh sweep    # run all combinations in SECTION 2
#        bash run.sh test     # run the 8 window-fill validation tests
#        bash run.sh kill     # stop all running simulations
#        bash run.sh clean    # delete temporary .sim_tmp_* folders
# =============================================================================

# Stop the script if any command fails or an undefined variable is used
set -euo pipefail

# =============================================================================
# SECTION 1: MODE & SINGLE-RUN SETTINGS (Edit these values directly)
# =============================================================================

# Choose what to run: "single", "sweep", "test", "kill", or "clean"
MODE="single"

# Workload type: "read", "write", "randread", "randwrite", or "randrw"
WORKLOAD="randwrite"

# Total data to transfer (e.g. "512M", "2G", "4G", "8G")
IO_SIZE="4G"

# Size of each I/O request (e.g. "4K", "16K", "64K")
BLOCK_SIZE="4K"

# Number of parallel requests in flight (1 = synchronous, 32 = standard NVMe)
IO_DEPTH=32

# Fraction of reads when WORKLOAD="randrw" (0.5 = 50% reads, 50% writes)
RW_MIX_READ="0.5"

# CMT replacement policy: 0 = LRU (Least Recently Used), 1 = LFU (Least Frequently Used)
CMT_POLICY=0

# CMT cache size in bytes:
#   524288   = 512 KiB
#   2097152  = 2 MiB
#   16777216 = 16 MiB
#   33554432 = 32 MiB
CMT_BYTES=16777216

# How full the SSD is after warm-up (0.0 = empty, 0.8 = 80% full, 1.0 = 100% full)
FILL_RATIO="0.8"

# Garbage Collection victim selection policy:
#   0 = Greedy, 1 = Cost-Benefit, 2 = Random, 3 = D-Choice
EVICT_POLICY=0

# CMT Window Fill (prefetch neighboring LPN mappings on a miss): "true" or "false"
WINDOW_FILL="false"

# Number of LPNs per translation window (typically 512)
WINDOW_SIZE=512

# Random seed for warm-up (0 = random each run, any other number = reproducible)
WARMUP_SEED=0

# Folder where output logs and JSON files will be saved
OUTPUT_DIR="outputs"


# =============================================================================
# SECTION 2: SWEEP SETTINGS (Used when MODE="sweep")
# =============================================================================

# Maximum number of simulations to run at the same time
MAX_PARALLEL=4

# Lists of values to test (separate items with spaces inside parentheses)
SWEEP_WORKLOADS=( "randread" "randwrite" "randrw" )
SWEEP_CMT_BYTES=( 16777216 33554432 )
SWEEP_BLOCK_SIZES=( "4K" )
SWEEP_CMT_POLICIES=( 0 1 )
SWEEP_WINDOW_FILL=( "false" )
SWEEP_WINDOW_SIZES=( 512 )
SWEEP_FILL_RATIOS=( "0.8" )
SWEEP_IO_SIZES=( "4G" )
SWEEP_RW_MIX_READ=( "0.5" )

SWEEP_IO_DEPTH=32
SWEEP_EVICT_POLICY=0


# =============================================================================
# SECTION 3: HELPER FUNCTIONS (No need to edit below this line)
# =============================================================================

# Allow overriding MODE from the command line (e.g. `bash run.sh sweep`)
if [[ $# -gt 0 ]]; then
  MODE="$1"
fi

# Find the folder where run.sh lives
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/simplessd-standalone"
BASE_CFG="$SCRIPT_DIR/config/sample.cfg"
SSD_CFG="$SCRIPT_DIR/simplessd/config/sample.cfg"

# Helper 1: Build the simulator binary every time before running
build_simulator() {
  echo "Building simplessd-standalone..."
  local build_dir="$SCRIPT_DIR/build"

  # Configure CMake if the build folder doesn't exist yet
  if [[ ! -f "$build_dir/CMakeCache.txt" ]]; then
    cmake -S "$SCRIPT_DIR" -B "$build_dir"
  fi

  # Compile using all available CPU cores
  local cores
  cores=$(nproc 2>/dev/null || echo 2)
  cmake --build "$build_dir" --target simplessd-standalone -j "$cores"

  # Copy the compiled binary to the project root so it is easy to find
  if [[ -f "$build_dir/simplessd-standalone" ]]; then
    cp "$build_dir/simplessd-standalone" "$BINARY"
  fi

  if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: Build finished, but $BINARY was not found."
    exit 1
  fi
  echo "Build complete."
  echo ""
}

# Helper 2: Replace `key = ...` with `key = new_value` in a config file
set_config_value() {
  local file="$1"
  local key="$2"
  local value="$3"

  if ! grep -q "^${key} *=" "$file"; then
    echo "ERROR: Config key '$key' not found in $file"
    exit 1
  fi
  sed -i "s|^${key} *=.*|${key} = ${value}|" "$file"
}

# Helper 3: Create a descriptive filename label for a simulation run
# Example output: randwrite_LRU_WF_OFF_16MiB_4K_4G_fill0.8_evict0
make_label() {
  local wl="$1" cmt_b="$2" bs="$3" pol="$4" wf="$5" win="$6" fill="$7" evict="$8" ios="$9" rwmix="${10}"

  local policy_name="LRU"
  if [[ "$pol" == "1" ]]; then
    policy_name="LFU"
  fi

  local wf_name="WF_OFF"
  if [[ "$wf" == "true" ]]; then
    wf_name="WF_ON_W${win}"
  fi

  local size_name
  if (( cmt_b >= 1048576 )); then
    size_name="$(( cmt_b / 1048576 ))MiB"
  else
    size_name="$(( cmt_b / 1024 ))KiB"
  fi

  local workload_name="$wl"
  if [[ "$wl" == "randrw" ]]; then
    workload_name="randrw_mix${rwmix}"
  fi

  echo "${workload_name}_${policy_name}_${wf_name}_${size_name}_${bs}_${ios}_fill${fill}_evict${evict}"
}

# Helper 4: Run a single simulation job and save its .txt and .meta.json files
run_one_simulation() {
  local wl="$1"
  local cmt_b="$2"
  local bs="$3"
  local pol="$4"
  local wf="$5"
  local win="$6"
  local fill="$7"
  local ios="$8"
  local iodepth="$9"
  local rwmix="${10}"
  local evict="${11}"

  local label
  label=$(make_label "$wl" "$cmt_b" "$bs" "$pol" "$wf" "$win" "$fill" "$evict" "$ios" "$rwmix")
  local outfile="$OUTPUT_DIR/${label}.txt"
  local metafile="$OUTPUT_DIR/${label}.meta.json"

  # In sweep mode, skip jobs that already finished in an earlier run
  if [[ "$MODE" == "sweep" && -s "$outfile" ]] && grep -q "cmt\.hit_rate" "$outfile" 2>/dev/null; then
    echo "  [SKIP] $label (already completed)"
    if [[ -n "${SWEEP_SUMMARY_FILE:-}" ]]; then
      printf "%-70s  %7s  %8s  %7s  %s\n" "$label" "-" "-" "-" "SKIPPED" >> "$SWEEP_SUMMARY_FILE"
    fi
    return 0
  fi

  echo "  [START] $label"

  # Create a temporary folder for this job's config and raw log files
  local tmp_dir
  tmp_dir=$(mktemp -d "$SCRIPT_DIR/.sim_tmp_XXXXXX")
  local stats_file="$tmp_dir/stats.log"
  local console_file="$tmp_dir/console.log"
  local standalone_cfg="$tmp_dir/standalone.cfg"
  local simplessd_cfg="$tmp_dir/simplessd.cfg"

  cp "$BASE_CFG" "$standalone_cfg"
  cp "$SSD_CFG"  "$simplessd_cfg"

  # Update standalone generator config
  set_config_value "$standalone_cfg" "readwrite"      "$wl"
  set_config_value "$standalone_cfg" "blocksize"      "$bs"
  set_config_value "$standalone_cfg" "io_size"        "$ios"
  set_config_value "$standalone_cfg" "iodepth"        "$iodepth"
  set_config_value "$standalone_cfg" "rwmixread"      "$rwmix"
  set_config_value "$standalone_cfg" "LogFile"        "$stats_file"
  set_config_value "$standalone_cfg" "LogPeriod"      "5000"
  set_config_value "$standalone_cfg" "LatencyLogFile" ""

  # Update SimpleSSD internal config
  set_config_value "$simplessd_cfg" "Block"              "512"
  set_config_value "$simplessd_cfg" "CMTCapacityBytes"   "$cmt_b"
  set_config_value "$simplessd_cfg" "CMTCapacityRatio"   "0.0"
  set_config_value "$simplessd_cfg" "CMTPolicy"          "$pol"
  set_config_value "$simplessd_cfg" "CMTWindowFill"      "$wf"
  set_config_value "$simplessd_cfg" "CMTWindowSize"      "$win"
  set_config_value "$simplessd_cfg" "FillRatio"          "$fill"
  set_config_value "$simplessd_cfg" "EvictPolicy"        "$evict"
  set_config_value "$simplessd_cfg" "WarmupSeed"         "$WARMUP_SEED"
  set_config_value "$simplessd_cfg" "EnableReadCache"    "0"
  set_config_value "$simplessd_cfg" "EnableWriteCache"   "0"

  # Record start time and run the simulator at low CPU priority (nice -n 19)
  local start_sec end_sec elapsed_sec start_iso end_iso duration_fmt sim_status=0
  start_sec=$(date +%s)
  start_iso=$(date -Iseconds 2>/dev/null || date)

  nice -n 19 "$BINARY" "$standalone_cfg" "$simplessd_cfg" "$tmp_dir/statprefix" > "$console_file" 2>&1 || sim_status=$?

  end_sec=$(date +%s)
  end_iso=$(date -Iseconds 2>/dev/null || date)
  elapsed_sec=$(( end_sec - start_sec ))
  duration_fmt=$(printf "%dm %02ds" $(( elapsed_sec / 60 )) $(( elapsed_sec % 60 )))

  # Assemble the human-readable output file
  local pol_label="LRU"
  [[ "$pol" == "1" ]] && pol_label="LFU"
  local wf_label="OFF"
  [[ "$wf" == "true" ]] && wf_label="ON"
  local win_label="N/A"
  [[ "$wf" == "true" ]] && win_label="$win"

  {
    echo "=== SimpleSSD Simulation ==="
    echo "Started         : $(date)"
    echo ""
    echo "--- Configuration ---"
    echo "Workload        : $wl"
    echo "IO Size         : $ios"
    echo "Block Size      : $bs"
    echo "CMT Policy      : $pol_label"
    echo "CMT Capacity    : $cmt_b Bytes"
    echo "Window Fill     : $wf_label"
    echo "Window Size     : $win_label"
    echo "Eviction Policy : $evict"
    echo "Fill Ratio      : $fill"
    echo "============================="
    echo ""
    echo "--- Performance ---"
    echo "Wall Time       : $duration_fmt"
    echo ""
    echo "=== SUBSYSTEM STATS ==="
    if [[ -s "$stats_file" ]]; then
      # Keep only the final periodic stats printout block
      awk '/Periodic log printout/{flag=1; buf=""}
           !/Periodic log printout/ && !/End of log/{if(flag) buf = buf $0 "\n"}
           /End of log/{flag=0}
           END{print buf}' "$stats_file" || cat "$stats_file"
    else
      echo "(WARNING: stats file empty or missing)"
    fi
    echo ""
    echo "=== RUN SUMMARY ==="
    sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\r$//' "$console_file"
    echo ""
    echo "Finished: $(date)"
  } > "$outfile"

  # Extract hit rate and window-fill accuracy from the final log
  local final_hit final_acc job_status="DONE"
  final_hit=$(grep "cmt\.hit_rate" "$outfile" 2>/dev/null | tail -n 1 | awk '{printf "%.2f", $2}' || true)
  final_acc=$(grep "fill_accuracy_percent" "$outfile" 2>/dev/null | tail -n 1 | awk '{printf "%.1f", $2}' || true)

  if [[ $sim_status -ne 0 || -z "$final_hit" ]]; then
    job_status="FAILED"
    final_hit="${final_hit:-N/A}"
    final_acc="${final_acc:-N/A}"
  fi

  # Write the .meta.json file used by analyze_outputs.py
  local compiler_ver git_sha host_name
  compiler_ver=$("${CXX:-c++}" --version 2>/dev/null | head -n 1 | tr -d '"\\' || echo "unknown")
  git_sha=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  host_name=$(hostname -s 2>/dev/null || echo "unknown")

  cat <<EOF > "$metafile"
{
  "label": "$label",
  "workload": "$wl",
  "io_size": "$ios",
  "block_size": "$bs",
  "cmt_bytes": $cmt_b,
  "cmt_policy": $pol,
  "window_fill": $wf,
  "window_size": $win,
  "fill_ratio": $fill,
  "evict_policy": $evict,
  "io_depth": $iodepth,
  "rw_mix_read": $rwmix,
  "warmup_seed": $WARMUP_SEED,
  "start_time": "$start_iso",
  "end_time": "$end_iso",
  "duration": "$duration_fmt",
  "duration_seconds": $elapsed_sec,
  "wall_secs": $elapsed_sec,
  "status": "$job_status",
  "compiler": "$compiler_ver",
  "git_commit": "$git_sha",
  "hostname": "$host_name"
}
EOF

  # Clean up temporary directory
  rm -rf "$tmp_dir"

  # Append a summary line if running a sweep
  if [[ -n "${SWEEP_SUMMARY_FILE:-}" ]]; then
    local short_time
    short_time=$(printf "%dm%02ds" $(( elapsed_sec / 60 )) $(( elapsed_sec % 60 )))
    printf "%-70s  %7s  %8s  %7s  %s\n" \
      "$label" "$short_time" "${final_hit}%" "${final_acc}%" "$job_status" >> "$SWEEP_SUMMARY_FILE"
  fi

  if [[ "$job_status" == "FAILED" ]]; then
    echo "  [FAIL]  $label (exit code $sim_status) -> $outfile"
    return 1
  else
    echo "  [DONE]  $label | Time: $duration_fmt | Hit Rate: ${final_hit}% | Fill Acc: ${final_acc}%"
    return 0
  fi
}


# =============================================================================
# SECTION 4: MAIN EXECUTION LOGIC
# =============================================================================

# --- Mode 1: Kill running simulations ---
if [[ "$MODE" == "kill" ]]; then
  echo "Stopping all running SimpleSSD simulations..."
  pkill -9 -f "simplessd-standalone" 2>/dev/null || true
  echo "Done."
  exit 0
fi

# --- Mode 2: Clean temporary directories ---
if [[ "$MODE" == "clean" ]]; then
  echo "Removing temporary .sim_tmp_* folders..."
  rm -rf "$SCRIPT_DIR"/.sim_tmp_*
  echo "Done."
  exit 0
fi

# Check that base config files exist before building
if [[ ! -f "$BASE_CFG" ]]; then echo "ERROR: Missing $BASE_CFG"; exit 1; fi
if [[ ! -f "$SSD_CFG"  ]]; then echo "ERROR: Missing $SSD_CFG";  exit 1; fi

# Always build the simulator before running single, test, or sweep mode
build_simulator
mkdir -p "$OUTPUT_DIR"

# --- Mode 3: Single simulation run ---
if [[ "$MODE" == "single" ]]; then
  echo "Running single simulation..."
  run_one_simulation \
    "$WORKLOAD" "$CMT_BYTES" "$BLOCK_SIZE" "$CMT_POLICY" \
    "$WINDOW_FILL" "$WINDOW_SIZE" "$FILL_RATIO" \
    "$IO_SIZE" "$IO_DEPTH" "$RW_MIX_READ" "$EVICT_POLICY"
  echo "Finished single run. Output saved in: $OUTPUT_DIR/"
  exit 0
fi

# --- Mode 4: Validation test mode (8 short runs) ---
if [[ "$MODE" == "test" ]]; then
  echo "Running window-fill validation suite (8 jobs)..."
  TEST_CMT=2097152
  TEST_IOS="512M"
  TEST_FAIL=0

  run_one_simulation "read"     "$TEST_CMT" "4K" "0" "false" "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1
  run_one_simulation "read"     "$TEST_CMT" "4K" "0" "true"  "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1
  run_one_simulation "randread" "$TEST_CMT" "4K" "0" "false" "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1
  run_one_simulation "randread" "$TEST_CMT" "4K" "0" "true"  "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1
  run_one_simulation "read"     "$TEST_CMT" "4K" "1" "false" "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1
  run_one_simulation "read"     "$TEST_CMT" "4K" "1" "true"  "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1
  run_one_simulation "write"    "$TEST_CMT" "4K" "0" "false" "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1
  run_one_simulation "write"    "$TEST_CMT" "4K" "0" "true"  "$WINDOW_SIZE" "1.0" "$TEST_IOS" "32" "0.5" "0" || TEST_FAIL=1

  echo ""
  echo "Checking validation invariants..."

  # Check 1: WF_OFF runs must have 0 window-fill insertions
  for f in "$OUTPUT_DIR"/*WF_OFF*.txt; do
    [[ -f "$f" ]] || continue
    ins=$(awk '/fill_insertions/ {print $2}' "$f" | cut -d. -f1)
    if [[ -n "$ins" ]] && (( ins > 0 )); then
      echo "FAIL: WF_OFF log has non-zero fill_insertions ($ins): $f"
      TEST_FAIL=1
    fi
  done

  # Check 2: Sequential read misses should drop when Window Fill is enabled
  seq_off=$(ls -t "$OUTPUT_DIR"/read_LRU_WF_OFF_*.txt 2>/dev/null | head -n 1 || true)
  seq_on=$(ls -t "$OUTPUT_DIR"/read_LRU_WF_ON_*.txt  2>/dev/null | head -n 1 || true)
  if [[ -n "$seq_off" && -n "$seq_on" ]]; then
    misses_off=$(awk '/cmt\.misses/ {print $2}' "$seq_off" | cut -d. -f1)
    misses_on=$(awk '/cmt\.misses/ {print $2}'  "$seq_on"  | cut -d. -f1)
    if (( misses_on >= misses_off )); then
      echo "FAIL: Sequential read misses did not decrease ($misses_off -> $misses_on)"
      TEST_FAIL=1
    else
      echo "PASS: Sequential read misses decreased from $misses_off to $misses_on"
    fi
  fi

  if (( TEST_FAIL > 0 )); then
    echo "ERROR: One or more validation checks failed."
    exit 1
  fi
  echo "All validation tests passed!"
  exit 0
fi

# --- Mode 5: Parameter sweep mode ---
if [[ "$MODE" == "sweep" ]]; then
  OUTPUT_DIR="${OUTPUT_DIR}/sweep_$(date +%b%d_%I-%M%p)"
  mkdir -p "$OUTPUT_DIR"
  SWEEP_SUMMARY_FILE="$OUTPUT_DIR/sweep_summary.txt"

  # Build the list of all job combinations
  jobs_list=()
  for ios in "${SWEEP_IO_SIZES[@]}"; do
    for fill in "${SWEEP_FILL_RATIOS[@]}"; do
      for wl in "${SWEEP_WORKLOADS[@]}"; do
        if [[ "$wl" == "randrw" ]]; then
          mix_list=( "${SWEEP_RW_MIX_READ[@]}" )
        else
          mix_list=( "0.5" )
        fi
        for rwmix in "${mix_list[@]}"; do
          for cmt_b in "${SWEEP_CMT_BYTES[@]}"; do
            for bs in "${SWEEP_BLOCK_SIZES[@]}"; do
              for pol in "${SWEEP_CMT_POLICIES[@]}"; do
                for wf in "${SWEEP_WINDOW_FILL[@]}"; do
                  if [[ "$wf" == "false" ]]; then
                    win_list=( "${SWEEP_WINDOW_SIZES[0]}" )
                  else
                    win_list=( "${SWEEP_WINDOW_SIZES[@]}" )
                  fi
                  for win in "${win_list[@]}"; do
                    jobs_list+=( "$wl $cmt_b $bs $pol $wf $win $fill $ios $SWEEP_IO_DEPTH $rwmix $SWEEP_EVICT_POLICY" )
                  done
                done
              done
            done
          done
        done
      done
    done
  done

  TOTAL_JOBS=${#jobs_list[@]}
  echo "Starting sweep of $TOTAL_JOBS jobs (up to $MAX_PARALLEL in parallel)"
  echo "Output folder: $OUTPUT_DIR"
  echo ""

  # Write header for sweep_summary.txt
  SWEEP_START_SEC=$(date +%s)
  {
    echo "=== SimpleSSD Sweep Summary ==="
    echo "Started    : $(date)"
    echo "Output Dir : $OUTPUT_DIR"
    echo "Total Jobs : $TOTAL_JOBS"
    echo ""
    printf "%-70s  %7s  %8s  %7s  %s\n" "Label" "Time" "CMT Hit%" "Fill Acc%" "Status"
    printf '%.0s-' {1..110}
    echo ""
  } > "$SWEEP_SUMMARY_FILE"

  # Write sweep metadata file
  compiler_ver=$("${CXX:-c++}" --version 2>/dev/null | head -n 1 | tr -d '"\\' || echo "unknown")
  git_sha=$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown")
  host_name=$(hostname -s 2>/dev/null || echo "unknown")
  cat <<EOF > "$OUTPUT_DIR/run_metadata.json"
{
  "type": "sweep",
  "git_commit": "$git_sha",
  "compiler": "$compiler_ver",
  "hostname": "$host_name",
  "started": "$(date -Iseconds 2>/dev/null || date)",
  "total_jobs": $TOTAL_JOBS,
  "max_parallel": $MAX_PARALLEL
}
EOF

  # Launch jobs, waiting whenever MAX_PARALLEL background jobs are already running
  for job_args in "${jobs_list[@]}"; do
    while (( $(jobs -rp | wc -l) >= MAX_PARALLEL )); do
      wait -n 2>/dev/null || true
    done
    # shellcheck disable=SC2086
    run_one_simulation $job_args &
  done

  # Wait for all remaining background jobs to finish
  wait

  # Write totals footer to sweep_summary.txt
  SWEEP_ELAPSED=$(( $(date +%s) - SWEEP_START_SEC ))
  DONE_COUNT=$(grep -c " DONE$" "$SWEEP_SUMMARY_FILE" || true)
  SKIP_COUNT=$(grep -c " SKIPPED$" "$SWEEP_SUMMARY_FILE" || true)
  FAIL_COUNT=$(( TOTAL_JOBS - DONE_COUNT - SKIP_COUNT ))

  {
    printf '%.0s-' {1..110}
    echo ""
    echo "=== Sweep Totals ==="
    echo "Finished    : $(date)"
    printf "Wall Time   : %dh %02dm %02ds\n" $(( SWEEP_ELAPSED / 3600 )) $(( (SWEEP_ELAPSED % 3600) / 60 )) $(( SWEEP_ELAPSED % 60 ))
    echo "Total Jobs  : $TOTAL_JOBS  ($DONE_COUNT done, $SKIP_COUNT skipped, $FAIL_COUNT failed)"
    echo "================================"
  } >> "$SWEEP_SUMMARY_FILE"

  echo ""
  echo "Sweep complete! Summary saved to: $SWEEP_SUMMARY_FILE"
  if (( FAIL_COUNT > 0 )); then
    echo "ERROR: $FAIL_COUNT job(s) failed."
    exit 1
  fi
  exit 0
fi

echo "ERROR: Unknown MODE='$MODE'. Use 'single', 'sweep', 'test', 'kill', or 'clean'."
exit 1