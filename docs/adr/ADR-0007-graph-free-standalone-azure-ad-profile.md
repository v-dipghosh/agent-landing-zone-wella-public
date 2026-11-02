# ADR-0007: Graph-free profile lookup for standalone Azure AD sign-in

- Status: Accepted
- Date: 2026-10-31
- Owners: Agent Landing Zone UI maintainers

## Context

Chainlit 2.12.0 `AzureADOAuthProvider.get_user_info` calls
`GET https://graph.microsoft.com/v1.0/me` with the access token returned by the
code exchange and calls `raise_for_status()`. In this UI that token is issued for
the orchestrator API (`api://<API app>/user_impersonation`, see ADR-0006), never
for Graph, so Graph answers 401 "Invalid audience". Chainlit logs
"OAuth callback error" and redirects to `/login?error=oauthSignin`, so standalone
sign-in fails after a successful Entra token exchange. Graph scopes cannot be
added: the UI rejects them on purpose so the orchestrator audience check holds.

`auth.oauth.oauth_callback` never uses `raw_user_data` or `default_user.identifier`.
It needs only `default_user.metadata["refresh_token"]`, performs its own MSAL
refresh exchange, and takes `tid`, `oid`, `preferred_username`, and `name` from the
MSAL `id_token_claims`, then validates the GUIDs, applies the allowlist, and
returns its own `cl.User` or `None`.

## Prioritized characteristics

| Characteristic | Priority | Measure or fitness function |
| --- | --- | --- |
| Security | 5 | No new identity source; scope, Graph-scope, allowlist, and `tid`/`oid` checks unchanged. |
| Compatibility | 4 | Only the Azure AD provider's profile lookup changes; routes, SSE, sessions, persistence unchanged. |
| Reversibility | 4 | Remove one installer call. |

## Alternatives

### Option A: Install a network-free `get_user_info` when OAuth is configured (selected)

- Benefits: Removes the failing call; no Graph permission, scope, or token needed.
- Costs and risks: Monkey-patches a third-party class attribute; must be rechecked
  on Chainlit upgrades.
- Security and identity: The replacement returns `({}, User)` with a fixed
  non-identifying placeholder identifier (`azure-ad-pending`), `provider`, the
  provider's refresh token, and `image: None`. It makes no HTTP call and does not
  decode or trust token claims.

### Option B: Request Graph `User.Read` as well

Rejected: it yields a Graph-audience token, which the orchestrator rejects, and the
UI rejects Graph scopes by design.

### Option C: Decode the access token for identity

Rejected: unverified claims must never establish identity.

### Do not change

Standalone sign-in stays broken.

## Decision

Add `install_graph_free_azure_ad_profile()` to `gpt_rag_ui/auth/oauth.py`. It
replaces `chainlit.oauth_providers.AzureADOAuthProvider.get_user_info` (class
attribute, so the already-created provider instance is affected) and is idempotent
(returns `False` when already installed). `bootstrap._create_chainlit_app` calls it
right after `chainlit.server` is imported, only when `auth_state.oauth_configured`
is true, i.e. after the OAuth environment is configured. Chainlit reads provider
environment in `__init__`; the class-attribute patch is independent of that.
Anonymous mode without OAuth and auth-required startup never reach the installer;
Copilot/embed paths are untouched. Applies to single and split registrations
(ADR-0006) alike.

## Security analysis

- Identity comes only from MSAL-validated `id_token_claims` inside `oauth_callback`.
- The placeholder is never a session. Chainlit's callback route
  (`chainlit/server.py`) authenticates only the value returned by
  `config.code.oauth_callback`; `None` or an exception redirects to
  `/login?error=oauthSignin` without `_authenticate_user`. `oauth_callback` returns
  a new `cl.User` built from claims, or `None` when unauthorized, and raises on
  missing refresh token, invalid `tid`/`oid`, or scope misconfiguration.
- No check is weakened: exact API scope, Graph-scope rejection, allowlist, and
  GUID validation are unchanged. The profile photo is no longer fetched.

## Consequences

### Positive

- Standalone sign-in no longer depends on Graph audience; one fewer outbound call.

### Negative

- The Chainlit user avatar from Graph is dropped.
- Depends on Chainlit's `AzureADOAuthProvider` shape; tests drive the real class.

## Adoption, migration, and recovery

No migration or configuration. Rollback: remove the installer call from
`bootstrap.py` (restores Chainlit's Graph lookup).

## Compliance verification

`tests/test_oauth_graph_free_profile.py`: idempotent install, zero HTTP calls from
the real provider (control proves the guard detects the original), refresh token
and `azure-ad` provider metadata, missing refresh token still failing in
`oauth_callback`, Chainlit's real callback route refusing unauthorized,
claim-less, and refresh-less sign-ins without authenticating the placeholder, and
bootstrap installing only when OAuth is configured. Live Entra is not covered.

## Documentation impact

`CHANGELOG.md` `[Unreleased]` (Fixed). No README change.

## Review trigger

Chainlit upgrade changing `AzureADOAuthProvider` or the OAuth callback route, or a
need for Graph-backed profile data.
