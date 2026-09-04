from channels.db import database_sync_to_async
import asyncio
import uuid
from channels.generic.websocket import AsyncJsonWebsocketConsumer
from rest_framework_simplejwt.authentication import JWTAuthentication

from apps.core.permissions import can_manage_session
from apps.session.access import resolve_access
from apps.session.models import LiveSession
from apps.session.realtime import (
    build_account_session_state,
    build_display_session_state,
    build_participant_session_state,
    session_group_name,
)


class SessionConsumer(AsyncJsonWebsocketConsumer):
    auth_timeout = 10

    async def connect(self):
        try:
            self.session_uuid = uuid.UUID(str(self.scope['url_route']['kwargs']['session_uuid']))
        except (ValueError, KeyError, TypeError):
            await self.close(code=4000)
            return
        self.authorized = False
        await self.accept()
        self.deadline_task = asyncio.create_task(self._wait_for_auth())

    async def _wait_for_auth(self):
        await asyncio.sleep(self.auth_timeout)
        if not self.authorized:
            await self.close(code=4001)

    async def _watch_access(self):
        while True:
            await asyncio.sleep(1)
            if await database_sync_to_async(self._state_if_allowed)() is None:
                await self.close(code=4003)
                return

    async def disconnect(self, close_code):
        for name in ('deadline_task', 'access_task'):
            task = getattr(self, name, None)
            if task and task is not asyncio.current_task():
                task.cancel()
        if hasattr(self, 'group_name'):
            await self.channel_layer.group_discard(self.group_name, self.channel_name)

    async def receive(self, text_data=None, bytes_data=None, **kwargs):
        try:
            await super().receive(text_data=text_data, bytes_data=bytes_data, **kwargs)
        except (ValueError, TypeError):
            await self.close(code=4000)

    async def receive_json(self, content, **kwargs):
        if self.authorized or not isinstance(content, dict) or content.get('event') != 'auth':
            await self.close(code=4003)
            return
        self.access_type = content.get('access_type')
        self.secret = content.get('token')
        if self.access_type not in {'account', 'participant', 'display'} or not isinstance(self.secret, str):
            await self.close(code=4003)
            return
        state = await database_sync_to_async(self._state_if_allowed)()
        if state is None:
            await self.close(code=4003)
            return
        if self.deadline_task.done():
            await self.close(code=4001)
            return
        self.authorized = True
        self.deadline_task.cancel()
        self.group_name = session_group_name(self.session_id, self.access_type)
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        # После подписки перечитываем состояние, чтобы не потерять переход в промежутке.
        state = await database_sync_to_async(self._state_if_allowed)()
        if state is None:
            await self.close(code=4003)
            return
        await self.send_json({'event': 'session_state', 'schema_version': 2, 'payload': state})
        self.access_task = asyncio.create_task(self._watch_access())

    async def session_event(self, event):
        state = await database_sync_to_async(self._state_if_allowed)()
        if state is None:
            await self.close(code=4003)
            return
        await self.send_json({
            'event': event['event'],
            'schema_version': event.get('schema_version', 2),
            'payload': state,
        })

    def _state_if_allowed(self):
        from rest_framework.exceptions import APIException
        session = LiveSession.objects.select_related('quiz', 'current_question').filter(join_token=self.session_uuid).first()
        if session is None:
            return None
        try:
            if self.access_type == 'account':
                auth = JWTAuthentication()
                token = auth.get_validated_token(self.secret)
                if not can_manage_session(auth.get_user(token), session):
                    return None
            else:
                access = resolve_access(self.access_type, self.secret)
                if access.session_id != session.pk:
                    return None
        except (APIException, ValueError, TypeError):
            return None
        self.session_id = session.pk
        if self.access_type == 'display':
            return build_display_session_state(session)
        if self.access_type == 'participant':
            return build_participant_session_state(session, access.record_id)
        return build_account_session_state(session)
