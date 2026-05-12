#!/usr/bin/env bash
set -euo pipefail

# =========================
# Usage
# =========================
#
# ./backfill.sh START_DATE END_DATE
#
# END_DATE is exclusive.
#
# Example:
#   ./backfill.sh 2026-01-01 2026-05-01
#
# This exports Jan 1, 2026 through Apr 30, 2026.
#
# Optional environment (defaults shown):
#   WORKDIR              $HOME/projects/immich-backfill
#   PHOTOS_LIBRARY       $HOME/Pictures/Photos Library.photoslibrary
#   EXPORT_ROOT          $WORKDIR/export
#   LOG_ROOT             $WORKDIR/logs
#   CONCURRENCY          4
#   DRY_RUN              0
#   KEEP_EXPORTED_BATCHES 1

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 START_DATE END_DATE"
  echo
  echo "Example:"
  echo "  $0 2026-01-01 2026-05-01"
  echo
  echo "END_DATE is exclusive."
  exit 1
fi

START_DATE="$1"
END_DATE="$2"

# =========================
# Config
# =========================

WORKDIR="${WORKDIR:-$HOME/projects/immich-backfill}"
PHOTOS_LIBRARY="${PHOTOS_LIBRARY:-$HOME/Pictures/Photos Library.photoslibrary}"
EXPORT_ROOT="${EXPORT_ROOT:-$WORKDIR/export}"
LOG_ROOT="${LOG_ROOT:-$WORKDIR/logs}"
CONCURRENCY="${CONCURRENCY:-4}"

# Set to 1 for a no-op test.
DRY_RUN="${DRY_RUN:-0}"

# Set to 1 if you want to keep the exported batch after uploading.
KEEP_EXPORTED_BATCHES="${KEEP_EXPORTED_BATCHES:-1}"

# =========================
# Safety checks
# =========================

mkdir -p "$EXPORT_ROOT" "$LOG_ROOT"

command -v osxphotos >/dev/null 2>&1 || {
  echo "ERROR: osxphotos not found in PATH"
  exit 1
}

command -v immich >/dev/null 2>&1 || {
  echo "ERROR: immich CLI not found in PATH"
  exit 1
}

if [[ ! -d "$PHOTOS_LIBRARY" ]]; then
  echo "ERROR: Photos library not found or not a directory: $PHOTOS_LIBRARY"
  exit 1
fi

if ! date -j -f "%Y-%m-%d" "$START_DATE" "+%Y-%m-%d" >/dev/null 2>&1; then
  echo "ERROR: START_DATE must be YYYY-MM-DD. Got: $START_DATE"
  exit 1
fi

if ! date -j -f "%Y-%m-%d" "$END_DATE" "+%Y-%m-%d" >/dev/null 2>&1; then
  echo "ERROR: END_DATE must be YYYY-MM-DD. Got: $END_DATE"
  exit 1
fi

if [[ "$START_DATE" > "$END_DATE" || "$START_DATE" == "$END_DATE" ]]; then
  echo "ERROR: START_DATE must be before END_DATE"
  exit 1
fi

echo "Checking Immich CLI login..."
immich server-info >/dev/null

echo "Working dir: $WORKDIR"
echo "Photos lib:  $PHOTOS_LIBRARY"
echo "Export root: $EXPORT_ROOT"
echo "Date range:  $START_DATE to $END_DATE"
echo "Dry run:     $DRY_RUN"
echo

# =========================
# Helpers
# =========================

next_month() {
  date -j -v+1m -f "%Y-%m-%d" "$1" "+%Y-%m-%d"
}

date_part() {
  date -j -f "%Y-%m-%d" "$1" "$2"
}

run_osxphotos_export() {
  local batch_dir="$1" current="$2" next="$3" report="$4" export_log="$5"
  local dry=()
  [[ "$DRY_RUN" == "1" ]] && dry=(--dry-run)

  osxphotos export "$batch_dir" \
    --library "$PHOTOS_LIBRARY" \
    --from-date "$current" \
    --to-date "$next" \
    --skip-edited \
    --sidecar XMP \
    --touch-file \
    --directory "{created.year}/{created.mm}/{created.dd}" \
    --download-missing \
    --retry 3 \
    --report "$report" \
    --update \
    "${dry[@]}" \
    --verbose | tee "$export_log"
}

run_immich_upload() {
  local batch_dir="$1" upload_log="$2"
  local dry=()
  [[ "$DRY_RUN" == "1" ]] && dry=(--dry-run)

  immich upload \
    --recursive \
    --concurrency "$CONCURRENCY" \
    "${dry[@]}" \
    "$batch_dir" | tee "$upload_log"
}

# =========================
# Main loop
# =========================

current="$START_DATE"

while [[ "$current" < "$END_DATE" ]]; do
  next="$(next_month "$current")"

  # Clamp final batch to END_DATE
  if [[ "$next" > "$END_DATE" ]]; then
    next="$END_DATE"
  fi

  year="$(date_part "$current" "+%Y")"
  month="$(date_part "$current" "+%m")"

  batch_name="${year}-${month}"
  batch_dir="$EXPORT_ROOT/batches/$batch_name"
  report="$LOG_ROOT/osxphotos-$batch_name.csv"
  export_log="$LOG_ROOT/osxphotos-$batch_name.log"
  upload_log="$LOG_ROOT/immich-upload-$batch_name.log"

  mkdir -p "$batch_dir"

  echo "============================================================"
  echo "Batch: $batch_name"
  echo "From:  $current"
  echo "To:    $next"
  echo "Dir:   $batch_dir"
  echo "============================================================"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY RUN: osxphotos export"
  else
    echo "Exporting from Apple Photos..."
  fi
  run_osxphotos_export "$batch_dir" "$current" "$next" "$report" "$export_log"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY RUN: Immich upload"
  else
    echo "Uploading to Immich..."
  fi
  run_immich_upload "$batch_dir" "$upload_log"

  if [[ "$DRY_RUN" != "1" && "$KEEP_EXPORTED_BATCHES" == "0" ]]; then
    echo "Deleting exported batch after upload: $batch_dir"
    rm -rf "$batch_dir"
  elif [[ "$DRY_RUN" != "1" ]]; then
    echo "Keeping exported batch: $batch_dir"
  fi

  echo "Completed batch $batch_name"
  echo

  current="$next"
done

echo "Backfill complete."
