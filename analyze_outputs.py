#!/usr/bin/env python3
"""Parse SimpleSSD output logs and summarize sweep results."""

import argparse
import csv
import json
import re
import sys
from pathlib import Path


LATENCY_RE = re.compile(r"Latency \(([^)]+)\): .*avg=([0-9.]+)")
DIM_RE = re.compile(r"_([0-9]+(?:KiB|MiB|GiB))_([0-9]+[KMG])_([0-9]+[KMG])_fill([0-9.]+)")
MIX_RE = re.compile(r"mix([0-9.]+)")

KEY_METRICS = (
    "ftl.page_mapping.cmt.hit_rate",
    "ftl.page_mapping.cmt.hits",
    "ftl.page_mapping.cmt.misses",
    "ftl.page_mapping.cmt.evictions",
    "ftl.page_mapping.cmt.dirty_evictions",
    "ftl.page_mapping.cmt.writebacks",
    "ftl.page_mapping.cmt.fill_insertions",
    "ftl.page_mapping.cmt.fill_hits",
    "ftl.page_mapping.cmt.fill_evicted_unused",
    "ftl.page_mapping.cmt.fill_accuracy_percent",
    "ftl.page_mapping.cmt.fill_waste_rate_percent",
    "ftl.page_mapping.cmt.fill_coverage_percent",
    "ftl.page_mapping.cmt.fill_avg_batch_size",
    "pal.energy.total",
    "dram.energy",
    "request_count",
    "bytes",
)


def to_float(val):
    if val is None or val == "" or val == "N/A":
        return None
    try:
        return float(val)
    except (ValueError, TypeError):
        return None


def format_bytes(bytes_val):
    try:
        b = int(bytes_val)
        if b >= 1048576:
            return f"{b // 1048576}MiB"
        elif b >= 1024:
            return f"{b // 1024}KiB"
        return f"{b}B"
    except (ValueError, TypeError):
        return str(bytes_val) if bytes_val is not None else ""


def parse_name(path):
    name = path.stem
    workload = name.split("_", 1)[0]
    mix = ""
    if workload.startswith("randrw"):
        match = MIX_RE.search(workload)
        mix = match.group(1) if match else ""
        workload = "randrw"

    dim_match = DIM_RE.search(name)

    return {
        "file": path.name,
        "workload": workload,
        "mix": mix,
        "policy": "LFU" if "_LFU_" in name else "LRU" if "_LRU_" in name else "",
        "window_fill": "ON" if "_WF_ON_" in name else "OFF" if "_WF_OFF_" in name else "",
        "cmt": dim_match.group(1) if dim_match else "",
        "block_size": dim_match.group(2) if dim_match else "",
        "io_size": dim_match.group(3) if dim_match else "",
    }


def read_metadata(path):
    """Attempt to load metadata JSON for a run log."""
    candidates = [
        path.with_suffix(".meta.json"),
        path.with_name(f"{path.stem}.meta.json"),
        path.with_name(f"{path.stem}.json"),
        path.parent / "run_metadata.json",
    ]
    for c in candidates:
        if c.is_file():
            try:
                with c.open(encoding="utf-8") as f:
                    data = json.load(f)
                    if isinstance(data, dict):
                        return data
            except (json.JSONDecodeError, OSError):
                pass
    return None


def latency_to_us(value, unit):
    if value is None:
        return None
    if unit == "ns":
        return value / 1000.0
    if unit == "ms":
        return value * 1000.0
    return value


def parse_log(path):
    meta = read_metadata(path)
    row = parse_name(path)

    if meta:
        if "workload" in meta and meta["workload"]:
            row["workload"] = meta["workload"]
        if "rw_mix_read" in meta:
            row["mix"] = str(meta["rw_mix_read"])
        if "cmt_policy" in meta:
            pol = meta["cmt_policy"]
            row["policy"] = "LFU" if str(pol) in ("1", "LFU") else "LRU"
        if "window_fill" in meta:
            wf = meta["window_fill"]
            row["window_fill"] = "ON" if str(wf).lower() in ("true", "1", "on") else "OFF"
        if "cmt_bytes" in meta:
            row["cmt"] = format_bytes(meta["cmt_bytes"])
        if "block_size" in meta and meta["block_size"]:
            row["block_size"] = str(meta["block_size"])
        if "io_size" in meta and meta["io_size"]:
            row["io_size"] = str(meta["io_size"])
        if "warmup_seed" in meta:
            row["warmup_seed"] = str(meta["warmup_seed"])
        if "status" in meta:
            row["status"] = str(meta["status"])
        if "start_time" in meta:
            row["start_time"] = str(meta["start_time"])
        if "duration" in meta:
            row["duration"] = str(meta["duration"])
        elif "wall_secs" in meta:
            row["duration"] = f"{meta['wall_secs']}s"
        if "git_commit" in meta:
            row["git_commit"] = str(meta["git_commit"])

    stats = {}
    latency_unit = ""
    latency_avg = None

    with path.open(encoding="utf-8", errors="ignore") as stream:
        for line in stream:
            # Fallback extraction from configuration section if filename was non-standard
            if not row.get("cmt") and "CMT Capacity" in line:
                parts = line.split(":")
                if len(parts) >= 2:
                    try:
                        bytes_val = int(parts[1].replace("Bytes", "").strip())
                        row["cmt"] = format_bytes(bytes_val)
                    except ValueError:
                        pass
            if not row.get("block_size") and "Block Size" in line:
                parts = line.split(":")
                if len(parts) >= 2:
                    row["block_size"] = parts[1].strip()
            if not row.get("io_size") and "IO Size" in line:
                parts = line.split(":")
                if len(parts) >= 2:
                    row["io_size"] = parts[1].strip()

            fields = line.split()
            if len(fields) >= 2:
                try:
                    stats[fields[0]] = float(fields[1])
                except ValueError:
                    pass

            match = LATENCY_RE.search(line)
            if match:
                latency_unit = match.group(1)
                try:
                    latency_avg = float(match.group(2))
                except ValueError:
                    latency_avg = None

    lat_us = latency_to_us(latency_avg, latency_unit)
    row["latency_avg_us"] = lat_us if lat_us is not None else ""
    for metric in KEY_METRICS:
        row[metric] = stats.get(metric, "")
    return row


