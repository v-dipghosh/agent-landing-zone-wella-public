import base64
import hashlib
import json
import logging
import os
import re
import asyncio
import time
from dataclasses import dataclass, field
from typing import Dict, List, NamedTuple, Optional

import chainlit as cl
import msal

from gpt_rag_ui.auth.auth_common import (
    OAUTH_API_CLIENT_ID_SETTING,
    canonical_principal_id,
    expected_orchestrator_api_scope,
    is_user_authorized,
)
from gpt_rag_ui.config.dependencies import get_config
from gpt_rag_ui.config.errors import ConfigurationError

logger = logging.getLogger("gpt_rag_ui.auth_oauth")

config = get_config()

_SCOPE_SPLIT_RE = re.compile(r"[\s,]+")


def _decode_jwt_unverified(token: str) -> Optional[dict]:
    """Decode JWT payload without verifying signature.

    For debug diagnostics only. Never use this to authorize.
    """

    try:
        parts = (token or "").split(".")
        if len(parts) < 2:
            return None
        payload_b64 = parts[1]
        payload_b64 += "=" * (-len(payload_b64) % 4)
        payload = base64.urlsafe_b64decode(payload_b64.encode("utf-8"))
        data = json.loads(payload.decode("utf-8"))
        return data if isinstance(data, dict) else None
    except ValueError:
        return None


def _access_token_debug_summary(access_token: str) -> dict:
    claims = _decode_jwt_unverified(access_token) or {}
    aud = claims.get("aud")
    if isinstance(aud, list):
        aud_value = ",".join(str(x) for x in aud)
    else:
        aud_value = str(aud) if aud is not None else None

    oid = claims.get("oid")
    tid = claims.get("tid")
    iss = claims.get("iss")
    scp = claims.get("scp")
    ver = claims.get("ver")
    azp = claims.get("azp")

    def _short(value: object) -> str:
        s = str(value or "")
        if len(s) <= 10:
            return s
        return f"{s[:4]}…{s[-4:]}"

    return {
        "aud": aud_value,
        "tid": _short(tid) if tid else None,
        "oid": _short(oid) if oid else None,
        "iss": iss,
        "scp": scp,
        "ver": ver,
        "azp": _short(azp) if azp else None,
    }


def _jwt_exp_unverified(access_token: str) -> int | None:
    claims = _decode_jwt_unverified(access_token) or {}
    exp = claims.get("exp")
    try:
        return int(exp) if exp is not None else None
    except (ValueError, TypeError, OverflowError):
        return None


def _access_token_ttl_seconds(access_token: str) -> int | None:
    exp = _jwt_exp_unverified(access_token)
    if not exp:
        return None
    now = int(time.time())
    return int(exp) - now


def _is_access_token_expiring(access_token: str, *, min_ttl_seconds: int = 120) -> bool:
    ttl = _access_token_ttl_seconds(access_token)
    if ttl is None:
        # If we can't read exp, be safe and refresh.
        return True
    return ttl <= int(min_ttl_seconds)


def _resolve_oauth_runtime_config() -> tuple[str, str, str]:
    """Return (client_id, client_secret, tenant_id) for MSAL operations."""

    # Prefer process env (bootstrapped by main.py), then App Configuration.
    client_id = (os.getenv("OAUTH_AZURE_AD_CLIENT_ID") or "").strip() or (get_env_var("OAUTH_AZURE_AD_CLIENT_ID") or "").strip()
    client_secret = (os.getenv("OAUTH_AZURE_AD_CLIENT_SECRET") or "").strip() or (
        get_env_var("OAUTH_AZURE_AD_CLIENT_SECRET") or ""
    ).strip()
    tenant_id = (os.getenv("OAUTH_AZURE_AD_TENANT_ID") or "").strip() or (get_env_var("OAUTH_AZURE_AD_TENANT_ID") or "").strip()

    if not client_id or not client_secret or not tenant_id:
        raise RuntimeError("OAuth is not configured (missing OAUTH_AZURE_AD_* settings)")

    return client_id, client_secret, tenant_id


