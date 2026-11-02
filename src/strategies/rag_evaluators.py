"""Opt-in RAD Triad evaluation of a completed classic MAF Lite turn."""

import asyncio
import logging
import math
import threading
from collections.abc import Mapping
from concurrent.futures import ThreadPoolExecutor
from typing import Any, Protocol
from urllib.parse import urlparse

from azure.core.credentials import TokenCredential
from azure.core.exceptions import AzureError
from openai import OpenAIError

from orchestration.turn import RagMetricResult

logger = logging.getLogger(__name__)
_WORKERS = ThreadPoolExecutor(max_workers=3, thread_name_prefix="rag-evaluation")
_CAPACITY = threading.BoundedSemaphore(3)
_FLAGS = {
    "groundedness": "ENABLE_GROUNDEDNESS_EVALUATION",
    "retrieval": "ENABLE_RETRIEVAL_EVALUATION",
    "relevance": "ENABLE_RELEVANCE_EVALUATION",
}


class EvaluationConfig(Protocol):
    def get(self, key: str, default: Any = None, type: type = str) -> Any: ...


def _enabled(cfg: EvaluationConfig, key: str) -> bool:
    value = cfg.get(key, False, type=bool)
    if isinstance(value, bool):
        return value
    if isinstance(value, str) and value.strip().lower() in {"true", "false"}:
        return value.strip().lower() == "true"
    raise ValueError(f"{key} must be true or false")


def _unavailable(metric: str, reason: str) -> RagMetricResult:
    logger.warning("RAG evaluation unavailable: metric=%s reason=%s", metric, reason)
    return RagMetricResult(metric=metric, status="unavailable", reason=reason)


def _run_sdk(
    metric: str,
    model_config: dict[str, Any],
    credential: TokenCredential,
    reasoning: bool,
    query: str,
    response: str,
    context: str,
) -> Mapping[str, Any]:
    # The SDK is synchronous and expensive to import. Disabled turns never load it.
    from azure.ai.evaluation import (
        GroundednessEvaluator,
        RelevanceEvaluator,
        RetrievalEvaluator,
    )

    if metric == "groundedness":
        groundedness = GroundednessEvaluator(
            model_config=model_config, credential=credential, is_reasoning_model=reasoning
        )
        return groundedness(query=query, response=response, context=context)
    if metric == "retrieval":
        retrieval = RetrievalEvaluator(
            model_config=model_config, credential=credential, is_reasoning_model=reasoning
        )
        return retrieval(query=query, context=context)
    relevance = RelevanceEvaluator(
        model_config=model_config, credential=credential, is_reasoning_model=reasoning
    )
    return relevance(query=query, response=response)


def _validated_result(metric: str, raw: Mapping[str, Any]) -> RagMetricResult:
    # Prefer the SDK's current keys; older SDK outputs used a gpt_ prefix.
    if not isinstance(raw, Mapping):
        raise ValueError("Invalid evaluator output")
    score = raw.get(metric, raw.get(f"gpt_{metric}"))
    reason = raw.get(f"{metric}_reason", raw.get(f"gpt_{metric}_reason"))
    if (
        isinstance(score, bool)
        or not isinstance(score, (int, float))
        or not math.isfinite(score)
        or not 1 <= score <= 5
        or not isinstance(reason, str)
        or not reason.strip()
    ):
        raise ValueError("Invalid evaluator score or reason")
    return RagMetricResult(
        metric=metric,
        status="success",
        score=float(score),
        reason=reason[:4000],
    )


