"""RAD Triad contracts with deterministic SDK and retrieval boundaries."""

import asyncio
import base64
import json
import threading
from types import SimpleNamespace
from unittest.mock import AsyncMock, MagicMock, Mock, patch

import pytest

from api.turn_sse import serialize_turn_event
from orchestration.turn import RagMetricResult, TurnEvaluationEvent
from strategies import rag_evaluators as rag


def config(**overrides):
    settings = {
        "EVALUATORS_ENABLED": True,
        "ENABLE_GROUNDEDNESS_EVALUATION": True,
        "ENABLE_RETRIEVAL_EVALUATION": True,
        "ENABLE_RELEVANCE_EVALUATION": True,
        "AI_FOUNDRY_ACCOUNT_ENDPOINT": "https://judge.openai.azure.com",
        "CHAT_DEPLOYMENT_NAME": "judge-deployment",
    }
    settings.update(overrides)
    cfg = Mock()
    cfg.get.side_effect = lambda key, default=None, type=str: settings.get(key, default)
    return cfg


async def evaluate(cfg=None):
    return await rag.evaluate_rag_triad(
        cfg or config(), Mock(), query="Question", response="Answer", context="Evidence"
    )


@pytest.mark.parametrize("master", [False, "false"])
async def test_master_disabled_makes_no_sdk_calls(master):
    with patch.object(rag, "_run_sdk") as sdk:
        assert await evaluate(config(EVALUATORS_ENABLED=master)) == ((), False)
    sdk.assert_not_called()


async def test_absent_flags_are_disabled():
    cfg = Mock()
    cfg.get.side_effect = lambda key, default=None, type=str: default
    with patch.object(rag, "_run_sdk") as sdk:
        assert await evaluate(cfg) == ((), False)
    sdk.assert_not_called()


@pytest.mark.parametrize("metric", ["groundedness", "retrieval", "relevance"])
async def test_independent_metric_flags_and_sdk_input(metric):
    flags = {flag: name == metric for name, flag in rag._FLAGS.items()}
    with patch.object(rag, "_run_sdk", return_value={
        metric: 4, f"{metric}_reason": "A native SDK explanation.",
    }) as sdk:
        results, truncated = await evaluate(config(**flags))
    assert results == (RagMetricResult(metric, "success", "A native SDK explanation.", 4.0),)
    assert truncated is False
    assert sdk.call_args.args[0] == metric
    assert sdk.call_args.args[4:] == ("Question", "Answer", "Evidence")


@pytest.mark.parametrize("metric", ["groundedness", "retrieval", "relevance"])
def test_sdk_wrapper_uses_official_evaluator_and_correct_arguments(metric):
    from azure.ai import evaluation

    classes = {
        "groundedness": "GroundednessEvaluator",
        "retrieval": "RetrievalEvaluator",
        "relevance": "RelevanceEvaluator",
    }
    credential = Mock()
    model = {"azure_endpoint": "https://judge.openai.azure.com", "azure_deployment": "judge"}
    with patch.object(evaluation, classes[metric]) as evaluator:
        rag._run_sdk(metric, model, credential, True, "Q", "A", "C")
    evaluator.assert_called_once_with(
        model_config=model, credential=credential, is_reasoning_model=True
    )
    expected = {"query": "Q"}
    if metric != "retrieval":
        expected["response"] = "A"
    if metric != "relevance":
        expected["context"] = "C"
    evaluator.return_value.assert_called_once_with(**expected)


def test_real_sdk_constructors_accept_token_credentials_without_network():
    from azure.ai.evaluation import GroundednessEvaluator, RetrievalEvaluator, RelevanceEvaluator

    model = {
        "azure_endpoint": "https://judge.openai.azure.com",
        "azure_deployment": "judge",
        "api_version": "2025-04-01-preview",
    }
    for evaluator in (GroundednessEvaluator, RetrievalEvaluator, RelevanceEvaluator):
        evaluator(model_config=model, credential=Mock(), is_reasoning_model=True)


