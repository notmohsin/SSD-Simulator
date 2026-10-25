#!/usr/bin/env bash
# =============================================================================
# download_traces.sh — Fetch the MSR Cambridge IO traces used in this study
#
# The trace file (Traces/stg_0.txt) is 131 MB and is NOT stored in git.
# Run this script once to download it before running any simulations.
#
# SOURCE
#   MSR Cambridge Block I/O Traces (2007)
#   https://iotta.snia.org/traces/388
#   Specifically: stg_0.trace (storage server, first volume)
#
# USAGE
#   bash Traces/download_traces.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TRACE_FILE="$SCRIPT_DIR/stg_0.txt"

if [[ -f "$TRACE_FILE" ]]; then
  echo "Trace already exists: $TRACE_FILE"
  exit 0
fi

echo "The MSR Cambridge traces must be downloaded manually from SNIA IOTTA:"
echo ""
echo "  1. Go to: https://iotta.snia.org/traces/388"
echo "  2. Download 'MSR-Cambridge-2.tar.gz' (requires free account registration)"
echo "  3. Extract and locate 'stg_0.csv' or 'stg_0.trace'"
echo "  4. Convert/copy the file to: $TRACE_FILE"
echo ""
echo "Alternatively, if you have the file locally, copy it here:"
echo "  cp /path/to/stg_0.txt $TRACE_FILE"
echo ""
echo "The file should be ~131 MB. Its SHA-256 (for verification):"
echo "  (Run: sha256sum Traces/stg_0.txt  after copying)"
