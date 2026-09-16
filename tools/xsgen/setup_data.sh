#!/usr/bin/env bash
# Kallskar: unpack the OpenMC nuclear data onto D: (WSL path below).
#
# Why selective: ENDF/B-VIII.1 unpacks to 45.9 GB, of which 40.3 GB is thermal-scattering (S(a,b)) data that only
# matters for moderated (thermal) systems. A sodium fast reactor has no moderator, so only neutron (5.50 GB, all 558
# nuclides incl. fission products for depletion) and photon (0.19 GB) data are unpacked.
#
# Why D:: the WSL virtual disk lives on C:, which is nearly full (see memory/reference-wsl-openmc).
#
# Usage (from Windows):  wsl.exe -d Ubuntu -e bash "<repo>/tools/xsgen/setup_data.sh"
set -euo pipefail

DATA="/mnt/d/Roblox Projects/Kallinskar Nuclear Power Plant/nucdata"
SRC_DIR="$HOME/nucdata"
ARCHIVE="endfb81.tar.xz"
ARCHIVE_BYTES=9661406540
CHAIN="chain_endfb81_fast.xml"
CHAIN_BYTES=27532017
LOG="$DATA/setup_data.log"

mkdir -p "$DATA"
log() { echo "[$(date -Is)] $*" | tee -a "$LOG"; }

log "start; free on D: $(df -h --output=avail "$DATA" | tail -1)"

# Locate the archive (first run: WSL home; later runs: already on D:)
if [ -f "$SRC_DIR/$ARCHIVE" ]; then A="$SRC_DIR/$ARCHIVE"; elif [ -f "$DATA/$ARCHIVE" ]; then A="$DATA/$ARCHIVE"; else
  log "archive not found in $SRC_DIR or $DATA"; exit 1; fi
[ "$(stat -c %s "$A")" = "$ARCHIVE_BYTES" ] || { log "archive size mismatch: $(stat -c %s "$A")"; exit 1; }
log "archive OK at $A"

# Remove the corrupt partial extraction left by the failed 2026-09-16 run (it filled C: and went read-only)
if [ -d "$SRC_DIR/endfb81" ]; then
  log "removing partial extraction $SRC_DIR/endfb81 ($(du -sh "$SRC_DIR/endfb81" | cut -f1))"
  rm -rf "$SRC_DIR/endfb81"
fi

# Selective extraction straight to D:
if [ -f "$DATA/endfb-viii.1-hdf5/.extract_complete" ]; then
  log "extraction already complete, skipping"
else
  rm -rf "$DATA/endfb-viii.1-hdf5"
  log "extracting neutron + photon + cross_sections.xml (single-stream xz, several minutes)"
  tar -xf "$A" -I "xz -d" -C "$DATA" --exclude="endfb-viii.1-hdf5/thermal" --exclude="endfb-viii.1-hdf5/thermal/*"
  N=$(find "$DATA/endfb-viii.1-hdf5/neutron" -name '*.h5' | wc -l)
  G=$(find "$DATA/endfb-viii.1-hdf5/photon" -name '*.h5' | wc -l)
  log "extracted: $N neutron files (expect 557-558), $G photon files (expect ~100), $(du -sh "$DATA/endfb-viii.1-hdf5" | cut -f1)"
  [ "$N" -ge 550 ] || { log "too few neutron files"; exit 1; }
  touch "$DATA/endfb-viii.1-hdf5/.extract_complete"
fi

# Move the archive and chain off the C:-hosted WSL disk onto D: (move, not delete: re-extraction stays possible)
move_verified() {
  local f="$1" bytes="$2"
  if [ -f "$SRC_DIR/$f" ]; then
    log "moving $f to D:"
    cp "$SRC_DIR/$f" "$DATA/$f.part"
    [ "$(stat -c %s "$DATA/$f.part")" = "$bytes" ] || { log "copy size mismatch for $f"; exit 1; }
    mv "$DATA/$f.part" "$DATA/$f"
    rm -f "$SRC_DIR/$f"
  fi
  [ "$(stat -c %s "$DATA/$f")" = "$bytes" ] && log "$f on D: OK ($bytes bytes)"
}
move_verified "$CHAIN" "$CHAIN_BYTES"
move_verified "$ARCHIVE" "$ARCHIVE_BYTES"

log "done; free on D: $(df -h --output=avail "$DATA" | tail -1); WSL home nucdata: $(du -sh "$SRC_DIR" | cut -f1)"
