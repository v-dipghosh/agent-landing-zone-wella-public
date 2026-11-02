"""Classic SSE serialization for runtime-neutral orchestration events."""

import base64
import json
from dataclasses import asdict
from typing import assert_never

from orchestration.turn import (
    TurnCancelledEvent,
    TurnCitationEvent,
    TurnConversationEvent,
    TurnErrorEvent,
    TurnEvaluationEvent,
    TurnOutputEvent,
    TurnTextEvent,
    TurnToolActivityEvent,
)


def serialize_turn_event(event: TurnOutputEvent) -> str | None:
    """Serialize a typed turn event to the existing classic SSE wire format."""
    if isinstance(event, TurnConversationEvent):
        return f"{event.conversation_id} "
    if isinstance(event, TurnTextEvent):
        return event.text
    if isinstance(event, TurnCitationEvent):
        return event.text or None
    if isinstance(event, TurnToolActivityEvent):
        return event.text or None
    if isinstance(event, TurnErrorEvent):
        return f"event: error\ndata: {event.message}\n\n"
    if isinstance(event, TurnCancelledEvent):
        return None
    if isinstance(event, TurnEvaluationEvent):
        payload = {"version": 1, **asdict(event)}
        encoded = base64.urlsafe_b64encode(
            json.dumps(payload, allow_nan=False).encode("utf-8")
        ).decode("ascii")
        return f"<<<GROUNDEDNESS_JSON>>>{encoded}<<<END_GROUNDEDNESS_JSON>>>"
    assert_never(event)