@pytest.mark.parametrize("score", [1, 2.5, 5])
def test_native_scores_are_not_rescaled(score):
    result = rag._validated_result("retrieval", {
        "retrieval": score, "retrieval_reason": "Reason",
        "gpt_retrieval": 1,
    })
    assert result.score == score


@pytest.mark.parametrize("score", [None, True, "4", 0, 6, float("nan"), float("inf")])
def test_invalid_scores_are_rejected(score):
    with pytest.raises(ValueError):
        rag._validated_result("groundedness", {
            "groundedness": score, "groundedness_reason": "Reason",
        })


def test_legacy_sdk_output_keys_are_supported():
    result = rag._validated_result("relevance", {
        "gpt_relevance": 3, "gpt_relevance_reason": "Reason",
    })
    assert result.score == 3


async def test_missing_evidence_only_prevents_evidence_based_metrics():
    with patch.object(rag, "_run_sdk", return_value={
        "relevance": 5, "relevance_reason": "On topic.",
    }) as sdk:
        results, _ = await rag.evaluate_rag_triad(
            config(), Mock(), query="Hello", response="Hello!", context=""
        )
    assert [r.status for r in results] == ["unavailable", "unavailable", "success"]
    assert sdk.call_count == 1
    assert sdk.call_args.args[0] == "relevance"


async def test_independent_failures_are_safe_and_do_not_hide_success(caplog):
    def run(metric, *args):
        if metric == "groundedness":
            raise RuntimeError("private-evidence-and-token")
        return {metric: 4, f"{metric}_reason": "Reason"}

    with patch.object(rag, "_run_sdk", side_effect=run):
        results, _ = await evaluate()
    assert [r.status for r in results] == ["unavailable", "success", "success"]
    assert results[0].score is None
    assert "private-evidence-and-token" not in caplog.text
    assert "RuntimeError" in caplog.text


@pytest.mark.parametrize("overrides", [
    {"EVALUATOR_TIMEOUT_SECONDS": "nan"},
    {"EVALUATOR_TIMEOUT_SECONDS": 0},
    {"EVALUATOR_TIMEOUT_SECONDS": 301},
    {"EVALUATOR_MAX_EVIDENCE_CHARS": 0},
    {"EVALUATOR_MAX_EVIDENCE_CHARS": 100001},
    {"EVALUATOR_AZURE_ENDPOINT": "http://judge.example.com"},
    {"EVALUATOR_IS_REASONING_MODEL": "not-a-bool"},
    {"EVALUATORS_ENABLED": "not-a-bool"},
])
async def test_invalid_configuration_is_unavailable_not_fake_scores(overrides):
    with patch.object(rag, "_run_sdk") as sdk:
        results, _ = await evaluate(config(**overrides))
    assert len(results) == 3
    assert all(r.status == "unavailable" and r.score is None for r in results)
    sdk.assert_not_called()


async def test_judge_overrides_and_evidence_truncation_are_explicit():
    def run(metric, *args):
        return {metric: 5, f"{metric}_reason": "Reason"}

    with patch.object(rag, "_run_sdk", side_effect=run) as sdk:
        results, truncated = await evaluate(config(
            EVALUATOR_MAX_EVIDENCE_CHARS=3,
            EVALUATOR_AZURE_ENDPOINT="https://separate-judge.openai.azure.com",
            EVALUATOR_MODEL="separate-deployment",
            EVALUATOR_IS_REASONING_MODEL=True,
        ))
    assert len(results) == 3 and truncated is True
    for call in sdk.call_args_list:
        assert call.args[1]["azure_deployment"] == "separate-deployment"
        assert call.args[1]["azure_endpoint"] == "https://separate-judge.openai.azure.com"
        assert call.args[3] is True
        assert call.args[-1] == "Evi"