def _resolve_expected_api_scope(client_id: str) -> str:
    """Return the exact API scope for standalone OAuth.

    Reads the optional split-registration setting OAUTH_AZURE_AD_API_CLIENT_ID
    (process env first, then App Configuration). Unset keeps the UI client id.
    A malformed value raises ConfigurationError (fail closed).
    """

    api_client_id = (os.getenv(OAUTH_API_CLIENT_ID_SETTING) or "").strip() or (
        get_env_var(OAUTH_API_CLIENT_ID_SETTING, warn_on_missing=False) or ""
    ).strip()
    return expected_orchestrator_api_scope(client_id, api_client_id)


def _resolve_msal_scopes_for_refresh(*, client_id: str) -> List[str]:
    expected_api_scope = _resolve_expected_api_scope(client_id)
    raw_scopes, scopes = read_scopes_list("OAUTH_AZURE_AD_SCOPES")
    if not scopes:
        scopes = [
            expected_api_scope,
            "openid",
            "profile",
            "offline_access",
        ]

    if any(_looks_like_graph_scope(s) for s in scopes):
        raise RuntimeError(
            "Invalid OAUTH_AZURE_AD_SCOPES for 'single token' mode: Graph scopes detected. "
            "Remove Graph scopes (e.g. User.Read) and configure the API scope instead."
        )

    msal_scopes = [s for s in scopes if not _is_reserved_oidc_scope(s)]
    if expected_api_scope not in msal_scopes:
        raise RuntimeError(
            "OAuth scope misconfiguration: expected API scope is missing for orchestrator token exchange. "
            f"expected={expected_api_scope} got={msal_scopes}"
        )

    if logger.isEnabledFor(logging.DEBUG):
        logger.debug(
            "Resolved OAuth scopes for refresh: raw=%r parsed=%s msal_scopes=%s",
            raw_scopes,
            scopes,
            msal_scopes,
        )

    return msal_scopes


async def refresh_access_token(refresh_token: str) -> dict:
    """Exchange refresh_token -> new access_token using MSAL.

    This runs MSAL's blocking network call in a thread to avoid blocking the event loop.
    """

    client_id, client_secret, tenant_id = _resolve_oauth_runtime_config()
    authority = f"https://login.microsoftonline.com/{tenant_id}"
    msal_scopes = _resolve_msal_scopes_for_refresh(client_id=client_id)

    msal_app = msal.ConfidentialClientApplication(
        client_id,
        authority=authority,
        client_credential=client_secret,
    )

    def _run_refresh() -> dict:
        return msal_app.acquire_token_by_refresh_token(refresh_token=refresh_token, scopes=msal_scopes)

    return await asyncio.to_thread(_run_refresh)


async def ensure_fresh_user_access_token(user: cl.User, *, min_ttl_seconds: int = 120) -> bool:
    """Ensure the user's access token is valid and refresh it when close to expiry.

    Returns True if a refresh was performed.
    """

    metadata = user.metadata or {}
    refreshed = await _refresh_metadata_access_token(
        metadata,
        min_ttl_seconds=min_ttl_seconds,
        fallback_subject=user.identifier,
    )
    if refreshed:
        user.metadata = metadata
    return refreshed


async def ensure_fresh_access_token_for_metadata(
    metadata: dict | None, *, min_ttl_seconds: int = 120
) -> str | None:
    """Return a usable access token for OAuth user ``metadata``.

    The token is returned unchanged unless it is within ``min_ttl_seconds`` of
    expiry (or its ``exp`` is unreadable) and a refresh token is present. In
    that case the shared single-flight refresh runs and the SAME ``metadata``
    dict is updated in place (``access_token``, ``refresh_token``,
    ``access_token_acquired_at``, ``access_token_expires_at``).

    Without a refresh token the existing token is returned unchanged. A failed
    refresh raises ``RuntimeError`` (or the underlying MSAL/config/network error)
    and never returns the expired token. Tokens are never logged.
    """

    metadata = metadata if metadata is not None else {}
    await _refresh_metadata_access_token(metadata, min_ttl_seconds=min_ttl_seconds)
    return str(metadata.get("access_token") or "").strip() or None


