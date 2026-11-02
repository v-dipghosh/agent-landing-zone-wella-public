"""Entra-owned history remains mandatory after removing shared demo identity."""

from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest

import dependencies
from orchestration.turn import TurnTextEvent
from test_primary_strategy_failure_boundaries import main_module
from test_service_token_auth import TENANT, _SIGNING_KEY, _jwk, _token

API_CLIENT = "history-api-client"
SERVICE_KEY = "synthetic-service-key"
USER_ID = "signed-in-user"
SERVICE_HEADERS = {"X-API-KEY": SERVICE_KEY}


@pytest.fixture
def entra_environment(mock_config, monkeypatch):
    values = {
        "OAUTH_AZURE_AD_TENANT_ID": TENANT,
        "OAUTH_AZURE_AD_CLIENT_ID": API_CLIENT,
        "ORCHESTRATOR_APP_APIKEY": SERVICE_KEY,
        "ALLOW_ANONYMOUS": False,
        "DEMO_AUTH_ENABLED": "true",
        "DEMO_SERVICE_AUTH_MODE": "api_key",
    }
    original_get = mock_config.get.side_effect

    def get(key, default=None, type=str):
        if key in values:
            return values[key]
        return original_get(key, default, type)

    mock_config.get.side_effect = get
    monkeypatch.delenv("DISABLE_AUTH", raising=False)
    monkeypatch.setenv("DEMO_DEPLOYMENT", "true")
    monkeypatch.setattr(
        dependencies, "_get_cached_public_keys",
        AsyncMock(return_value={"keys": [_jwk(_SIGNING_KEY)]}),
    )


@pytest.fixture
def entra_main(entra_environment, main_module):
    return main_module


@pytest.fixture
async def client(entra_main):
    async with httpx.AsyncClient(
        transport=httpx.ASGITransport(app=entra_main.app), base_url="http://test",
    ) as value:
        yield value


def user_headers():
    token = _token(
        aud=f"api://{API_CLIENT}", oid=USER_ID,
        preferred_username="user@example.invalid", name="Test User",
    )
    return SERVICE_HEADERS | {"Authorization": f"Bearer {token}"}


async def test_retired_discovery_is_not_mounted(client):
    response = await client.get(
        "/demo/context", headers=SERVICE_HEADERS | {"X-Demo-Auth": "shared-v1"},
    )
    assert response.status_code == 404


@pytest.mark.parametrize("method,path,payload", [
    ("POST", "/orchestrator", {"ask": "hello"}),
    ("GET", "/conversations", None),
    ("GET", "/conversations/seeded", None),
    ("PATCH", "/conversations/seeded", {"name": "changed"}),
    ("DELETE", "/conversations/seeded", None),
])
async def test_retired_marker_and_service_key_cannot_replace_user_login(
    client, method, path, payload,
):
    kwargs = {"json": payload} if payload is not None else {}
    response = await client.request(
        method, path, headers=SERVICE_HEADERS | {"X-Demo-Auth": "shared-v1"}, **kwargs,
    )
    assert response.status_code == 401


async def test_signed_entra_user_owns_history(client, entra_main, monkeypatch):
    document = {
        "id": "seeded", "name": "Entra history",
        "principal_id": USER_ID,
        "messages": [{"role": "user", "text": "Saved message"}],
    }
    query = AsyncMock(return_value=[document])
    read = AsyncMock(return_value=document)
    monkeypatch.setattr(entra_main, "query_user_conversations", query)
    monkeypatch.setattr(entra_main, "read_user_conversation", read)
    headers = user_headers()

    listing = await client.get("/conversations?principal_id=other-user", headers=headers)
    assert listing.status_code == 200
    assert listing.json()["conversations"][0]["id"] == "seeded"
    assert query.await_args.kwargs["principal_id"] == USER_ID
    detail = await client.get("/conversations/seeded", headers=headers)
    assert detail.status_code == 200
    assert detail.json()["principal_id"] == USER_ID
    assert detail.json()["messages"] == document["messages"]
    read.assert_awaited_once_with("seeded", USER_ID)

    read.return_value = document | {"principal_id": "other-user"}
    assert (await client.get("/conversations/seeded", headers=headers)).status_code == 403


async def test_chat_uses_verified_user_not_client_supplied_principal(client, entra_main, monkeypatch):
    async def stream(turn):
        yield TurnTextEvent(text="answer")

    create = AsyncMock(return_value=SimpleNamespace(stream_turn=stream))
    monkeypatch.setattr(entra_main.Orchestrator, "from_turn_request", create)
    headers = user_headers()
    response = await client.post(
        "/orchestrator", headers=headers,
        json={"ask": "hello", "user_context": {
            "principal_id": "forged-user", "principal_name": "Forged User",
        }},
    )
    assert response.status_code == 200
    assert "answer" in response.text
    turn = create.await_args.args[0]
    assert turn.user_context["principal_id"] == USER_ID
    assert turn.user_context["principal_name"] == "user@example.invalid"
    assert turn.request_access_token == headers["Authorization"].removeprefix("Bearer ")
