#!/usr/bin/env python3
"""Parse SimpleSSD output logs and summarize sweep results."""

import argparse
import csv
import re
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


def latency_to_us(value, unit):
    if unit == "ns":
        return value / 1000.0
    if unit == "ms":
        return value * 1000.0
    return value


def parse_log(path):
    row = parse_name(path)
    stats = {}
    latency_unit = ""
    latency_avg = None

    with path.open(encoding="utf-8", errors="ignore") as stream:
        for line in stream:
            # Fallback extraction from configuration section if filename was non-standard
            if not row["cmt"] and "CMT Capacity" in line:
                parts = line.split(":")
                if len(parts) >= 2:
                    try:
                        bytes_val = int(parts[1].replace("Bytes", "").strip())
                        if bytes_val >= 1048576:
                            row["cmt"] = f"{bytes_val // 1048576}MiB"
                        else:
                            row["cmt"] = f"{bytes_val // 1024}KiB"
                    except ValueError:
                        pass
            if not row["block_size"] and "Block Size" in line:
                parts = line.split(":")
                if len(parts) >= 2:
                    row["block_size"] = parts[1].strip()
            if not row["io_size"] and "IO Size" in line:
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
                latency_avg = float(match.group(2))

    row["latency_avg_us"] = (
        latency_to_us(latency_avg, latency_unit) if latency_avg is not None else ""
    )
    for metric in KEY_METRICS:
        row[metric] = stats.get(metric, "")
    return row


def mean(values):
    values = [float(value) for value in values if value != ""]
    return sum(values) / len(values) if values else 0.0


def print_summary(rows, limit):
    print(f"Parsed {len(rows)} result files")
    print()

    groups = {}
    for row in rows:
        key = (row["workload"], row["policy"], row["window_fill"])
        groups.setdefault(key, []).append(row)

    print("Average by workload / policy / window fill")
    for key in sorted(groups):
        group = groups[key]
        print(
            f"{key[0]:<8} {key[1]:<3} WF_{key[2]:<3} "
            f"lat={mean(row['latency_avg_us'] for row in group):8.2f} us "
            f"hit={mean(row['ftl.page_mapping.cmt.hit_rate'] for row in group):6.2f}% "
            f"pollution={mean(row['ftl.page_mapping.cmt.fill_waste_rate_percent'] for row in group):6.2f}%"
        )

    print()
    print(f"Lowest latency runs (top {limit})")
    ranked = [row for row in rows if row["latency_avg_us"] != ""]
    for row in sorted(ranked, key=lambda item: float(item["latency_avg_us"]))[:limit]:
        print(format_run(row))

    print()
    print(f"Highest latency runs (top {limit})")
    for row in sorted(ranked, key=lambda item: float(item["latency_avg_us"]), reverse=True)[
        :limit
    ]:
        print(format_run(row))


def format_run(row):
    mix = row["mix"] or "-"
    return (
        f"{float(row['latency_avg_us']):9.2f} us | "
        f"{row['workload']:<8} mix={mix:<3} {row['policy']:<3} WF_{row['window_fill']:<3} "
        f"cmt={row['cmt']:<6} io={row['io_size']:<3} "
        f"hit={float(row['ftl.page_mapping.cmt.hit_rate']):6.2f}% "
        f"file={row['file']}"
    )


def write_csv(rows, output):
    fieldnames = list(rows[0].keys()) if rows else []
    with output.open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "path",
        nargs="?",
        default="outputs/sweep_Aug28_12-55AM",
        type=Path,
        help="Directory containing SimpleSSD .txt result logs",
    )
    parser.add_argument("--csv", type=Path, help="Write parsed rows to this CSV path")
    parser.add_argument("--limit", type=int, default=10, help="Number of ranked runs to show")
    args = parser.parse_args()

    rows = [parse_log(path) for path in sorted(args.path.glob("*.txt"))]
    print_summary(rows, args.limit)
    if args.csv:
        write_csv(rows, args.csv)
        print()
        print(f"Wrote {args.csv}")


if __name__ == "__main__":
    main()
