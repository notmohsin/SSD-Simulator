#!/usr/bin/env python3
"""stg_0 fields look like byte offset/length, not 512-byte LBAs."""
from __future__ import print_function

import os
import sys

TRACE = os.path.join(os.path.dirname(__file__), "..", "Traces", "stg_0.txt")


def parse_line(line):
    # blkparse-like: ... D Write <off> + <len>
    if " D Write " not in line and " D Read " not in line:
        return None
    parts = line.split()
    plus = parts.index("+")
    return int(parts[plus - 1]), int(parts[plus + 1])


def main():
    path = os.path.abspath(TRACE)
    if not os.path.isfile(path):
        print("SKIP: missing", path)
        return 0

    sizes = []
    with open(path, "r") as handle:
        for i, line in enumerate(handle):
            if i >= 20:
                break
            parsed = parse_line(line)
            if parsed:
                sizes.append(parsed[1])

    if not sizes:
        print("FAIL: no Write/Read lengths in first 20 lines")
        return 1

    # Byte interpretation: typical 512..16384. Sector×512 would be 256KiB..8MiB.
    if min(sizes) >= 256 * 1024:
        print("FAIL: lengths already look like expanded sectors", sizes[:5])
        return 1
    if max(sizes) > 1024 * 1024:
        print("FAIL: unexpected huge byte length", max(sizes))
        return 1

    lba_expanded = [s * 512 for s in sizes]
    if min(lba_expanded) < 256 * 1024:
        print("FAIL: LBA×512 should be hundreds of KiB", lba_expanded[:5])
        return 1

    print("test_trace_units: PASS (use ByteOffset/ByteLength, not LBA×512)")
    print("  sample lengths (bytes):", sizes[:8])
    return 0


if __name__ == "__main__":
    sys.exit(main())
