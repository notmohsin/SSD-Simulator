#!/usr/bin/env bash
# =============================================================================
# run_trace.sh — SimpleSSD MSR Cambridge Trace Replay Runner
#
# Runs stg_0.txt trace with realistic scaling and faithful unit parsing.
#
# USAGE
#   bash run_trace.sh                      # Runs default LRU, WF=false, 16MiB CMT
#   CMT_POLICY=1 bash run_trace.sh         # Runs LFU policy
#   WINDOW_FILL=true bash run_trace.sh     # Runs with Window Fill (spatial prefetch)
#   IO_LIMIT=100000 bash run_trace.sh      # Fast run (first 100k requests)
#   SWEEP=true bash run_trace.sh           # Runs comparison matrix across policies
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BINARY="$SCRIPT_DIR/build/simplessd-standalone"
[[ -x "$BINARY" ]] || BINARY="$SCRIPT_DIR/simplessd-standalone"

# Build if binary is missing
if [[ ! -x "$BINARY" ]]; then
  echo "Building simplessd-standalone..."
  cmake -S "$SCRIPT_DIR" -B "$SCRIPT_DIR/build"
  cmake --build "$SCRIPT_DIR/build" --target simplessd-standalone -j"$(nproc 2>/dev/null || echo 2)"
  BINARY="$SCRIPT_DIR/build/simplessd-standalone"
fi

TRACE_SRC="$SCRIPT_DIR/config/trace_stg_0.cfg"
SSD_SRC="$SCRIPT_DIR/config/ssd_trace_replay.cfg"
TRACE_FILE="$SCRIPT_DIR/Traces/stg_0.txt"

# Sanity checks
[[ -f "$TRACE_FILE" ]] || {
  echo "ERROR: Trace file not found: $TRACE_FILE"
  echo "Run: git lfs pull   (or bash Traces/download_traces.sh)"
  exit 1
}
[[ -f "$TRACE_SRC" ]] || { echo "ERROR: Missing $TRACE_SRC"; exit 1; }
[[ -f "$SSD_SRC"   ]] || { echo "ERROR: Missing $SSD_SRC"; exit 1; }

# Configuration parameters with sensible defaults
CMT_POLICY="${CMT_POLICY:-0}"          # 0=LRU, 1=LFU
WINDOW_FILL="${WINDOW_FILL:-false}"    # false=Demand fill, true=Window fill
WINDOW_SIZE="${WINDOW_SIZE:-512}"      # 512 LPNs per translation page
CMT_BYTES="${CMT_BYTES:-16777216}"     # 16 MiB default CMT size
BLOCK_COUNT="${BLOCK_COUNT:-64}"       # 64 GiB physical NAND geometry (trace spans 10.82 GiB)
IO_LIMIT="${IO_LIMIT:-0}"              # 0 = entire trace (~2.03M requests), or e.g. 100000
OUTPUT_DIR="${OUTPUT_DIR:-outputs_trace}"
SWEEP="${SWEEP:-false}"

mkdir -p "$OUTPUT_DIR"

format_bytes() {
  local b="$1"
  if (( b >= 1048576 )); then
    echo "$(( b / 1048576 ))MiB"
  elif (( b >= 1024 )); then
    echo "$(( b / 1024 ))KiB"
  else
    echo "${b}B"
  fi
}

