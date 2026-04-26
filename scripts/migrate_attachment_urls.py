from __future__ import annotations

import json
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from backend.app.media_utils import normalize_attachment_payload

DB_PATH = ROOT / 'data' / 'lunaria.sqlite3'


def main() -> None:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    updated = 0
    scanned = 0
    try:
        rows = conn.execute("SELECT id, attachments_json FROM messages").fetchall()
        for row in rows:
            scanned += 1
            raw_items = json.loads(row['attachments_json'] or '[]')
            if not isinstance(raw_items, list):
                continue
            normalized = []
            changed = False
            for item in raw_items:
                if not isinstance(item, dict):
                    normalized.append(item)
                    continue
                normalized_item = normalize_attachment_payload(item)
                normalized.append(normalized_item)
                if normalized_item != item:
                    changed = True
            if not changed:
                continue
            conn.execute(
                "UPDATE messages SET attachments_json=? WHERE id=?",
                (json.dumps(normalized, ensure_ascii=False), row['id']),
            )
            updated += 1
        conn.commit()
    finally:
        conn.close()
    print(f'scanned={scanned} updated={updated}')


if __name__ == '__main__':
    main()
