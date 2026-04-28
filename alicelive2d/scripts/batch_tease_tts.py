#!/usr/bin/env python3
"""
Batch TTS generator for AliceChat Live2D tease audio files.
Uses the existing MiniMax TTS backend from the backend package.

Usage:
    python scripts/batch_tease_tts.py

Requirements:
    - Python 3.10+
    - All dependencies from backend/requirements.txt
    - Valid config.json with minimax-tts provider configured

Output:
    - Audio files: desktop/public/audio/tease/tease_XXX.mp3
    - Manifest:   scripts/tease_audio_manifest.json (input)
"""

from __future__ import annotations

import json
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# Add backend to path so we can import its modules
# __file__ = scripts/batch_tease_tts.py  =>  parent = scripts/  =>  go up to repo root
BACKEND_DIR = Path(__file__).resolve().parent.parent / "backend"
sys.path.insert(0, str(BACKEND_DIR))

from app.tts_backends import create_tts_backend
from app.config import get_tts_provider_config

# ── Configuration ──────────────────────────────────────────────────────────────

REPO_DIR = Path(__file__).resolve().parent.parent
MANIFEST_PATH = REPO_DIR / "scripts" / "tease_audio_manifest.json"
OUTPUT_DIR = REPO_DIR / "desktop" / "public" / "audio" / "tease"

PROVIDER_ID = "minimax-tts"
MAX_WORKERS = 1          # single-threaded to avoid MiniMax rate limiting
BATCH_DELAY = 1.5        # seconds between API calls to avoid rate limiting
RETRY_COUNT = 2
RETRY_DELAY = 5          # seconds before retry


def load_manifest(path: Path) -> list[dict]:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def get_backend(provider_id: str):
    """Create a TTS backend using the same config as the FastAPI app."""
    provider_cfg = get_tts_provider_config(provider_id)
    return create_tts_backend(provider_cfg, provider_id=provider_id)


def synthesize_one(entry: dict, backend, output_dir: Path) -> dict:
    """Synthesize a single audio file. Returns result dict."""
    entry_id = entry["id"]
    text = entry["text"]
    filename = f"{entry_id}.mp3"
    audio_path = output_dir / filename

    # Skip if already exists and is non-empty
    if audio_path.exists() and audio_path.stat().st_size > 100:
        return {
            "id": entry_id,
            "status": "skipped",
            "path": str(audio_path.relative_to(REPO_DIR)),
            "size": audio_path.stat().st_size,
        }

    for attempt in range(1, RETRY_COUNT + 1):
        try:
            audio_bytes, mime_type = backend.synthesize(text, overrides=None)

            # Ensure output format is mp3
            if not filename.endswith(".mp3"):
                filename = filename.rsplit(".", 1)[0] + ".mp3"
                audio_path = output_dir / filename

            audio_path.parent.mkdir(parents=True, exist_ok=True)
            audio_path.write_bytes(audio_bytes)

            return {
                "id": entry_id,
                "status": "ok",
                "path": str(audio_path.relative_to(REPO_DIR)),
                "size": len(audio_bytes),
                "mime": mime_type,
            }

        except Exception as exc:
            last_exc = exc
            if attempt < RETRY_COUNT:
                time.sleep(RETRY_DELAY)

    return {
        "id": entry_id,
        "status": "failed",
        "error": str(last_exc),
    }


def main():
    print(f"[batch_tease_tts] Starting batch TTS generation")
    print(f"[batch_tease_tts] Repo root: {REPO_DIR}")
    print(f"[batch_tease_tts] Output dir: {OUTPUT_DIR}")
    print(f"[batch_tease_tts] Manifest:   {MANIFEST_PATH}")

    # Validate manifest
    if not MANIFEST_PATH.exists():
        print(f"[batch_tease_tts] ERROR: Manifest not found: {MANIFEST_PATH}")
        sys.exit(1)

    manifest = load_manifest(MANIFEST_PATH)
    print(f"[batch_tease_tts] Loaded {len(manifest)} entries from manifest")

    # Create output directory
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)

    # Create backend (loads config automatically)
    try:
        backend = get_backend(PROVIDER_ID)
        print(f"[batch_tease_tts] TTS backend created: {PROVIDER_ID}")
    except Exception as exc:
        print(f"[batch_tease_tts] ERROR: Failed to create TTS backend: {exc}")
        traceback.print_exc()
        sys.exit(1)

    results = []
    ok_count = 0
    skip_count = 0
    fail_count = 0

    # Process with thread pool
    print(f"[batch_tease_tts] Processing with {MAX_WORKERS} workers...")

    with ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = {
            executor.submit(synthesize_one, entry, backend, OUTPUT_DIR): entry
            for entry in manifest
        }

        for future in as_completed(futures):
            entry = futures[future]
            try:
                result = future.result()
            except Exception as exc:
                result = {
                    "id": entry["id"],
                    "status": "failed",
                    "error": str(exc),
                }

            results.append(result)
            status = result["status"]

            if status == "ok":
                ok_count += 1
                print(f"  [OK]   {result['id']} -> {result['path']} ({result['size']} bytes)")
            elif status == "skipped":
                skip_count += 1
                print(f"  [SKIP] {result['id']} (already exists, {result['size']} bytes)")
            else:
                fail_count += 1
                print(f"  [FAIL] {result['id']}: {result.get('error', 'unknown error')}")

            # Small delay to avoid overwhelming the API
            time.sleep(BATCH_DELAY)

    # Summary
    total = len(manifest)
    print()
    print(f"[batch_tease_tts] ═══════════════════════════════════════")
    print(f"[batch_tease_tts] Done! Summary:")
    print(f"[batch_tease_tts]   Total entries:  {total}")
    print(f"[batch_tease_tts]   Generated (ok): {ok_count}")
    print(f"[batch_tease_tts]   Skipped:        {skip_count}")
    print(f"[batch_tease_tts]   Failed:         {fail_count}")
    print(f"[batch_tease_tts]   Output dir:     {OUTPUT_DIR}")

    # Write results report
    report_path = REPO_DIR / "scripts" / "tease_tts_report.json"
    report_path.write_text(json.dumps({
        "total": total,
        "ok": ok_count,
        "skipped": skip_count,
        "failed": fail_count,
        "results": results,
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[batch_tease_tts]   Report:         {report_path}")
    print(f"[batch_tease_tts] ═══════════════════════════════════════")

    if fail_count > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