async def test_timeout_keeps_capacity_occupied_until_worker_finishes():
    release = threading.Event()
    finished = threading.Event()
    capacity = threading.BoundedSemaphore(1)

    def slow(*args):
        try:
            release.wait(timeout=2)
            return {"relevance": 4, "relevance_reason": "Reason"}
        finally:
            finished.set()

    cfg = config(
        ENABLE_GROUNDEDNESS_EVALUATION=False,
        ENABLE_RETRIEVAL_EVALUATION=False,
        EVALUATOR_TIMEOUT_SECONDS=0.01,
    )
    with patch.object(rag, "_CAPACITY", capacity), patch.object(rag, "_run_sdk", side_effect=slow):
        try:
            results, _ = await evaluate(cfg)
            assert results[0].reason == "Evaluation timed out."
            assert not capacity.acquire(blocking=False)
            results, _ = await evaluate(cfg)
            assert "capacity is busy" in results[0].reason
        finally:
            release.set()
            await asyncio.to_thread(finished.wait, 2)
            # Let the concurrent-future completion callbacks finish.
            await asyncio.sleep(0.01)
    assert capacity.acquire(blocking=False)
    capacity.release()


async def test_cancellation_is_propagated():
    release = threading.Event()
    entered = threading.Event()
    finished = threading.Event()
    capacity = threading.BoundedSemaphore(1)

    def run(*args):
        try:
            entered.set()
            release.wait(timeout=2)
            return {"relevance": 4, "relevance_reason": "Reason"}
        finally:
            finished.set()

    cfg = config(ENABLE_GROUNDEDNESS_EVALUATION=False, ENABLE_RETRIEVAL_EVALUATION=False)
    with patch.object(rag, "_CAPACITY", capacity), patch.object(rag, "_run_sdk", side_effect=run):
        task = asyncio.create_task(evaluate(cfg))
        try:
            assert await asyncio.to_thread(entered.wait, 2)
            task.cancel()
            with pytest.raises(asyncio.CancelledError):
                await task
            assert not capacity.acquire(blocking=False)
        finally:
            release.set()
            await asyncio.to_thread(finished.wait, 2)
            await asyncio.sleep(0.01)


@pytest.mark.parametrize("backend", ["ai_search", "foundry_iq"])
async def test_evidence_callback_receives_exact_authorized_model_context(mock_config, backend):
    from agent_framework import ChatMessage, Role
    from connectors.obo import RetrievalAuthorizationMode
    from strategies import foundry_iq_context_provider as iq
    from strategies import search_context_provider as search
    from test_context_provider_boundary_dispositions import _sdk_search

    rows = [
        {"id": "1", "title": "First", "filepath": "one.pdf", "content": "First ranked evidence"},
        {"id": "2", "title": "Second", "filepath": "two.pdf", "content": "Second ranked evidence"},
    ]
    captured = []
    sdk = _sdk_search(rows, lambda _: None)
    client = SimpleNamespace(
        mcp_config=SimpleNamespace(enabled=False),
        retrieve=AsyncMock(return_value=[
            {"title": row["title"], "link": row["filepath"], "content": row["content"]}
            for row in rows
        ]),
    )
    kwargs = dict(
        conversation_id="conversation", on_context=captured.append,
        authorization_mode=RetrievalAuthorizationMode.SERVICE_ONLY,
        max_content_chars=100,
    )
    if backend == "ai_search":
        provider = search.SearchContextProvider(
            endpoint="https://search.invalid", index_name="documents",
            credential=Mock(), owner_id="owner", **kwargs,
        )
    else:
        provider = iq.FoundryIQContextProvider(**kwargs)
    with (
        patch.object(search, "SearchClient", return_value=sdk),
        patch.object(search, "get_config", return_value=mock_config),
        patch.object(iq, "get_foundry_iq_client", return_value=client),
    ):
        model_context = await provider.invoking(ChatMessage(role=Role.USER, text="Question"))
    assert captured == [model_context.messages[0].text]
    assert captured[0].index("First ranked") < captured[0].index("Second ranked")
    if backend == "ai_search":
        assert "owner" in sdk.search.call_args.kwargs["filter"]


