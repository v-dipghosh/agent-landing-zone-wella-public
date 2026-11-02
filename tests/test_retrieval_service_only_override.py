"""RETRIEVAL_SERVICE_ONLY_OVERRIDE: default-off, Azure AI Search only, explicit."""

import logging
from types import SimpleNamespace
from unittest.mock import AsyncMock, patch

import pytest
from agent_framework import ChatMessage, Role

from connectors.obo import RetrievalAuthorizationMode
from strategies import foundry_iq_context_provider as foundry
from strategies import search_context_provider as text
from test_context_provider_boundary_dispositions import _sdk_search
from test_strategy_helper_boundaries import strategy as all_strategies

ASSERTION = "synthetic-user-assertion"
DOCUMENTS = [{"id": "one", "title": "Doc", "content": "shared corpus content"}]


@pytest.fixture
def strategy(all_strategies):
    module, instance = all_strategies
    if type(instance).__name__ != "MafLiteStrategy":
        pytest.skip("The override is implemented for MafLiteStrategy only")
    return module, instance


def configure(mock_config, override, anonymous=False):
    original_get = mock_config.get.side_effect

    def get(key, default=None, type=str):
        if key == "RETRIEVAL_SERVICE_ONLY_OVERRIDE":
            return override
        if key == "ALLOW_ANONYMOUS":
            return anonymous
        if key == "FOUNDRY_IQ_MCP_ENABLED":
            return False
        return original_get(key, default, type)

    mock_config.get.side_effect = get


async def build(strategy, backend):
    module, instance = strategy
    instance.request_access_token = ASSERTION
    obo = AsyncMock(return_value="synthetic-delegated")
    sdk = _sdk_search(DOCUMENTS, lambda _: None)
    remote = SimpleNamespace(
        mcp_config=SimpleNamespace(enabled=False, sources=()),
        retrieve=AsyncMock(return_value=DOCUMENTS),
    )
    with (
        patch.object(module, "get_retrieval_backend", return_value=backend),
        patch.object(module, "acquire_obo_search_token", obo),
        patch.object(text, "SearchClient", return_value=sdk),
        patch.object(foundry, "get_foundry_iq_client", return_value=remote),
    ):
        provider = await instance._create_search_provider()
        result = await provider.invoking(ChatMessage(role=Role.USER, text="question"))
    return provider, result, obo, sdk, remote


async def test_default_off_keeps_user_token_exchange(strategy, mock_config):
    configure(mock_config, override=False)
    provider, result, obo, sdk, _ = await build(strategy, "ai_search")
    assert provider._authorization_mode is RetrievalAuthorizationMode.USER_REQUIRED
    obo.assert_awaited_once_with(ASSERTION, allow_anonymous=False)
    assert sdk.search.await_args.kwargs["x_ms_query_source_authorization"] == "synthetic-delegated"


@pytest.mark.parametrize("value", [None, "", "yes", "1", 1, "True", "true"])
async def test_only_a_real_true_enables_the_override(strategy, mock_config, value):
    configure(mock_config, override=value)
    provider, *_ = await build(strategy, "ai_search")
    assert provider._authorization_mode is RetrievalAuthorizationMode.USER_REQUIRED


async def test_override_skips_exchange_and_searches_with_service_identity(
    strategy, mock_config, caplog,
):
    caplog.set_level(logging.WARNING)
    configure(mock_config, override=True)
    provider, result, obo, sdk, _ = await build(strategy, "ai_search")
    assert provider._authorization_mode is RetrievalAuthorizationMode.SERVICE_ONLY
    assert "shared corpus content" in result.messages[0].text
    obo.assert_not_awaited()
    assert "x_ms_query_source_authorization" not in sdk.search.await_args.kwargs
    assert "RETRIEVAL_SERVICE_ONLY_OVERRIDE is enabled" in caplog.text
    assert ASSERTION not in caplog.text


async def test_override_does_not_apply_to_foundry_iq(strategy, mock_config):
    configure(mock_config, override=True)
    provider, _, obo, _, remote = await build(strategy, "foundry_iq")
    assert provider._authorization_mode is RetrievalAuthorizationMode.USER_REQUIRED
    obo.assert_awaited_once_with(ASSERTION, allow_anonymous=False)
    assert remote.retrieve.await_args.kwargs["obo_token"] == "synthetic-delegated"
