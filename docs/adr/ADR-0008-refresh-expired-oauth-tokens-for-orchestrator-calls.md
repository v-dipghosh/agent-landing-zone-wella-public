# ADR-0008: Refresh expired OAuth access tokens for every orchestrator call

- Status: Accepted
- Date: 2026-11-02
- Owners: Agent Landing Zone UI maintainers

## Context

After the UI sits idle longer than the Entra access-token lifetime (about one
hour) and the browser is refreshed, history is empty and the next question fails
with the generic "We hit a technical issue" message; a retry moments later works.
The orchestrator logs `ExpiredSignatureError` and answers 401 to
`GET /conversations`, `GET /conversations/<id>`, and `POST /orchestrator`.

Two causes:

1. `services.chat.get_auth_info()` read `metadata["access_token"]` into a local
   variable, then called `auth_oauth.ensure_fresh_user_access_token()`, which
   refreshed and mutated the user metadata, but the returned dict still carried
   the local variable captured before the refresh. The first request after expiry
   always went out with the expired token.
2. The history and ownership path (`services.history` list/rename/delete and
   `services.conversation_security.get_owned_conversation`) resolves the token
   with `auth.embed_auth.resolve_access_token(metadata)`, which only read
   `metadata["access_token"]`. That metadata is the live `cl.user_session` user
   or, in HTTP requests, the user rebuilt from Chainlit's session JWT cookie. The
   cookie carries the **login-time** metadata, so after any page refresh the
   rebuilt user holds the stale login-time access token. A refresh in the live
   session mutates only the in-memory user, never the cookie.

## Prioritized characteristics

| Characteristic | Priority | Measure or fitness function |
| --- | --- | --- |
| Security | 5 | Tokens stay in memory, cache keys are hashes, nothing is logged or persisted; copilot/anonymous paths untouched. |
| Compatibility | 4 | No cookie/JWT, session lifetime, scope, Entra, or setting change; no behavior change for a non-expiring token. |
| Reliability | 4 | One refresh per stale refresh token regardless of concurrent requests. |
| Reversibility | 4 | Revert the call sites; no data or configuration to migrate. |

## Alternatives

### Option A: One shared refresh helper plus a single-flight cache (selected)

Add `ensure_fresh_access_token_for_metadata(metadata)` to `auth/oauth.py`, reusing
`_is_access_token_expiring` (minimum TTL 120 s) and `refresh_access_token`. It
updates the same metadata dict in place (`access_token`, `refresh_token` when
rotated, `access_token_acquired_at`, `access_token_expires_at`).
`ensure_fresh_user_access_token` now delegates to the same code, and
`resolve_access_token` calls it for `auth_source == "oauth"` only, which is the
single choke point for history and ownership checks.

### Option B: Refresh per request without sharing

Rejected: a page load starts several requests (for example `list_threads` with
`limit=35` and `limit=20` plus thread reads), each from its own copy of the same
stale cookie metadata, so one refresh token would be redeemed many times in
parallel.

### Option C: Rewrite the session cookie with the new tokens

Rejected: changes cookie/JWT handling and session contents, which is out of scope
and a larger security surface.

### Do not change

The first request after one idle hour keeps failing.

## Decision

Option A.

- `oauth._refresh_tokens_single_flight` keeps a bounded in-memory cache
  (256 entries) keyed by the SHA-256 of the refresh token that was **redeemed**,
  mapping to the new access token and the new (possibly rotated) refresh token.
  An entry is valid while its access token is not expiring. A per-key slot with
  an `asyncio.Lock` serializes concurrent requests so one performs the refresh and
  the rest reuse the cached result; slots are released when unused. Expired
  entries are evicted on lookup and on insert, then the oldest entry when full.
- `get_auth_info()` re-reads the token from the user metadata after a successful
  refresh. The refresh-failure handler is unchanged: the session is cleared and
  `auth_error: session_expired` is returned.
- `resolve_access_token` logs a failed refresh without token material (existing
  `log_boundary_failure` pattern) and returns no token. History, rename, delete,
  and ownership callers already treat that as an unusable session (empty result,
  `None`, or `False`) instead of sending a token known to be expired.
- `copilot_session`, anonymous, and unmarked metadata never reach the refresh.
  Without a refresh token the existing token is returned unchanged.

### Refresh-token rotation assumption

Entra may return a new refresh token when one is redeemed. The cache is keyed by
the redeemed (cookie) refresh token, so later requests that still carry the old
cookie value hit the cache while the new access token is fresh. When the cached
token expires, those requests redeem the old refresh token again. This relies on
Entra not invalidating a refresh token when it is redeemed (it stays valid until
its own lifetime or revocation). If that assumption fails, refresh returns
`invalid_grant`, history is empty and chat reports `session_expired`, so the user
signs in again; this is the same outcome as an expired session today. Live Entra
behavior has not been verified by tests.

## Security analysis

- Tokens are held in memory only, never persisted, written to logs, or placed in
  errors. The cache key is a SHA-256 digest, never the token.
- Memory is bounded (256 entries) and a restart empties it; the next request
  refreshes.
- Entries are per refresh token, so one user's cached token cannot be returned for
  another user's request.
- A failed refresh never falls back to the expired token.
- Logs carry the exception class and failure site only. Entra's
  `error_description` is logged as before.

## Consequences

### Positive

- The first request after expiry succeeds for chat, history, rename, delete, and
  ownership checks, and concurrent requests redeem one refresh token once.

### Negative

- Process-local cache: replicas each refresh once per stale refresh token.
- A failing refresh token is retried by each waiting request in turn; failures are
  not cached.
- `embed_auth` lazily imports `auth.oauth` for OAuth metadata only.

## Adoption, migration, and recovery

No configuration, schema, or data migration. Rollback: revert the call in
`embed_auth.resolve_access_token`, the re-read in `get_auth_info`, and the helper
in `auth/oauth.py`; behavior returns to the stale-token path.

## Compliance verification

`tests/test_oauth_token_refresh.py`: the new token returned by `get_auth_info`
(fails on the previous code), history list/get/rename/delete using the refreshed
token, no refresh for a non-expiring token, one refresh for concurrent stale
metadata dicts, failure behavior without secrets in logs, missing refresh token,
untouched copilot and anonymous metadata, and cache bounds and eviction. Live
Entra is not covered.

## Documentation impact

`CHANGELOG.md` `[Unreleased]` (Fixed). No README change.

## Review trigger

A change to Chainlit session/cookie handling, the Entra refresh-token policy,
scopes, multiple UI replicas needing a shared cache, or a different token
lifetime.
