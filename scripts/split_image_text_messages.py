from __future__ import annotations

import json
import sqlite3
import uuid
from pathlib import Path

DB_PATH = Path('/root/.openclaw/AliceChat/data/lunaria.sqlite3')


def main() -> None:
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()

    rows = cur.execute(
        '''
        select id, session_id, role, text, raw_text, meta, source, attachments_json, created_at
        from messages
        where role='assistant'
          and trim(coalesce(text, '')) != ''
          and trim(coalesce(attachments_json, '')) != ''
        order by created_at asc, id asc
        '''
    ).fetchall()

    scanned = 0
    updated = 0
    inserted = 0

    for row in rows:
        scanned += 1
        try:
            attachments = json.loads(row['attachments_json'] or '[]')
        except Exception:
            continue
        if not isinstance(attachments, list) or not attachments:
            continue

        has_image = False
        for item in attachments:
            if not isinstance(item, dict):
                continue
            kind = str(item.get('kind') or '').lower()
            mime = str(item.get('mimeType') or item.get('mime_type') or '').lower()
            if kind == 'image' or mime.startswith('image/'):
                has_image = True
                break
        if not has_image:
            continue

        text = str(row['text'] or '').strip()
        if not text:
            continue

        new_message_id = f"msg_{uuid.uuid4().hex[:12]}"
        new_created_at = float(row['created_at']) + 0.0001

        cur.execute(
            '''
            insert into messages(id, session_id, role, text, raw_text, meta, source, attachments_json, created_at)
            values(?,?,?,?,?,?,?,?,?)
            ''',
            (
                new_message_id,
                row['session_id'],
                row['role'],
                text,
                row['raw_text'] or '',
                row['meta'] or '',
                row['source'] or 'chat',
                '[]',
                new_created_at,
            ),
        )
        inserted += 1

        cur.execute(
            '''
            update messages
            set text='', raw_text=''
            where id=?
            ''',
            (row['id'],),
        )
        updated += 1

    conn.commit()
    conn.close()
    print(f'scanned={scanned} updated={updated} inserted={inserted}')


if __name__ == '__main__':
    main()