def mean(values):
    nums = []
    for val in values:
        f = to_float(val)
        if f is not None:
            nums.append(f)
    return sum(nums) / len(nums) if nums else 0.0


def print_summary(rows, limit):
    if not rows:
        print("No results to summarize.")
        return

    print(f"Parsed {len(rows)} result files")
    print()

    groups = {}
    for row in rows:
        key = (row.get("workload", "unknown"), row.get("policy", ""), row.get("window_fill", ""))
        groups.setdefault(key, []).append(row)

    print("Average by workload / policy / window fill")
    for key in sorted(groups):
        group = groups[key]
        lat_m = mean(row.get("latency_avg_us") for row in group)
        hit_m = mean(row.get("ftl.page_mapping.cmt.hit_rate") for row in group)
        poll_m = mean(row.get("ftl.page_mapping.cmt.fill_waste_rate_percent") for row in group)
        print(
            f"{key[0]:<8} {key[1]:<3} WF_{key[2]:<3} "
            f"lat={lat_m:8.2f} us "
            f"hit={hit_m:6.2f}% "
            f"pollution={poll_m:6.2f}%"
        )

    ranked = [row for row in rows if to_float(row.get("latency_avg_us")) is not None]
    if ranked:
        print()
        print(f"Lowest latency runs (top {min(limit, len(ranked))})")
        for row in sorted(ranked, key=lambda item: to_float(item["latency_avg_us"]))[:limit]:
            print(format_run(row))

        print()
        print(f"Highest latency runs (top {min(limit, len(ranked))})")
        for row in sorted(
            ranked, key=lambda item: to_float(item["latency_avg_us"]), reverse=True
        )[:limit]:
            print(format_run(row))
    else:
        print("\nNo runs with valid latency data found.")


def format_run(row):
    lat = to_float(row.get("latency_avg_us"))
    lat_str = f"{lat:9.2f} us" if lat is not None else "      N/A"
    hr = to_float(row.get("ftl.page_mapping.cmt.hit_rate"))
    hr_str = f"{hr:6.2f}%" if hr is not None else "   N/A"
    mix = row.get("mix") or "-"
    return (
        f"{lat_str} | "
        f"{row.get('workload', '-'):<8} mix={mix:<3} {row.get('policy', '-'):<3} WF_{row.get('window_fill', '-'):<3} "
        f"cmt={row.get('cmt', '-'):<6} io={row.get('io_size', '-'):<3} "
        f"hit={hr_str} "
        f"file={row.get('file', '')}"
    )


def write_csv(rows, output):
    if not rows:
        print("No rows to write to CSV.")
        return
    fieldnames = list(rows[0].keys())
    with output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        default="outputs",
        type=Path,
        help="Directory or file containing SimpleSSD .txt result logs (default: outputs)",
    )
    parser.add_argument("--csv", type=Path, help="Write parsed rows to this CSV path")
    parser.add_argument("--limit", type=int, default=10, help="Number of ranked runs to show")
    args = parser.parse_args()

    target_path = args.path
    if not target_path.exists():
        print(f"Error: Path '{target_path}' does not exist.")
        return 1

    log_files = []
    if target_path.is_file():
        log_files = [target_path]
    elif target_path.is_dir():
        log_files = [p for p in target_path.glob("*.txt") if p.name != "sweep_summary.txt"]
        if not log_files:
            sweeps = sorted(
                [d for d in target_path.glob("sweep_*") if d.is_dir()],
                key=lambda d: d.stat().st_mtime,
                reverse=True,
            )
            if sweeps:
                print(
                    f"No .txt logs directly in '{target_path}'. Using latest sweep directory: '{sweeps[0]}'"
                )
                log_files = [p for p in sweeps[0].glob("*.txt") if p.name != "sweep_summary.txt"]
            else:
                log_files = [p for p in target_path.rglob("*.txt") if p.name != "sweep_summary.txt"]

    if not log_files:
        print(f"No result logs found in '{target_path}'.")
        return 0

    rows = [parse_log(path) for path in sorted(log_files)]
    print_summary(rows, args.limit)
    if args.csv:
        write_csv(rows, args.csv)
        print()
        print(f"Wrote {args.csv}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