# ── Shared refresh with single-flight cache ──────────────────────────────────
#
# Chainlit rebuilds the request user from the session JWT cookie, which carries
# the LOGIN-TIME metadata. After the access token expires, every request that
# starts from that cookie (several concurrent history reads, thread reads, ...)
# holds its own metadata dict with the same stale tokens. Refreshing per dict
# would redeem one refresh token many times in parallel, so refreshed tokens are
# cached in memory, keyed by a SHA-256 of the refresh token that was REDEEMED
# (the cookie's), and concurrent requests for that key share one refresh.
#
# Assumption (ADR-0008): redeeming a refresh token with Entra returns a new
# access token (and usually a rotated refresh token) but does not invalidate the
# redeemed one, so requests that still carry the cookie's refresh token can
# refresh again once the cached access token expires. Memory only; never
# persisted or logged; bounded; lost on restart (the next request refreshes).

_REFRESH_CACHE_MAX_ENTRIES = 256


class _RefreshedTokens(NamedTuple):
    access_token: str
    refresh_token: str


@dataclass
class _RefreshSlot:
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    users: int = 0


_refresh_cache: Dict[str, _RefreshedTokens] = {}
_refresh_slots: Dict[str, _RefreshSlot] = {}


def _refresh_cache_key(refresh_token: str) -> str:
    return hashlib.sha256(refresh_token.encode("utf-8")).hexdigest()


def _refresh_cache_get(key: str, *, min_ttl_seconds: int) -> _RefreshedTokens | None:
    entry = _refresh_cache.get(key)
    if entry is None:
        return None
    if _is_access_token_expiring(entry.access_token, min_ttl_seconds=min_ttl_seconds):
        _refresh_cache.pop(key, None)
        return None
    return entry


def _refresh_cache_put(key: str, entry: _RefreshedTokens, *, min_ttl_seconds: int) -> None:
    for stale_key in [
        cached_key
        for cached_key, cached in _refresh_cache.items()
        if _is_access_token_expiring(cached.access_token, min_ttl_seconds=min_ttl_seconds)
    ]:
        del _refresh_cache[stale_key]
    _refresh_cache.pop(key, None)
    while len(_refresh_cache) >= _REFRESH_CACHE_MAX_ENTRIES:
        del _refresh_cache[next(iter(_refresh_cache))]
    _refresh_cache[key] = entry


async def _refresh_tokens_single_flight(
    refresh_token: str, *, min_ttl_seconds: int
) -> _RefreshedTokens:
    """Redeem ``refresh_token`` once per key and share the result."""

    key = _refresh_cache_key(refresh_token)
    slot = _refresh_slots.get(key)
    if slot is None:
        slot = _refresh_slots[key] = _RefreshSlot()
    slot.users += 1
    try:
        async with slot.lock:
            cached = _refresh_cache_get(key, min_ttl_seconds=min_ttl_seconds)
            if cached is not None:
                return cached

            result = await refresh_access_token(refresh_token)
            if "error" in result:
                error_desc = result.get("error_description", "Unknown error")
                logger.warning("User token refresh failed: %s", error_desc)
                raise RuntimeError(f"token refresh failed: {error_desc}")

            new_access_token = result.get("access_token")
            if not new_access_token:
                raise RuntimeError("token refresh failed: missing access_token")

            entry = _RefreshedTokens(
                access_token=new_access_token,
                refresh_token=result.get("refresh_token") or refresh_token,
            )
            _refresh_cache_put(key, entry, min_ttl_seconds=min_ttl_seconds)
            return entry
    finally:
        slot.users -= 1
        if slot.users == 0:
            _refresh_slots.pop(key, None)