run_trace_instance() {
  local pol="$1" wf="$2" cmt_b="$3" limit="$4"
  local pol_name="LRU"
  [[ "$pol" == "1" ]] && pol_name="LFU"
  local wf_name="WF_OFF"
  [[ "$wf" == "true" ]] && wf_name="WF_ON_W${WINDOW_SIZE}"
  local sz_name
  sz_name=$(format_bytes "$cmt_b")
  local limit_name="full"
  (( limit > 0 )) && limit_name="${limit}req"

  local label="trace_stg0_${pol_name}_${wf_name}_${sz_name}_${limit_name}"
  local run_dir="$OUTPUT_DIR/$label"
  local stats_file="$run_dir/sim_stats.log"

  if [[ -f "$stats_file" && -s "$stats_file" ]]; then
    echo "  [SKIPPED] Already finished: $label"
    return 0
  fi

  rm -rf "$run_dir"
  mkdir -p "$run_dir"

  local tmp_cfg
  tmp_cfg=$(mktemp -d "/tmp/sim_trace_XXXXXX")

  # Generate patched trace config
  sed \
    -e "s|^TimingMode *=.*|TimingMode = 0|" \
    -e "s|^IOLimit *=.*|IOLimit = $limit|" \
    -e "s|^ProgressPeriod *=.*|ProgressPeriod = 5000|" \
    -e "s|^LatencyLogFile *=.*|LatencyLogFile =|" \
    -e "s|^DebugLogFile *=.*|DebugLogFile =|" \
    "$TRACE_SRC" > "$tmp_cfg/trace.cfg"

  # Generate patched SSD config (scaled 64GiB geometry, FillRatio=0.0)
  sed \
    -e "s|^Block *=.*|Block = $BLOCK_COUNT|" \
    -e "s|^CMTCapacityBytes *=.*|CMTCapacityBytes = $cmt_b|" \
    -e "s|^CMTCapacityRatio *=.*|CMTCapacityRatio = 0.0|" \
    -e "s|^CMTPolicy *=.*|CMTPolicy = $pol|" \
    -e "s|^CMTWindowFill *=.*|CMTWindowFill = $wf|" \
    -e "s|^CMTWindowSize *=.*|CMTWindowSize = $WINDOW_SIZE|" \
    -e "s|^FillRatio *=.*|FillRatio = 0.0|" \
    -e "s|^InvalidPageRatio *=.*|InvalidPageRatio = 0.0|" \
    -e "s|^CacheSize *=.*|CacheSize = 67108864|" \
    -e "s|^ChipSize *=.*|ChipSize = 67108864|" \
    -e "s|^EnableReadCache *=.*|EnableReadCache = 0|" \
    -e "s|^EnableWriteCache *=.*|EnableWriteCache = 0|" \
    "$SSD_SRC" > "$tmp_cfg/ssd.cfg"

  echo "==> Starting: $label"
  local start_time end_time elapsed_s start_iso end_iso duration_fmt
  start_time=$(date +%s)
  start_iso=$(date -Iseconds 2>/dev/null || date)

  "$BINARY" "$tmp_cfg/trace.cfg" "$tmp_cfg/ssd.cfg" "$run_dir" \
    > "$run_dir/console.log" 2>&1

  end_time=$(date +%s)
  end_iso=$(date -Iseconds 2>/dev/null || date)
  elapsed_s=$(( end_time - start_time ))
  duration_fmt=$(printf "%dm %02ds" $((elapsed_s / 60)) $((elapsed_s % 60)))
  rm -rf "$tmp_cfg"

  # Write metadata
  local compiler_ver
  compiler_ver=$("${CXX:-c++}" --version 2>/dev/null | head -n1 | sed -e 's/["\\]//g' || echo "unknown")
  {
    printf '{\n'
    printf '  "label": "%s",\n'            "$label"
    printf '  "trace": "stg_0.txt",\n'
    printf '  "cmt_policy": %s,\n'         "$pol"
    printf '  "window_fill": %s,\n'        "$wf"
    printf '  "window_size": %s,\n'        "$WINDOW_SIZE"
    printf '  "cmt_bytes": %s,\n'          "$cmt_b"
    printf '  "io_limit": %s,\n'           "$limit"
    printf '  "start_time": "%s",\n'       "$start_iso"
    printf '  "end_time": "%s",\n'         "$end_iso"
    printf '  "duration": "%s",\n'         "$duration_fmt"
    printf '  "duration_seconds": %s,\n'   "$elapsed_s"
    printf '  "wall_secs": %s,\n'          "$elapsed_s"
    printf '  "compiler": "%s",\n'         "$compiler_ver"
    printf '  "git_commit": "%s",\n'       "$(git -C "$SCRIPT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    printf '  "hostname": "%s"\n'          "$(hostname -s 2>/dev/null || echo unknown)"
    printf '}\n'
  } > "$run_dir/run_metadata.json"

  # Extract summary metrics
  local hr="N/A" acc="N/A" lat="N/A"
  if [[ -f "$stats_file" ]]; then
    hr=$(awk '/cmt.hit_rate/ {printf "%.2f", $2}' "$stats_file" 2>/dev/null || echo "N/A")
    acc=$(awk '/fill_accuracy_percent/ {printf "%.1f", $2}' "$stats_file" 2>/dev/null || echo "N/A")
    lat=$(awk '/Latency \(([^)]+)\):/ {
      unit="us";
      if ($0 ~ /Latency \(ns\):/) unit="ns";
      if ($0 ~ /Latency \(ms\):/) unit="ms";
      for (i=1; i<=NF; i++) {
        if ($i ~ /^avg=/) {
          split($i, a, "=");
          val = a[2] + 0;
          if (unit == "ns") val = val / 1000.0;
          if (unit == "ms") val = val * 1000.0;
          printf "%.2f", val;
        }
      }
    }' "$run_dir/console.log" 2>/dev/null || echo "N/A")
  fi

  printf "  [FINISHED] Time: %dm%02ds | CMT Hit: %s%% | Window Acc: %s%% | Avg Lat: %s us\n" \
    $((elapsed_s / 60)) $((elapsed_s % 60)) "$hr" "$acc" "$lat"
  echo "  Log: $stats_file"
  echo ""
}

if [[ "$SWEEP" == "true" ]]; then
  echo "=========================================================="
  echo "SimpleSSD Trace Replay Matrix: LRU vs LFU x WF_OFF vs WF_ON"
  echo "Output Directory: $OUTPUT_DIR"
  echo "=========================================================="
  echo ""

  # Compare LRU and LFU across demand and window fill
  # Capacities to test: 4MiB, 16MiB, 64MiB
  TEST_SIZES=( 4194304 16777216 67108864 )

  for sz in "${TEST_SIZES[@]}"; do
    for pol in 0 1; do
      for wf in false true; do
        run_trace_instance "$pol" "$wf" "$sz" "$IO_LIMIT"
      done
    done
  done

  echo "All trace experiment runs completed!"
  exit 0
fi

# Single run
run_trace_instance "$CMT_POLICY" "$WINDOW_FILL" "$CMT_BYTES" "$IO_LIMIT"
