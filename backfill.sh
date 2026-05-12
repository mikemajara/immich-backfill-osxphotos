#!/usr/bin/env bash
set -euo pipefail

# =========================
# Usage
# =========================
#
# ./backfill.sh START_DATE END_DATE [BATCH_SIZE]
#
# END_DATE is exclusive. Assets are grouped into export/upload chunks of
# BATCH_SIZE (default 250) to limit AppleScript / Photos load.
#
# Example:
#   ./backfill.sh 2026-01-01 2026-05-01
#   ./backfill.sh 2026-01-01 2026-05-01 100
#
# Each chunk exports to a temporary staging folder, uploads to Immich, then
# staging is removed. With KEEP_EXPORTED_BATCHES=1, files merge into
# EXPORT_ROOT/archive/{year}/{month}/ (same layout as inside staging).
#
# Optional environment (defaults shown):
#   WORKDIR               $HOME/projects/immich-backfill
#   PHOTOS_LIBRARY        $HOME/Pictures/Photos Library.photoslibrary
#   EXPORT_ROOT           $WORKDIR/export
#   LOG_ROOT              $WORKDIR/logs
#   CONCURRENCY           4
#   BATCH_SIZE            250  (overridden by 3rd argument if present)
#   DRY_RUN               0
#   KEEP_EXPORTED_BATCHES 1
#
# After each export, file extensions in staging are uppercased (e.g. .jpg → .JPG)
# before upload so Immich sees normalized names. Uses a two-step rename on
# case-insensitive volumes when only the extension case changes.

if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "Usage: $0 START_DATE END_DATE [BATCH_SIZE]"
  echo
  echo "Example:"
  echo "  $0 2026-01-01 2026-05-01"
  echo "  $0 2026-01-01 2026-05-01 100"
  echo
  echo "END_DATE is exclusive."
  echo "BATCH_SIZE defaults to 250, or set BATCH_SIZE in the environment."
  exit 1
fi

START_DATE="$1"
END_DATE="$2"
BATCH_SIZE="${3:-${BATCH_SIZE:-250}}"

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

# Set to 1 if you want to keep merged exports under EXPORT_ROOT/archive after upload.
KEEP_EXPORTED_BATCHES="${KEEP_EXPORTED_BATCHES:-1}"

STAGING_ROOT="$EXPORT_ROOT/staging"
ARCHIVE_ROOT="$EXPORT_ROOT/archive"
MANIFEST_SCOPE="${START_DATE}_to_${END_DATE}"
MANIFEST_DIR="$LOG_ROOT/manifests/$MANIFEST_SCOPE"
MANIFEST_UUIDS="$MANIFEST_DIR/assets.uuids"
CHUNK_DIR="$MANIFEST_DIR/chunks"

# =========================
# Safety checks
# =========================

mkdir -p "$EXPORT_ROOT" "$LOG_ROOT" "$MANIFEST_DIR"

command -v osxphotos >/dev/null 2>&1 || {
  echo "ERROR: osxphotos not found in PATH"
  exit 1
}

command -v immich >/dev/null 2>&1 || {
  echo "ERROR: immich CLI not found in PATH"
  exit 1
}

command -v rsync >/dev/null 2>&1 || {
  echo "ERROR: rsync not found in PATH"
  exit 1
}

if [[ ! -d "$PHOTOS_LIBRARY" ]]; then
  echo "ERROR: Photos library not found or not a directory: $PHOTOS_LIBRARY"
  exit 1
fi

