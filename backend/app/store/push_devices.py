from __future__ import annotations

import time
import uuid

from .db import DbConfig, connect, migrate


def _now() -> float:
    return time.time()


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


class PushDeviceStore:
    def __init__(self, db: DbConfig | None = None):
        self.db = db or DbConfig()

    def ensure_schema(self) -> None:
        with connect(self.db) as conn:
            migrate(conn)

    def _row_to_device(self, row) -> dict:
        return {
            'id': row['id'],
            'userId': row['user_id'],
            'deviceId': row['device_id'],
            'platform': row['platform'],
            'provider': row['provider'],
            'pushToken': row['push_token'],
            'appVersion': row['app_version'],
            'deviceName': row['device_name'],
            'notificationEnabled': bool(row['notification_enabled']),
            'lastSeenAt': row['last_seen_at'],
            'lastForegroundAt': row['last_foreground_at'],
            'activeSessionId': row['active_session_id'],
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
        }

    def upsert_device(
        self,
        *,
        user_id: str,
        device_id: str,
        platform: str,
        provider: str,
        push_token: str,
        app_version: str = '',
        device_name: str = '',
        notification_enabled: bool = True,
    ) -> dict:
        self.ensure_schema()
        now = _now()
        resolved_user_id = str(user_id or '').strip() or 'alicechat-user'
        resolved_device_id = str(device_id or '').strip()
        resolved_platform = str(platform or '').strip() or 'android'
        resolved_provider = str(provider or '').strip() or 'fcm'
        resolved_push_token = str(push_token or '').strip()
        resolved_app_version = str(app_version or '').strip()
        resolved_device_name = str(device_name or '').strip()
        if not resolved_device_id or not resolved_push_token:
            raise ValueError('deviceId and pushToken are required')

        with connect(self.db) as conn:
            row = conn.execute(
                'SELECT * FROM push_devices WHERE device_id=? LIMIT 1',
                (resolved_device_id,),
            ).fetchone()
            if row:
                conn.execute(
                    '''
                    UPDATE push_devices
                    SET user_id=?, platform=?, provider=?, push_token=?, app_version=?, device_name=?,
                        notification_enabled=?, last_seen_at=?, updated_at=?
                    WHERE device_id=?
                    ''',
                    (
                        resolved_user_id,
                        resolved_platform,
                        resolved_provider,
                        resolved_push_token,
                        resolved_app_version,
                        resolved_device_name,
                        1 if notification_enabled else 0,
                        now,
                        now,
                        resolved_device_id,
                    ),
                )
            else:
                conn.execute(
                    '''
                    INSERT INTO push_devices(
                        id, user_id, device_id, platform, provider, push_token, app_version, device_name,
                        notification_enabled, last_seen_at, last_foreground_at, active_session_id, created_at, updated_at
                    ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    ''',
                    (
                        _new_id('pdev'),
                        resolved_user_id,
                        resolved_device_id,
                        resolved_platform,
                        resolved_provider,
                        resolved_push_token,
                        resolved_app_version,
                        resolved_device_name,
                        1 if notification_enabled else 0,
                        now,
                        0.0,
                        '',
                        now,
                        now,
                    ),
                )
            conn.commit()
            saved = conn.execute(
                'SELECT * FROM push_devices WHERE device_id=? LIMIT 1',
                (resolved_device_id,),
            ).fetchone()
            return self._row_to_device(saved)

    def unregister_device(self, *, device_id: str, push_token: str = '') -> bool:
        self.ensure_schema()
        resolved_device_id = str(device_id or '').strip()
        resolved_push_token = str(push_token or '').strip()
        if not resolved_device_id:
            return False
        with connect(self.db) as conn:
            if resolved_push_token:
                cur = conn.execute(
                    'DELETE FROM push_devices WHERE device_id=? AND push_token=?',
                    (resolved_device_id, resolved_push_token),
                )
            else:
                cur = conn.execute('DELETE FROM push_devices WHERE device_id=?', (resolved_device_id,))
            conn.commit()
            return int(cur.rowcount or 0) > 0

    def update_presence(
        self,
        *,
        device_id: str,
        is_foreground: bool,
        active_session_id: str = '',
    ) -> dict | None:
        self.ensure_schema()
        resolved_device_id = str(device_id or '').strip()
        if not resolved_device_id:
            return None
        now = _now()
        with connect(self.db) as conn:
            row = conn.execute(
                'SELECT * FROM push_devices WHERE device_id=? LIMIT 1',
                (resolved_device_id,),
            ).fetchone()
            if not row:
                return None
            conn.execute(
                '''
                UPDATE push_devices
                SET last_seen_at=?, last_foreground_at=?, active_session_id=?, updated_at=?
                WHERE device_id=?
                ''',
                (
                    now,
                    now if is_foreground else float(row['last_foreground_at'] or 0.0),
                    str(active_session_id or '').strip(),
                    now,
                    resolved_device_id,
                ),
            )
            conn.commit()
            saved = conn.execute(
                'SELECT * FROM push_devices WHERE device_id=? LIMIT 1',
                (resolved_device_id,),
            ).fetchone()
            return self._row_to_device(saved)

    def list_user_devices(self, user_id: str, *, enabled_only: bool = True) -> list[dict]:
        self.ensure_schema()
        resolved_user_id = str(user_id or '').strip() or 'alicechat-user'
        sql = 'SELECT * FROM push_devices WHERE user_id=?'
        params = [resolved_user_id]
        if enabled_only:
            sql += ' AND notification_enabled=1'
        sql += ' ORDER BY updated_at DESC'
        with connect(self.db) as conn:
            rows = conn.execute(sql, tuple(params)).fetchall()
            return [self._row_to_device(row) for row in rows]
