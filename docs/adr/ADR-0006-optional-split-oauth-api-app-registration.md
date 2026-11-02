# ADR-0006: Optional split UI and API app registrations for standalone OAuth

- Status: Accepted
- Date: 2026-10-28
- Owners: Agent Landing Zone UI maintainers

ADR-0005 was removed and its number is intentionally not reused.

## Context

Standalone Entra sign-in derives the orchestrator API scope from the UI client
id: `api://<OAUTH_AZURE_AD_CLIENT_ID>/user_impersonation`. That requires one app
registration to both sign users in and expose the API. Deployments where the
sign-in app (app A) differs from the API app (app B, Application ID URI
`api://<B>`, scope `user_impersonation`) are rejected with "OAuth scope
misconfiguration", both in the OAuth callback and the refresh path, and the
bootstrap default for `OAUTH_AZURE_AD_SCOPES` requests the wrong scope.

## Prioritized characteristics

| Characteristic | Priority | Measure or fitness function |
| --- | --- | --- |
| Backward compatibility | 5 | Unset setting yields byte-identical scopes and checks; existing tests pass unchanged. |
| Security | 5 | Exact-scope check, Graph-scope rejection, and fail-closed validation are retained. |
| Operability | 3 | One optional key, read like the other `OAUTH_AZURE_AD_*` settings; rollback is unsetting it. |

## Alternatives

### Option A: Optional `OAUTH_AZURE_AD_API_CLIENT_ID` (selected)

- Benefits: Explicit, minimal, one helper shared by bootstrap, callback, and
  refresh; default untouched.
- Costs and risks: One more setting to keep consistent with the backend audience.
- Security and identity: Same checks; the expected scope is derived from a
  validated GUID rather than free text.
- Accessibility and user experience: None.
- Operational consequences: Operators set one key when using split registrations.
- Backend and data compatibility: No wire, session, or persistence change.
- Reversibility: Unset the key.

### Option B: Relax the check to accept any `api://*/user_impersonation`

- Benefits: No new setting.
- Costs and risks: Accepts scopes for arbitrary APIs, weakening the audience guard.
- Security and identity: Rejected; it removes the exact-scope control.
- Reversibility: Easy, but unsafe while deployed.

### Do not change

Split registrations stay unsupported; operators must co-locate the API on the
sign-in app.

## Decision

Add the optional `OAUTH_AZURE_AD_API_CLIENT_ID` setting (process environment
first, then App Configuration). `expected_orchestrator_api_scope` in
`auth/auth_common.py` returns `api://<API id>/user_impersonation` when the value
is set, else the existing `api://<OAUTH_AZURE_AD_CLIENT_ID>/user_impersonation`.
The value must be a lowercase canonical GUID; a set but malformed value raises a
configuration error and never falls back. The helper is used by the bootstrap
default scope string, the OAuth callback, and the MSAL refresh path. The key is
also cleared with the other OAuth variables when OAuth is not configured. The
UI app remains the confidential client; only the requested scope changes.

## Consequences

### Positive

- Split registrations work without weakening validation.
- Default deployments are unchanged.

### Negative

- Operators must ensure the orchestrator accepts the audience of app B.
- A malformed value fails startup (default-scope path) or sign-in rather than degrading.

## Adoption, migration, and recovery

No migration. Set the key only when the UI and API apps differ, grant app A
delegated consent for `api://<B>/user_impersonation`, and confirm the backend
accepts app B as the audience. Rollback: unset the key; behavior returns to the
single-registration default. Hosted-agent OBO and Entra embedding are untouched.

## Compliance verification

`tests/test_oauth_api_scope.py` and `tests/test_main_policy.py` cover unset and
set behavior, precedence of process environment over App Configuration,
acceptance of the exact API-app scope, rejection of UI-app and Graph scopes,
malformed values failing closed, the bootstrap default scope, and
`_clear_oauth_env_vars`. Live Entra behavior is not covered by automated tests.

## Documentation impact

`README.md` (standalone OAuth section) and `CHANGELOG.md` `[Unreleased]`. The
platform repository's deployment documentation should mention the key if it
provisions split registrations.

## Review trigger

Revisit if the orchestrator audience or scope name changes, or if standalone
OAuth moves to a different token model.