async def _refresh_metadata_access_token(
    metadata: dict,
    *,
    min_ttl_seconds: int,
    fallback_subject: str | None = None,
) -> bool:
    """Refresh ``metadata`` tokens in place when expiring. True if updated."""

    access_token = str(metadata.get("access_token") or "").strip()
    refresh_token_value = str(metadata.get("refresh_token") or "").strip()

    if not access_token or not refresh_token_value:
        return False

    if not _is_access_token_expiring(access_token, min_ttl_seconds=min_ttl_seconds):
        return False

    ttl = _access_token_ttl_seconds(access_token)
    logger.info(
        "Refreshing user access token (near expiry): ttl_seconds=%s user=%s",
        ttl if ttl is not None else "unknown",
        (metadata.get("client_principal_name") or metadata.get("client_principal_id") or fallback_subject or "<unknown>"),
    )

    refreshed = await _refresh_tokens_single_flight(
        refresh_token_value, min_ttl_seconds=min_ttl_seconds
    )

    metadata["access_token"] = refreshed.access_token
    metadata["refresh_token"] = refreshed.refresh_token
    metadata["access_token_acquired_at"] = int(time.time())
    exp = _jwt_exp_unverified(refreshed.access_token)
    if exp:
        metadata["access_token_expires_at"] = int(exp)

    if logger.isEnabledFor(logging.DEBUG):
        logger.debug(
            "Refreshed access token claims (unverified): %s",
            _access_token_debug_summary(refreshed.access_token),
        )

    return True


def _looks_like_graph_scope(scope: str) -> bool:
    s = (scope or "").strip()
    if not s:
        return False

    s_lower = s.lower()

    # Common Graph scope names (delegated)
    if s_lower in {
        "user.read",
        "groupmember.read.all",
        "directory.read.all",
        "directory.accessasuser.all",
    }:
        return True

    # Graph resource identifiers / default scopes
    if "graph.microsoft.com" in s_lower:
        return True
    if "00000003-0000-0000-c000-000000000000" in s_lower:
        return True

    return False


def _is_reserved_oidc_scope(scope: str) -> bool:
    # MSAL Python rejects these in acquire_token_by_refresh_token.
    return (scope or "").strip().lower() in {"openid", "profile", "offline_access"}


def read_scopes_list(var_name: str = "OAUTH_AZURE_AD_SCOPES") -> tuple[str, List[str]]:
    """Read scopes from config and split by comma OR whitespace.

    Azure App Configuration values sometimes come space-separated (e.g. "openid profile").
    MSAL supports passing scopes as a list; internally they'll be joined with spaces.
    """

    # Prefer process env (bootstrapped by main.py) to avoid stale App Config cache.
    raw = (os.getenv(var_name) or "").strip()
    if not raw:
        raw = str(config.get(var_name, "") or "").strip()
    if not raw:
        return "", []
    parts = [p.strip() for p in _SCOPE_SPLIT_RE.split(raw) if p and p.strip()]
    return raw, parts


def get_env_var(name: str, fallback: str | None = None, *, warn_on_missing: bool = True) -> str | None:
    # Despite the name, we read from Azure App Configuration (and env as fallback when App Config isn't configured).
    # Use allow_none=True so missing keys don't crash.
    try:
        value = config.get_value(name, default=fallback, allow_none=True, type=str)
    except ConfigurationError:
        logger.warning("Configuration key '%s' is unavailable; using fallback", name)
        value = fallback
    if value is None:
        if warn_on_missing:
            logger.warning("Configuration key '%s' is not set", name)
    return value


AZURE_AD_PENDING_IDENTIFIER = "azure-ad-pending"
_GRAPH_FREE_MARKER = "_gpt_rag_ui_graph_free"


