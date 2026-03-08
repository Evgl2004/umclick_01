from channels.db import database_sync_to_async
from channels.generic.websocket import AsyncJsonWebsocketConsumer

from apps.session.models import LiveSession
from apps.session.realtime import build_public_session_state, session_group_name


class SessionConsumer(AsyncJsonWebsocketConsumer):
    session_id: int
    group_name: str

    async def connect(self):
        session_id_raw = self.scope.get("url_route", {}).get("kwargs", {}).get("session_id")
        try:
            self.session_id = int(session_id_raw)
        except (TypeError, ValueError):
            await self.close(code=4000)
            return

        session_exists = await database_sync_to_async(
            lambda: LiveSession.objects.filter(id=self.session_id).exists()
        )()
        if not session_exists:
            await self.close(code=4004)
            return

        self.group_name = session_group_name(self.session_id)
        await self.channel_layer.group_add(self.group_name, self.channel_name)
        await self.accept()

        payload = await database_sync_to_async(self._load_public_state)()
        await self.send_json(
            {
                "event": "session_state",
                "payload": payload,
            }
        )

    async def disconnect(self, close_code):
        if hasattr(self, "group_name"):
            await self.channel_layer.group_discard(self.group_name, self.channel_name)

    async def receive_json(self, content, **kwargs):
        await self.send_json(
            {
                "event": "info",
                "payload": {
                    "message": "WebSocket is read-only in this MVP.",
                },
            }
        )

    async def session_event(self, event):
        await self.send_json(
            {
                "event": event.get("event"),
                "payload": event.get("payload", {}),
            }
        )

    def _load_public_state(self) -> dict:
        session = (
            LiveSession.objects.select_related("current_question")
            .prefetch_related("current_question__choices", "participants")
            .get(id=self.session_id)
        )
        return build_public_session_state(session)
