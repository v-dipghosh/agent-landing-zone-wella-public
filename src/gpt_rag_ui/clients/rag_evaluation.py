"""Incremental, bounded decoding of evaluation metadata in the classic stream."""

import base64
import binascii
import json
import logging
import math
from collections.abc import Callable
from typing import Literal, TypedDict

logger = logging.getLogger(__name__)
START_MARKER = "<<<GROUNDEDNESS_JSON>>>"
END_MARKER = "<<<END_GROUNDEDNESS_JSON>>>"
MAX_FRAME_CHARS = 128000


class RagMetric(TypedDict):
    metric: str
    status: Literal["success", "unavailable"]
    score: float | None
    reason: str


class RagEvaluation(TypedDict):
    version: int
    metrics: list[RagMetric]
    evidence_truncated: bool


class EvaluationProtocolError(ValueError):
    pass


def decode_evaluation(encoded: str) -> RagEvaluation:
    try:
        raw = json.loads(base64.b64decode(encoded, altchars=b"-_", validate=True))
    except (ValueError, UnicodeError, binascii.Error) as exc:
        raise EvaluationProtocolError("Malformed evaluation metadata.") from exc
    if (
        not isinstance(raw, dict)
        or type(raw.get("version")) is not int
        or raw["version"] != 1
        or not isinstance(raw.get("evidence_truncated"), bool)
        or not isinstance(raw.get("metrics"), list)
        or not 1 <= len(raw["metrics"]) <= 3
    ):
        raise EvaluationProtocolError("Unsupported evaluation payload.")
    metrics: list[RagMetric] = []
    seen: set[str] = set()
    for metric in raw["metrics"]:
        if not isinstance(metric, dict):
            raise EvaluationProtocolError("Invalid evaluation metric.")
        name, status = metric.get("metric"), metric.get("status")
        score, reason = metric.get("score"), metric.get("reason")
        if (
            not isinstance(name, str)
            or name not in {"groundedness", "retrieval", "relevance"}
            or name in seen
            or not isinstance(reason, str)
            or not reason.strip()
            or len(reason) > 4000
        ):
            raise EvaluationProtocolError("Invalid evaluation metric fields.")
        if status == "success":
            if (
                isinstance(score, bool)
                or not isinstance(score, (int, float))
                or not math.isfinite(score)
                or not 1 <= score <= 5
            ):
                raise EvaluationProtocolError("Invalid native evaluation score.")
            metrics.append({
                "metric": name, "status": "success",
                "score": float(score), "reason": reason,
            })
        elif status == "unavailable" and score is None:
            metrics.append({
                "metric": name, "status": "unavailable",
                "score": None, "reason": reason,
            })
        else:
            raise EvaluationProtocolError("Invalid evaluation status.")
        seen.add(name)
    return {
        "version": 1,
        "metrics": metrics,
        "evidence_truncated": raw["evidence_truncated"],
    }


class EvaluationStreamDecoder:
    def __init__(self, on_evaluation: Callable[[RagEvaluation], None] | None = None):
        self._on_evaluation = on_evaluation
        self._buffer = ""
        self._in_frame = False

    def feed(self, chunk: str) -> str:
        self._buffer += chunk
        text: list[str] = []
        while self._buffer:
            if self._in_frame:
                end = self._buffer.find(END_MARKER)
                if end < 0:
                    if len(self._buffer) > MAX_FRAME_CHARS:
                        raise EvaluationProtocolError("Evaluation frame is too large.")
                    break
                if end > MAX_FRAME_CHARS:
                    raise EvaluationProtocolError("Evaluation frame is too large.")
                payload = decode_evaluation(self._buffer[:end])
                self._buffer = self._buffer[end + len(END_MARKER):]
                self._in_frame = False
                if self._on_evaluation is not None:
                    self._on_evaluation(payload)
                continue
            start = self._buffer.find(START_MARKER)
            if start >= 0:
                text.append(self._buffer[:start])
                self._buffer = self._buffer[start + len(START_MARKER):]
                self._in_frame = True
                continue
            retained = 0
            for size in range(1, min(len(self._buffer), len(START_MARKER) - 1) + 1):
                if self._buffer.endswith(START_MARKER[:size]):
                    retained = size
            if retained:
                text.append(self._buffer[:-retained])
                self._buffer = self._buffer[-retained:]
            else:
                text.append(self._buffer)
                self._buffer = ""
            break
        return "".join(text)

    def finish(self) -> str:
        if self._in_frame:
            logger.error("Classic stream ended with incomplete RAG evaluation metadata")
            raise EvaluationProtocolError("Incomplete evaluation metadata.")
        remaining, self._buffer = self._buffer, ""
        return remaining