async def _graph_free_azure_ad_user_info(self, token: str) -> tuple[dict, cl.User]:
    """Replacement for ``AzureADOAuthProvider.get_user_info`` that never calls Graph.

    Chainlit's implementation calls Microsoft Graph ``/me`` with the access token,
    but this UI's token is issued for the orchestrator API, so Graph rejects it
    ("Invalid audience") and sign-in fails. ``oauth_callback`` ignores the raw
    user data and the default identity: it only needs the refresh token, then
    derives identity from the MSAL-validated ``id_token_claims`` and authorizes.

    The returned identity is a fixed placeholder, not derived from ``token`` and
    never trusted: ``oauth_callback`` returns its own ``cl.User`` or ``None``, and
    Chainlit refuses the sign-in when the callback returns ``None``.
    """

    del token  # Never decoded or trusted for identity.
    user = cl.User(
        identifier=AZURE_AD_PENDING_IDENTIFIER,
        metadata={
            "provider": "azure-ad",
            "refresh_token": getattr(self, "_refresh_token", None),
            "image": None,
        },
    )
    return {}, user


setattr(_graph_free_azure_ad_user_info, _GRAPH_FREE_MARKER, True)


def install_graph_free_azure_ad_profile() -> bool:
    """Replace Chainlit's Azure AD profile lookup with a network-free one.

    Patches the class attribute, so provider instances already created in
    ``chainlit.oauth_providers.providers`` use it too (the provider reads its
    environment in ``__init__``; that is independent of this patch). Idempotent:
    returns ``True`` when it installed the replacement and ``False`` when it was
    already installed. Call only when standalone OAuth is configured.
    """

    from chainlit.oauth_providers import AzureADOAuthProvider

    if getattr(AzureADOAuthProvider.get_user_info, _GRAPH_FREE_MARKER, False):
        return False
    AzureADOAuthProvider.get_user_info = _graph_free_azure_ad_user_info
    logger.info("Installed Graph-free Azure AD profile lookup for standalone OAuth")
    return True


