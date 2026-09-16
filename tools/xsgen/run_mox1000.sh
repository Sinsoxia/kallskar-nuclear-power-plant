#!/usr/bin/env bash
# Kallskar xsgen: production MOX-1000 validation runs (about an hour per case on 16 threads), then the summary.
# Statistics: 400k particles × 200 active batches ≈ 8e7 histories → σ_k ≈ 10 pcm per state (scaled from a
# 4e5-history timing run with σ_k = 135 pcm). 60 inactive batches; the entropy check in --summarise confirms them.
set -euo pipefail
cd "$(dirname "$0")/../.."
MM="$HOME/.local/bin/micromamba"
LOG="/mnt/d/Roblox Projects/Kallinskar Nuclear Power Plant/xs-runs/mox1000"
mkdir -p "$LOG"
for case in nominal void doppler rods; do
    echo "=== $case $(date -Is)"
    "$MM" run -n kallskar-xs python -u -B tools/xsgen/mox1000_model.py --case "$case" \
        --particles 400000 --batches 260 --inactive 60 > "$LOG/$case.log" 2>&1
    grep -E "Combined k-effective|Total time elapsed" "$LOG/$case.log"
done
"$MM" run -n kallskar-xs python -u -B tools/xsgen/mox1000_model.py --summarise
echo "=== done $(date -Is)"
