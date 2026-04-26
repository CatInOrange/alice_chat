from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from ..app_context import AppContext
from ..auth import verify_app_password


class PushRegisterRequest(BaseModel):
    userId: str = Field(default='alicechat-user')
    deviceId: str
    platform: str = Field(default='android')
    provider: str = Field(default='fcm')
    pushToken: str
    appVersion: str = Field(default='')
    deviceName: str = Field(default='')
    notificationEnabled: bool = Field(default=True)


class PushUnregisterRequest(BaseModel):
    deviceId: str
    pushToken: str = Field(default='')


class PushPresenceRequest(BaseModel):
    deviceId: str
    isForeground: bool = Field(default=False)
    activeSessionId: str = Field(default='')


class PushTestRequest(BaseModel):
    userId: str = Field(default='alicechat-user')
    sessionId: str
    title: str
    body: str
    messageId: str = Field(default='test_message')
    senderId: str = Field(default='system')
    senderName: str = Field(default='AliceChat')


def create_push_router(context: AppContext) -> APIRouter:
    router = APIRouter(dependencies=[Depends(verify_app_password)])

    @router.post('/api/push/register')
    async def register_push_device(payload: PushRegisterRequest) -> dict:
        try:
            device = context.push_service.register_device(
                user_id=payload.userId,
                device_id=payload.deviceId,
                platform=payload.platform,
                provider=payload.provider,
                push_token=payload.pushToken,
                app_version=payload.appVersion,
                device_name=payload.deviceName,
                notification_enabled=payload.notificationEnabled,
            )
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc
        return {'ok': True, 'device': device, 'pushEnabled': context.push_service.is_enabled()}

    @router.post('/api/push/unregister')
    async def unregister_push_device(payload: PushUnregisterRequest) -> dict:
        removed = context.push_service.unregister_device(
            device_id=payload.deviceId,
            push_token=payload.pushToken,
        )
        return {'ok': True, 'removed': removed}

    @router.post('/api/push/presence')
    async def update_push_presence(payload: PushPresenceRequest) -> dict:
        device = context.push_service.update_presence(
            device_id=payload.deviceId,
            is_foreground=payload.isForeground,
            active_session_id=payload.activeSessionId,
        )
        if not device:
            raise HTTPException(status_code=404, detail='device not found')
        return {'ok': True, 'device': device}

    @router.post('/api/push/test')
    async def test_push(payload: PushTestRequest) -> dict:
        results = context.push_service.notify_new_message(
            user_id=payload.userId,
            session_id=payload.sessionId,
            title=payload.title,
            body=payload.body,
            message_id=payload.messageId,
            sender_id=payload.senderId,
            sender_name=payload.senderName,
        )
        return {'ok': True, 'pushEnabled': context.push_service.is_enabled(), 'results': results}

    return router
