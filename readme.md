# Immich backfill from Apple Photos (macOS)

**What this is:** A small macOS script for people who use **Immich** but still keep their master library in **Apple Photos**. You pick a **date range**; it exports photos (and XMP sidecars) with **osxphotos** in **batches**, then **uploads each batch to Immich** with the Immich CLI—so you can migrate or catch up history without one giant export that stalls Photos.

Export originals from the **Photos** library in date range chunks, then upload them with the **Immich CLI**. Chunking limits how many assets each `osxphotos export` touches, which helps avoid AppleScript timeouts on large months or under heavy load.

## Prerequisites

- macOS (the script uses BSD `date` and expects a `.photoslibrary` bundle).
- [osxphotos](https://github.com/RhetTbull/osxphotos) on your `PATH`.
- [Immich CLI](https://immich.app/docs/features/command-line-interface/) on your `PATH`, logged in so `immich server-info` works.
- `rsync` on your `PATH` (used when keeping merged exports under `export/archive/`).

Ensure originals are available locally (e.g. “Download Originals to this Mac”) for assets you export.

## Usage

From this repo directory (or use an absolute path to the script):

```bash
chmod +x ./backfill.sh   # once
./backfill.sh START_DATE END_DATE [BATCH_SIZE]
```

- **`START_DATE`** and **`END_DATE`** are `YYYY-MM-DD`.
- **`END_DATE` is exclusive**: the run includes assets created on or after `START_DATE` and **before** `END_DATE`.
- **`BATCH_SIZE`** (optional) is how many assets to process per export/upload cycle. Default is **250**. Lower values reduce load per batch (helpful if Photos or the machine struggles).

Examples:

```bash
# January 1 through April 30, 2026 (end May 1 is exclusive)
./backfill.sh 2026-01-01 2026-05-01

# Smaller batches
./backfill.sh 2026-01-01 2026-05-01 100
```

Dry run (no real export or upload, still runs query and chunked commands with `--dry-run` where supported):

```bash
DRY_RUN=1 ./backfill.sh 2026-01-01 2026-05-01
```

## Environment variables

Defaults assume this project lives at `$HOME/projects/immich-backfill`.

| Variable | Default | Role |
| -------- | ------- | ---- |
| `WORKDIR` | `$HOME/projects/immich-backfill` | Base for paths below |
| `PHOTOS_LIBRARY` | `$HOME/Pictures/Photos Library.photoslibrary` | Photos library to read |
| `EXPORT_ROOT` | `$WORKDIR/export` | Export and staging area |
| `LOG_ROOT` | `$WORKDIR/logs` | Logs and UUID manifest data |
| `CONCURRENCY` | `4` | Parallel uploads for `immich upload` |
| `BATCH_SIZE` | `250` | Chunk size if not passed as the third argument |
| `DRY_RUN` | `0` | Set to `1` to test without writing assets or uploading |
| `KEEP_EXPORTED_BATCHES` | `1` | Set to `0` to delete exports after upload instead of merging into `archive/` |

## What gets written where

- **Manifests**: `logs/manifests/<START>_to_<END>/` — full UUID list for the range, per-chunk UUID files, and related logs.
- **Staging**: `export/staging/batch-*****` — temporary per-chunk export trees (removed after each chunk completes). Files are laid out as **`year/month/`** under staging (from each photo’s creation date).
- **Archive** (when `KEEP_EXPORTED_BATCHES=1`): `export/archive/year/month/` — merged copy of exported files after each successful upload.
- **Per-chunk logs**: under `logs/`, including `osxphotos-*.log` / CSV reports and `immich-upload-*.log`.

## How a run is structured

1. Query Photos for all UUIDs in the date range.
2. Split that list into chunks of `BATCH_SIZE`.
3. For each chunk: export to staging → **uppercase file extensions** in staging → upload staging to Immich → remove staging → optionally merge into `export/archive/`.

This avoids uploading the same files again on the next chunk, because each upload targets only the current staging directory.