if ! [[ "$BATCH_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "ERROR: BATCH_SIZE must be a positive integer. Got: $BATCH_SIZE"
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

echo "Working dir:   $WORKDIR"
echo "Photos lib:    $PHOTOS_LIBRARY"
echo "Export root:   $EXPORT_ROOT"
echo "Staging root:  $STAGING_ROOT"
echo "Archive root:  $ARCHIVE_ROOT (when keeping exports)"
echo "Date range:    $START_DATE to $END_DATE (end exclusive)"
echo "Batch size:    $BATCH_SIZE assets per chunk"
echo "Manifest dir:  $MANIFEST_DIR"
echo "Dry run:       $DRY_RUN"
echo

# =========================
# Helpers
# =========================

build_uuid_manifest() {
  local manifest_log="$1"
  echo "Building UUID manifest (osxphotos query)..."
  osxphotos query \
    --library "$PHOTOS_LIBRARY" \
    --from-date "$START_DATE" \
    --to-date "$END_DATE" \
    --print "{uuid}" \
    --quiet | tee "$manifest_log" | sed '/^$/d' >"$MANIFEST_UUIDS.tmp"
  mv "$MANIFEST_UUIDS.tmp" "$MANIFEST_UUIDS"
}

split_manifest_into_chunks() {
  local manifest_file="$1"
  local chunk_dir="$2"
  local batch_size="$3"
  rm -rf "$chunk_dir"
  mkdir -p "$chunk_dir"
  local chunk_idx=0
  local count=0
  local chunk_file=""
  while IFS= read -r uuid || [[ -n "${uuid:-}" ]]; do
    [[ -z "$uuid" ]] && continue
    if (( count == 0 )); then
      chunk_idx=$((chunk_idx + 1))
      chunk_file=$(printf '%s/batch-%05d.uuids' "$chunk_dir" "$chunk_idx")
      : >"$chunk_file"
    fi
    printf '%s\n' "$uuid" >>"$chunk_file"
    count=$((count + 1))
    if (( count >= batch_size )); then
      count=0
    fi
  done <"$manifest_file"
}

run_osxphotos_export() {
  local batch_dir="$1"
  local uuid_file="$2"
  local report="$3"
  local export_log="$4"
  # Build argv in an array so we never expand an empty "${dry[@]}" under set -u.
  local -a cmd=(
    osxphotos export "$batch_dir"
    --library "$PHOTOS_LIBRARY"
    --uuid-from-file "$uuid_file"
    --skip-edited
    --sidecar XMP
    --touch-file
    --directory "{created.year}/{created.mm}"
    --download-missing
    --retry 3
    --report "$report"
    --update
  )
  [[ "$DRY_RUN" == "1" ]] && cmd+=(--dry-run)
  cmd+=(--verbose)

  "${cmd[@]}" | tee "$export_log"
}

# Uppercase the final extension of every file under root (e.g. foo.bar.jpg → foo.bar.JPG).
# On case-insensitive filesystems, mv foo.jpg foo.JPG needs an intermediate name.
uppercase_extensions_in_tree() {
  local root="$1"
  [[ -d "$root" ]] || return 0
  local path dir base name ext upper_ext new_path lpath lnew tmp
  while IFS= read -r path; do
    [[ -f "$path" ]] || continue
    base="$(basename "$path")"
    [[ "$base" == *.* ]] || continue
    name="${base%.*}"
    [[ -n "$name" ]] || continue
    ext="${base##*.}"
    upper_ext="$(printf '%s' "$ext" | tr '[:lower:]' '[:upper:]')"
    [[ "$ext" != "$upper_ext" ]] || continue
    dir="$(dirname "$path")"
    new_path="$dir/$name.$upper_ext"
    lpath="$(printf '%s' "$path" | tr '[:upper:]' '[:lower:]')"
    lnew="$(printf '%s' "$new_path" | tr '[:upper:]' '[:lower:]')"
    if [[ "$lpath" == "$lnew" ]]; then
      # Same path modulo case (common on case-insensitive APFS): two-step rename.
      tmp="${path}.__ext_upper__$$"
      mv "$path" "$tmp"
      mv "$tmp" "$new_path"
    elif [[ -e "$new_path" ]]; then
      echo "WARN: skipping extension rename, target exists: $new_path" >&2
      continue
    else
      mv "$path" "$new_path"
    fi
  done < <(find "$root" -type f)
}

run_immich_upload() {
  local batch_dir="$1"
  local upload_log="$2"
  local -a cmd=(
    immich upload
    --recursive
    --concurrency "$CONCURRENCY"
  )
  [[ "$DRY_RUN" == "1" ]] && cmd+=(--dry-run)
  cmd+=("$batch_dir")

  "${cmd[@]}" | tee "$upload_log"
}

# =========================
# Manifest + chunking
# =========================

manifest_query_log="$LOG_ROOT/osxphotos-manifest-$MANIFEST_SCOPE.log"
build_uuid_manifest "$manifest_query_log"

total_assets="$(wc -l <"$MANIFEST_UUIDS" | tr -d ' ')"
if [[ "$total_assets" -eq 0 ]]; then
  echo "No assets in range $START_DATE .. $END_DATE (exclusive). Nothing to do."
  exit 0
fi

split_manifest_into_chunks "$MANIFEST_UUIDS" "$CHUNK_DIR" "$BATCH_SIZE"

shopt -s nullglob
chunk_files=("$CHUNK_DIR"/batch-*.uuids)
shopt -u nullglob
total_batches="${#chunk_files[@]}"
if [[ "$total_batches" -eq 0 ]]; then
  echo "ERROR: No chunk files were produced."
  exit 1
fi

sorted_chunks=()
while IFS= read -r line; do
  [[ -n "$line" ]] && sorted_chunks+=("$line")
done < <(printf '%s\n' "${chunk_files[@]}" | sort -V)

echo "Assets: $total_assets  Chunks: $total_batches"
echo

# =========================
# Main loop (per chunk)
# =========================

batch_idx=0
for chunk_file in "${sorted_chunks[@]}"; do
  batch_idx=$((batch_idx + 1))
  chunk_base="$(basename "$chunk_file" .uuids)"
  staging_dir="$STAGING_ROOT/$chunk_base"
  report="$LOG_ROOT/osxphotos-$MANIFEST_SCOPE-$chunk_base.csv"
  export_log="$LOG_ROOT/osxphotos-$MANIFEST_SCOPE-$chunk_base.log"
  upload_log="$LOG_ROOT/immich-upload-$MANIFEST_SCOPE-$chunk_base.log"

  rm -rf "$staging_dir"
  mkdir -p "$staging_dir"

  echo "============================================================"
  echo "Chunk $batch_idx / $total_batches  ($chunk_base)"
  echo "UUID list: $chunk_file"
  echo "Staging:   $staging_dir"
  echo "============================================================"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY RUN: osxphotos export"
  else
    echo "Exporting from Apple Photos..."
  fi
  run_osxphotos_export "$staging_dir" "$chunk_file" "$report" "$export_log"

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY RUN: skip extension normalization (no staging changes)"
  else
    echo "Normalizing extensions to uppercase before upload..."
    uppercase_extensions_in_tree "$staging_dir"
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY RUN: Immich upload"
  else
    echo "Uploading to Immich..."
  fi
  run_immich_upload "$staging_dir" "$upload_log"

  if [[ "$DRY_RUN" != "1" ]]; then
    if [[ "$KEEP_EXPORTED_BATCHES" == "1" ]]; then
      echo "Merging into archive: $ARCHIVE_ROOT"
      mkdir -p "$ARCHIVE_ROOT"
      rsync -a "$staging_dir/" "$ARCHIVE_ROOT/"
    fi
    echo "Removing staging: $staging_dir"
    rm -rf "$staging_dir"
  fi

  echo "Completed chunk $chunk_base"
  echo
done

echo "Backfill complete."