async def test_typed_metadata_survives_classic_orchestration_without_becoming_history(
    mock_config, mock_cosmos,
):
    from orchestration.orchestrator import Orchestrator
    from orchestration.turn import TurnConversationEvent, TurnRequest, TurnTextEvent

    evaluation = TurnEvaluationEvent((RagMetricResult("relevance", "success", "On topic.", 5),))
    strategy = Mock()
    strategy.set_context = Mock()

    async def flow(question):
        strategy.conversation["messages"] = [
            {"role": "user", "text": question}, {"role": "assistant", "text": "Answer"},
        ]
        yield "Answer"
        yield evaluation

    strategy.initiate_agent_flow = flow
    with (
        patch("orchestration.orchestrator.get_config", return_value=mock_config),
        patch("orchestration.orchestrator.get_cosmosdb_client", return_value=mock_cosmos),
        patch("orchestration.orchestrator.AgentStrategyFactory.get_strategy", AsyncMock(return_value=strategy)),
    ):
        request = TurnRequest(ask="Question")
        instance = await Orchestrator.from_turn_request(request)
        events = [event async for event in instance.stream_turn(request)]
        await asyncio.sleep(0)
    assert isinstance(events[0], TurnConversationEvent)
    assert events[1:] == [TurnTextEvent("Answer"), evaluation]
    assert strategy.conversation["messages"][-1] == {"role": "assistant", "text": "Answer"}


def test_versioned_metadata_preserves_scores_and_does_not_include_evidence():
    frame = serialize_turn_event(TurnEvaluationEvent((
        RagMetricResult("groundedness", "success", "Supported.", 4),
    )))
    assert frame.startswith("<<<GROUNDEDNESS_JSON>>>")
    encoded = frame.removeprefix("<<<GROUNDEDNESS_JSON>>>").removesuffix("<<<END_GROUNDEDNESS_JSON>>>")
    payload = json.loads(base64.urlsafe_b64decode(encoded))
    assert payload == {
        "version": 1, "evidence_truncated": False,
        "metrics": [{"metric": "groundedness", "status": "success", "score": 4, "reason": "Supported."}],
    }


@pytest.mark.parametrize("hosted", [False, True])
async def test_maf_lite_evaluates_only_classic_completed_turns(patch_dependencies, mock_config, hosted):
    from strategies.base_agent_strategy import hosted_runtime_construction
    from strategies import maf_lite_strategy as lite

    with patch.object(lite, "get_config", return_value=mock_config):
        if hosted:
            with hosted_runtime_construction():
                strategy = lite.MafLiteStrategy()
        else:
            strategy = lite.MafLiteStrategy()
    strategy.conversation = {}
    strategy._classify_intent = AsyncMock(return_value="question")
    strategy._ensure_user_memory = AsyncMock()
    strategy._get_or_create_chat_client = Mock()
    strategy._read_prompt = AsyncMock(return_value="Instructions")
    strategy._evaluation_contexts.append("stale evidence from another turn")
    provider = Mock()
    strategy._create_search_provider = AsyncMock(return_value=provider)
    agent = MagicMock()
    agent.__aenter__ = AsyncMock(return_value=agent)
    agent.__aexit__ = AsyncMock(return_value=False)

    async def stream(*args, **kwargs):
        strategy._evaluation_contexts.append("Actual authorized context")
        yield SimpleNamespace(text="Full ")
        yield SimpleNamespace(text="answer")

    agent.run_stream = stream
    result = (RagMetricResult("relevance", "success", "On topic.", 5),)
    with (
        patch.object(lite, "ChatAgent", return_value=agent),
        patch.object(lite, "evaluate_rag_triad", AsyncMock(return_value=(result, False))) as evaluate_turn,
    ):
        events = [event async for event in strategy.initiate_agent_flow("Question")]
    assert events[:2] == ["Full ", "answer"]
    assert strategy.conversation["messages"] == [
        {"role": "user", "text": "Question"}, {"role": "assistant", "text": "Full answer"},
    ]
    if hosted:
        evaluate_turn.assert_not_awaited()
        assert len(events) == 2
    else:
        assert events[-1] == TurnEvaluationEvent(result)
        assert evaluate_turn.call_args.kwargs == {
            "query": "Question", "response": "Full answer",
            "context": "Actual authorized context",
        }