async def oauth_callback(
    provider_id: str, code: str, raw_user_data: Dict[str, str], default_user: cl.User
) -> Optional[cl.User]:
    """Chainlit OAuth callback.

    Uses MSAL to exchange the Chainlit refresh token for an Entra ID access token.
    """

    logger.info("OAuth callback received for provider '%s'", provider_id)

    metadata_keys = sorted(key for key in (default_user.metadata or {}) if isinstance(key, str))
    logger.info(
        "OAuth callback context: provider=%s metadata_keys=%s",
        provider_id,
        metadata_keys,
    )

    # Prefer the explicit OAuth keys; legacy fallbacks are optional and should not spam warnings.
    client_id = get_env_var("OAUTH_AZURE_AD_CLIENT_ID") or get_env_var("CLIENT_ID", warn_on_missing=False)
    client_secret = get_env_var("OAUTH_AZURE_AD_CLIENT_SECRET") or get_env_var("authClientSecret", warn_on_missing=False)
    tenant_id = get_env_var("OAUTH_AZURE_AD_TENANT_ID")

    if not client_id or not client_secret or not tenant_id:
        raise RuntimeError("OAuth is not configured (missing OAUTH_AZURE_AD_* settings)")

    authority = f"https://login.microsoftonline.com/{tenant_id}"
    expected_api_scope = _resolve_expected_api_scope(client_id)
    raw_scopes, scopes = read_scopes_list("OAUTH_AZURE_AD_SCOPES")
    if not scopes:
        # "Single token" mode: request a token for the orchestrator API (not Microsoft Graph).
        # This assumes the API App Registration (the UI app by default, or the app named by
        # OAUTH_AZURE_AD_API_CLIENT_ID) has "Expose an API" with scope 'user_impersonation'.
        scopes = [
            expected_api_scope,
            "openid",
            "profile",
            "offline_access",
        ]

    # Guard rail: Graph scopes mint a token for Graph (aud=00000003-...), breaking the orchestrator audience check.
    if any(_looks_like_graph_scope(s) for s in scopes):
        raise RuntimeError(
            "Invalid OAUTH_AZURE_AD_SCOPES for 'single token' mode: Graph scopes detected. "
            "Remove Graph scopes (e.g. User.Read) and configure the API scope instead, e.g. "
            f"{expected_api_scope},openid,profile,offline_access"
        )

    if logger.isEnabledFor(logging.DEBUG):
        logger.debug(
            "Resolved OAuth scopes: raw=%r parsed=%s",
            raw_scopes,
            scopes,
        )

    logger.info(
        "OAuth token exchange configuration: authority_tenant=%s scopes=%s",
        (tenant_id[-6:] if len(tenant_id) >= 6 else "<redacted>"),
        scopes,
    )

    # MSAL does not allow OIDC reserved scopes when exchanging refresh_token -> access_token.
    # Keep them for the interactive login/consent (so Chainlit can obtain a refresh token),
    # but omit them from this refresh token exchange.
    msal_scopes = [s for s in scopes if not _is_reserved_oidc_scope(s)]
    if logger.isEnabledFor(logging.DEBUG):
        logger.debug("MSAL refresh-token exchange scopes (reserved omitted): %s", msal_scopes)

    if expected_api_scope not in msal_scopes:
        raise RuntimeError(
            "OAuth scope misconfiguration: expected API scope is missing for orchestrator token exchange. "
            f"expected={expected_api_scope} got={msal_scopes}"
        )

    refresh_token =  (default_user.metadata or {}).get("refresh_token")
    if not refresh_token:
        raise RuntimeError(
            "OAuth callback did not receive a refresh token from Chainlit. "
            "Ensure your scopes include 'offline_access' (for example: api://<CLIENT_ID>/user_impersonation,openid,profile,offline_access)."
        )

    msal_app = msal.ConfidentialClientApplication(
        client_id,
        authority=authority,
        client_credential=client_secret,
    )

    result = msal_app.acquire_token_by_refresh_token(refresh_token=refresh_token, scopes=msal_scopes)

    if "error" in result:
        error_desc = result.get("error_description", "Unknown error")
        if "AADSTS65001" in error_desc:
            logger.error("Token acquisition failed (consent required): %s", error_desc)
            raise RuntimeError(
                "Token acquisition failed: AADSTS65001 (consent required). "
                "Grant consent for this app in Entra ID (App Registration -> API permissions -> Grant admin consent) "
                "or allow user consent, then sign in again."
            )

        logger.error("Token acquisition failed: %s", error_desc)
        raise RuntimeError(f"Token acquisition failed: {error_desc}")

    access_token = result.get("access_token")
    refresh_token = result.get("refresh_token") or refresh_token
    id_token = result.get("id_token_claims", {})
    if not access_token:
        raise RuntimeError("Token acquisition failed: missing access token.")

    if logger.isEnabledFor(logging.DEBUG):
        logger.debug(
            "Access token claims (unverified): %s",
            _access_token_debug_summary(access_token),
        )

    tenant_id_claim = str(id_token.get("tid") or "").strip()
    object_id = str(id_token.get("oid") or "").strip()
    principal_name = str(id_token.get("preferred_username") or "").strip()
    try:
        principal_id = canonical_principal_id(
            tenant_id_claim,
            object_id,
        )
    except ValueError as exc:
        raise RuntimeError(
            "OAuth identity is missing valid tid or oid claims."
        ) from exc
    tenant_id_claim, object_id = principal_id.split(":", 1)
    user_name = str(id_token.get("name") or "").strip() or principal_id

    # "Single token" mode: do not call Microsoft Graph from the client.
    # If you need group-based auth, it will require a second token (Graph audience).
    groups: List[str] = []

    authorized = is_user_authorized(
        config,
        principal_name,
        principal_id,
    )

    logger.info(
        "User authenticated: name='%s' principal='%s' authorized=%s",
        user_name,
        principal_name or principal_id,
        authorized,
    )
    if not authorized:
        return None

    metadata = {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "access_token_acquired_at": int(time.time()),
        "access_token_expires_at": _jwt_exp_unverified(access_token),
        "authorized": authorized,
        "auth_source": "oauth",
        "user_name": principal_id,
        "client_principal_id": object_id,
        "client_principal_name": principal_name,
        "client_group_names": groups,
        "principal_id": principal_id,
        "tenant_id": tenant_id_claim,
        "object_id": object_id,
    }

    return cl.User(
        identifier=principal_id,
        display_name=user_name,
        metadata=metadata,
    )
