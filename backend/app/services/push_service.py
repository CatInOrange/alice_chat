from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from typing import Any

from ..store.push_devices import PushDeviceStore


class PushService:
    def __init__(self, devices: PushDeviceStore, config: dict | None = None):
        self.devices = devices
        self.config = config or {}

    def _push_config(self) -> dict:
        return ((self.config.get('push') or {}).get('fcm') or {})

    def is_enabled(self) -> bool:
        cfg = self._push_config()
        return bool(str(cfg.get('serverKey') or '').strip())

    def register_device(self, **kwargs) -> dict:
        return self.devices.upsert_device(**kwargs)

    def unregister_device(self, *, device_id: str, push_token: str = '') -> bool:
        return self.devices.unregister_device(device_id=device_id, push_token=push_token)

    def update_presence(self, *, device_id: str, is_foreground: bool, active_session_id: str = '') -> dict | None:
        return self.devices.update_presence(
            device_id=device_id,
            is_foreground=is_foreground,
            active_session_id=active_session_id,
        )

    def should_notify_device(self, device: dict, *, session_id: str) -> bool:
        if not device.get('notificationEnabled', True):
            return False
        active_session_id = str(device.get('activeSessionId') or '').strip()
        last_foreground_at = float(device.get('lastForegroundAt') or 0.0)
        if active_session_id and active_session_id == str(session_id or '').strip() and (time.time() - last_foreground_at) < 120:
            return False
        return True

    def build_payload(
        self,
        *,
        token: str,
        session_id: str,
        title: str,
        body: str,
        message_id: str,
        sender_id: str,
        sender_name: str,
    ) -> dict[str, Any]:
        preview = str(body or '').strip()
        if len(preview) > 96:
            preview = preview[:93] + '...'
        return {
            'to': token,
            'priority': 'high',
            'notification': {
                'title': title,
                'body': preview,
                'channel_id': 'chat_messages',
            },
            'data': {
                'type': 'chat_message',
                'sessionId': str(session_id or ''),
                'messageId': str(message_id or ''),
                'senderId': str(sender_id or ''),
                'senderName': str(sender_name or ''),
                'preview': preview,
            },
        }

    def send_payload(self, payload: dict[str, Any]) -> dict[str, Any]:
        cfg = self._push_config()
        server_key = str(cfg.get('serverKey') or '').strip()
        if not server_key:
            return {'ok': False, 'reason': 'missing_server_key'}

        endpoint = str(cfg.get('endpoint') or 'https://fcm.googleapis.com/fcm/send').strip()
        req = urllib.request.Request(
            endpoint,
            data=json.dumps(payload).encode('utf-8'),
            headers={
                'Content-Type': 'application/json',
                'Authorization': f'key={server_key}',
            },
            method='POST',
        )
        try:
            with urllib.request.urlopen(req, timeout=15) as resp:
                body = resp.read().decode('utf-8', errors='replace')
                return {
                    'ok': True,
                    'status': getattr(resp, 'status', 200),
                    'body': body,
                }
        except urllib.error.HTTPError as exc:
            body = exc.read().decode('utf-8', errors='replace')
            return {'ok': False, 'status': exc.code, 'body': body}
        except Exception as exc:  # noqa: BLE001
            return {'ok': False, 'reason': str(exc)}

    def notify_new_message(
        self,
        *,
        user_id: str,
        session_id: str,
        title: str,
        body: str,
        message_id: str,
        sender_id: str,
        sender_name: str,
    ) -> list[dict[str, Any]]:
        devices = self.devices.list_user_devices(user_id)
        results: list[dict[str, Any]] = []
        for device in devices:
            token = str(device.get('pushToken') or '').strip()
            if not token:
                continue
            if not self.should_notify_device(device, session_id=session_id):
                results.append({'ok': True, 'skipped': True, 'deviceId': device.get('deviceId'), 'reason': 'foreground_same_session'})
                continue
            payload = self.build_payload(
                token=token,
                session_id=session_id,
                title=title,
                body=body,
                message_id=message_id,
                sender_id=sender_id,
                sender_name=sender_name,
            )
            result = self.send_payload(payload)
            result['deviceId'] = device.get('deviceId')
            results.append(result)
        return results