async def _evaluate_metric(
    metric: str,
    *,
    model_config: dict[str, Any],
    credential: TokenCredential,
    reasoning: bool,
    timeout: float,
    query: str,
    response: str,
    context: str,
) -> RagMetricResult:
    if not query.strip() or (metric != "retrieval" and not response.strip()):
        return _unavailable(metric, "Missing question or answer.")
    if metric != "relevance" and not context.strip():
        return _unavailable(metric, "No retrieved evidence was supplied for this turn.")
    if not _CAPACITY.acquire(blocking=False):
        return _unavailable(metric, "Evaluation capacity is busy. Try a later turn.")
    try:
        future = _WORKERS.submit(
            _run_sdk, metric, model_config, credential, reasoning, query, response, context
        )
    except RuntimeError:
        _CAPACITY.release()
        return _unavailable(metric, "Evaluation workers are unavailable.")
    # A timeout/cancellation cannot stop synchronous SDK work. Do not release
    # capacity until that work actually exits, or timed-out requests accumulate.
    future.add_done_callback(lambda _: _CAPACITY.release())
    wrapped = asyncio.wrap_future(future)
    try:
        raw = await asyncio.wait_for(asyncio.shield(wrapped), timeout=timeout)
        return _validated_result(metric, raw)
    except TimeoutError:
        # Consume late failures without exporting SDK details or leaking task warnings.
        wrapped.add_done_callback(
            lambda done: done.exception() if not done.cancelled() else None
        )
        return _unavailable(metric, "Evaluation timed out.")
    except asyncio.CancelledError:
        wrapped.add_done_callback(
            lambda done: done.exception() if not done.cancelled() else None
        )
        raise
    except (AzureError, OpenAIError, ValueError, TypeError, RuntimeError, ImportError) as exc:
        # SDK/provider exceptions may contain the evidence, answer or credentials.
        logger.warning(
            "RAG SDK evaluation failed: metric=%s exception_type=%s",
            metric, type(exc).__name__,
        )
        return _unavailable(metric, "The evaluator did not return a valid result.")


async def evaluate_rag_triad(
    cfg: EvaluationConfig,
    credential: TokenCredential,
    *,
    query: str,
    response: str,
    context: str,
) -> tuple[tuple[RagMetricResult, ...], bool]:
    """Return enabled metrics and whether the judge evidence was truncated."""
    try:
        if not _enabled(cfg, "EVALUATORS_ENABLED"):
            return (), False
    except ValueError:
        return tuple(
            _unavailable(metric, "Evaluator enablement configuration is invalid.")
            for metric in _FLAGS
        ), False
    metrics: list[str] = []
    invalid: list[RagMetricResult] = []
    for metric, flag in _FLAGS.items():
        try:
            if _enabled(cfg, flag):
                metrics.append(metric)
        except ValueError:
            invalid.append(_unavailable(metric, "Evaluator enablement configuration is invalid."))
    if not metrics:
        return tuple(invalid), False
    try:
        endpoint = str(
            cfg.get("EVALUATOR_AZURE_ENDPOINT", "")
            or cfg.get("AI_FOUNDRY_ACCOUNT_ENDPOINT", "")
        ).strip()
        deployment = str(
            cfg.get("EVALUATOR_MODEL", "") or cfg.get("CHAT_DEPLOYMENT_NAME", "")
        ).strip()
        parsed = urlparse(endpoint)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Invalid evaluator endpoint")
        if not deployment:
            raise ValueError("Missing evaluator deployment")
        timeout = float(cfg.get("EVALUATOR_TIMEOUT_SECONDS", 60))
        limit = int(cfg.get("EVALUATOR_MAX_EVIDENCE_CHARS", 24000))
        if not math.isfinite(timeout) or not 0 < timeout <= 300 or not 1 <= limit <= 100000:
            raise ValueError("Invalid evaluator limits")
        reasoning = _enabled(cfg, "EVALUATOR_IS_REASONING_MODEL")
        model_config = {
            "azure_endpoint": endpoint,
            "azure_deployment": deployment,
            "api_version": cfg.get("OPENAI_API_VERSION", "2025-04-01-preview"),
        }
    except (TypeError, ValueError, OverflowError):
        return tuple(invalid) + tuple(
            _unavailable(metric, "Evaluator configuration is invalid.") for metric in metrics
        ), False
    truncated = len(context) > limit
    results = await asyncio.gather(*(
        _evaluate_metric(
            metric,
            model_config=model_config,
            credential=credential,
            reasoning=reasoning,
            timeout=timeout,
            query=query,
            response=response,
            context=context[:limit],
        )
        for metric in metrics
    ))
    return tuple(results) + tuple(invalid), truncated
