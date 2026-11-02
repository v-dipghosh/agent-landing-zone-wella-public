# Microsoft Entra authentication: setup runbook

This runbook configures real Microsoft Entra sign-in for the Agent Landing Zone
UI and token-based authentication between the UI and the orchestrator.
Chat history belongs to each signed-in user's Entra object ID (`oid`).

Use placeholders until you have verified every value. Do not commit tenant IDs,
app IDs, host names, or secrets to source control.

## 1. How authentication works

Three separate checks protect a chat request.

| Boundary | Credential | Who issues it | Who validates it |
| --- | --- | --- | --- |
| Browser to UI | Chainlit session after Entra sign-in | UI, using an authorization-code flow | UI |
| UI to orchestrator, as the user | `Authorization: Bearer <user access token>` | Entra, for the API app | Orchestrator |
| UI to orchestrator, as the service | `X-Service-Authorization: Bearer <managed identity token>` | Entra, for the UI's managed identity | Orchestrator |

- The user token proves who is asking. Its `oid` partitions chat history in
  Cosmos DB.
- The service token proves the caller is the trusted UI. It does not identify a
  user and cannot read user history by itself.
- The two tokens are validated independently. Each needs its own settings.

### Supported registration model

The UI's sign-in flow requests the scope
`api://<OAUTH_AZURE_AD_CLIENT_ID>/user_impersonation`, and the orchestrator
accepts user tokens whose audience is `<OAUTH_AZURE_AD_CLIENT_ID>` or
`api://<OAUTH_AZURE_AD_CLIENT_ID>`. By default this means **one app
registration** that is both the OAuth client for the UI and the API exposed to
the orchestrator.

Two registrations are also supported, with a UI version that includes the
optional `OAUTH_AZURE_AD_API_CLIENT_ID` setting:

- the **UI client registration** signs users in and holds the UI's client
  secret;
- the **API registration** exposes `user_impersonation` and its Application ID
  URI `api://<api-app-id>`.

The UI then requests `api://<api-app-id>/user_impersonation`. The orchestrator's
`OAUTH_AZURE_AD_CLIENT_ID` is `<api-app-id>`. Section 6.3 lists the settings.
Without `OAUTH_AZURE_AD_API_CLIENT_ID`, the UI keeps the single-registration
behavior.

## 2. Values to collect first

| Placeholder | Meaning | Where to find it |
| --- | --- | --- |
| `<tenant-id>` | Directory (tenant) ID | Entra ID, Overview |
| `<app-id>` | Application (client) ID of the single app registration | App registration, Overview |
| `<ui-host>` | Public host name of the UI Container App | Container App, Ingress |
| `<ui-identity-oid>` | Object (principal) ID of the UI's managed identity | Container App, Identity |
| `<app-config>` | App Configuration store name | Azure portal |
| `<key-vault>` | Key Vault name | Azure portal |

## 3. Configure the app registration

Use one registration for the UI and the API. Choose a dedicated registration if
you can: changes to a registration that another application also uses affect
that application. Before editing a shared registration, check its redirect URIs,
scopes, and secrets for other users.

### 3.1 Create or select the registration

1. Open Microsoft Entra ID, App registrations.
2. Create a new registration, or open the one assigned to this deployment.
3. Set Supported account types to **Single tenant**.
4. Record the Application (client) ID as `<app-id>`.

### 3.2 Expose the API

1. Open Expose an API.
2. Set the Application ID URI to `api://<app-id>`.
   The portal's default value is correct.
3. Add a scope with these values:

   | Field | Value |
   | --- | --- |
   | Scope name | `user_impersonation` |
   | Who can consent | Admins and users |
   | Admin and user consent display names and descriptions | Short text, such as "Access the Agent Landing Zone API" |
   | State | Enabled |

The scope name must be exactly `user_impersonation`. A different name, such as
`access_as_user`, makes the UI reject the sign-in configuration.

The access token version can stay at its default. The orchestrator accepts the
audience in both forms and both Entra issuer forms.

### 3.3 Register the sign-in redirect URI

1. Open Authentication, then Add a platform, then **Web**.
2. Add this redirect URI:

   ```text
   https://<ui-host>/auth/oauth/azure-ad/callback
   ```

3. Do not add it under **Single-page application**. The UI signs in with a
   client secret, which requires the Web platform. A Single-page entry gives
   cross-origin or redirect errors.
4. Leave implicit grant and hybrid flow options off.

The host and path must match `CHAINLIT_URL` exactly, including HTTPS and no
extra path segment.

### 3.4 Set API permissions

1. Open API permissions.
2. Keep only what sign-in needs: Microsoft Graph delegated `openid` and
   `profile`, and this API's own `user_impersonation`. `User.Read` is not
   required.
3. Remove unrelated entries. For example, an Azure Cognitive Search
   `user_impersonation` permission is a different API and does not authorize
   this one.
4. Grant admin consent if your tenant policy blocks user consent. Otherwise,
   users consent at their first sign-in.

### 3.5 Create a client secret

1. Open Certificates and secrets, then New client secret.
2. Choose an expiry that matches your rotation policy.
3. Copy the secret value once, straight into Key Vault (next section). Do not
   paste it into chat, tickets, or source control.

## 4. Store the secrets

1. In `<key-vault>`, create a secret for the UI's client secret. Use a name such
   as `oauth-azure-ad-client-secret`.
2. If the orchestrator uses on-behalf-of retrieval, it needs the same
   registration's secret. Reuse the same Key Vault secret and reference it from
   both services' labels.
3. In `<app-config>`, add `OAUTH_AZURE_AD_CLIENT_SECRET` as a **Key Vault
   reference** under both labels (section 6).
4. Give each service's managed identity the **Key Vault Secrets User** role on
   the vault, or on that secret. A service without it cannot resolve the
   reference.
5. Create a separate persistent secret for `CHAINLIT_AUTH_SECRET`, at least 32
   bytes, for the UI. It signs UI sessions. A new value on each start signs
   every user out.

## 5. Configure UI-to-orchestrator service authentication

The UI's system-assigned managed identity authenticates the service call.

1. Record the UI Container App's identity object ID as `<ui-identity-oid>`.
2. The UI requests a token for `api://<app-id>/.default` using that identity.
   Do not set the UI's `AZURE_CLIENT_ID` environment variable to an app
   registration ID. That variable selects a user-assigned managed identity.
3. The orchestrator validates the token's issuer, audience, and caller. Its
   allowlist holds the UI identity's object ID.
4. If Entra refuses to issue a token for the API, define an application role on
   the registration and assign it to the UI's managed identity. Tenant policy
   decides whether this is required, so verify it in your tenant.
5. Remove `ORCHESTRATOR_APP_APIKEY` and any `DAPR_API_TOKEN` from every label
   and environment source. Do not rely on them as fallbacks.

## 6. App Configuration

Use service-specific labels so the UI and orchestrator can differ.

### UI, label `agent-app-ui`

| Key | Value |
| --- | --- |
| `OAUTH_AZURE_AD_CLIENT_ID` | `<app-id>` |
| `OAUTH_AZURE_AD_TENANT_ID` | `<tenant-id>` |
| `OAUTH_AZURE_AD_CLIENT_SECRET` | Key Vault reference |
| `OAUTH_AZURE_AD_ENABLE_SINGLE_TENANT` | `true` |
| `OAUTH_AZURE_AD_SCOPES` | `api://<app-id>/user_impersonation openid profile offline_access` |
| `ORCHESTRATOR_AUTH_AUDIENCE` | `api://<app-id>` |
| `CHAINLIT_URL` | `https://<ui-host>` |
| `CHAINLIT_AUTH_SECRET` | Key Vault reference |
| `CHAT_BACKEND` | `orchestrator` |
| `ORCHESTRATOR_BASE_URL` | Orchestrator HTTPS root URL |
| `ALLOW_ANONYMOUS` | `false` |

`OAUTH_AZURE_AD_SCOPES` is passed to Entra unchanged, so separate the scopes
with **spaces**. Commas make Entra treat the list as one invalid scope. Do not
add Microsoft Graph scopes: a Graph token cannot satisfy the orchestrator's
audience check.

### Orchestrator, label `agent-app-orchestrator`

| Key | Value |
| --- | --- |
| `OAUTH_AZURE_AD_CLIENT_ID` | `<app-id>` |
| `OAUTH_AZURE_AD_TENANT_ID` | `<tenant-id>` |
| `OAUTH_AZURE_AD_CLIENT_SECRET` | Key Vault reference, only if you use OBO retrieval |
| `ORCHESTRATOR_AUTH_AUDIENCE` | `api://<app-id>` |
| `ORCHESTRATOR_ALLOWED_CALLER_IDS` | `<ui-identity-oid>` |
| `ALLOW_ANONYMOUS` | `false` |

`AZURE_TENANT_ID` can be set as an environment variable instead. Do not set
`DISABLE_AUTH` to `true`.

### 6.3 Split UI client and API registrations

Use this model when the UI signs in with one registration and a different
registration exposes the API. In the tables above, use these values instead:

| Label | Key | Value |
| --- | --- | --- |
| `agent-app-ui` | `OAUTH_AZURE_AD_CLIENT_ID` | `<ui-client-app-id>` |
| `agent-app-ui` | `OAUTH_AZURE_AD_CLIENT_SECRET` | Key Vault reference to the **UI client registration's** secret |
| `agent-app-ui` | `OAUTH_AZURE_AD_API_CLIENT_ID` | `<api-app-id>`, a lowercase GUID |
| `agent-app-ui` | `OAUTH_AZURE_AD_SCOPES` | `api://<api-app-id>/user_impersonation openid profile offline_access` |
| `agent-app-ui` | `ORCHESTRATOR_AUTH_AUDIENCE` | `api://<api-app-id>` |
| `agent-app-orchestrator` | `OAUTH_AZURE_AD_CLIENT_ID` | `<api-app-id>` |
| `agent-app-orchestrator` | `OAUTH_AZURE_AD_CLIENT_SECRET` | Key Vault reference to the **API registration's** secret, only if you use OBO retrieval |
| `agent-app-orchestrator` | `ORCHESTRATOR_AUTH_AUDIENCE` | `api://<api-app-id>` |

Entra changes for this model:

1. On the API registration, set the Application ID URI to
   `api://<api-app-id>` and add the enabled `user_impersonation` scope.
2. On the UI client registration, add a delegated permission for that scope and
   grant consent according to tenant policy. Optionally add the UI client under
   the API's **Authorized client applications**.
3. Register the Web redirect URI (section 3.3) on the **UI client**
   registration.

The two registrations have separate secrets. The UI uses the client
registration's secret to sign users in, and the orchestrator uses the API
registration's secret for on-behalf-of calls. An API registration's own
permissions, such as Azure Cognitive Search `user_impersonation`, are what it
may call. They don't create the `user_impersonation` scope that the UI
requests from it.

Malformed `OAUTH_AZURE_AD_API_CLIENT_ID` values (for example uppercase
GUIDs or `api://...` URIs) stop the UI at startup. Unsetting the key restores
the single-registration behavior. This setting requires a UI build that
contains it.

Check for conflicting values before you test:

- A same-named environment variable on either Container App overrides App
  Configuration.
- A shared label, such as `agent-lz`, may supply a value you did not intend.
- Type values rather than copying them from a truncated portal field. A pasted
  ellipsis or a trailing space silently changes the value.

Restart both services after any change.

## 7. Validate

### 7.1 Configuration checks

1. Run `az ad app show --id <app-id>` and confirm the Application ID URI is
   `api://<app-id>` and the scope `user_impersonation` is enabled.
2. Confirm the redirect URI is under the Web platform, not Single-page.
3. Confirm the stored scopes value has no non-ASCII characters.

### 7.2 Sign-in and history

1. Open the UI in a private browser window.
2. Sign in through Microsoft Entra and accept the consent prompt, if shown.
3. Send a message, reload the page, and reopen it from history.
4. In the Cosmos DB conversations container, confirm `principal_id` equals the
   signed-in user's `oid`. It must not be an app ID or a managed identity ID.
5. Sign in as a second user. The first user's conversations must not appear.

### 7.3 Negative checks

- A request with the service token and no user token returns 401.
- A request with a user token and no service token returns 401.
- A token from another app or tenant returns 401.
- Neither `X-API-KEY` nor `dapr-api-token` grants access.

Do not share access tokens or cookies when asking for help. Share the HTTP
status and the Entra error code instead.

## 8. Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| `AADSTS500011`: resource principal named `api://...` not found | The scope contains a wrong or truncated resource URI, or the registration and its service principal are missing | Compare `OAUTH_AZURE_AD_SCOPES` character by character with `api://<app-id>/user_impersonation`; retype it |
| `AADSTS70011` or an invalid scope error | Scope name does not exist on the API, or scopes are comma-separated | Create `user_impersonation`; separate scopes with spaces |
| `AADSTS50011`: redirect URI does not match | Redirect URI is missing or on the wrong platform | Add the exact Web redirect URI from section 3.3 |
| `AADSTS9002326`: cross-origin token redemption | Redirect URI is registered as Single-page | Move it to the Web platform |
| `AADSTS7000215` or `AADSTS7000222`: invalid or expired client secret | Wrong secret value, wrong app, or expired secret | Store a current secret issued by the **UI client** registration (`<app-id>` in the single model) and restart |
| `AADSTS650053`: scope `user_impersonation` does not exist on resource `<id>` | The API registration named in the scope has no `user_impersonation` scope. Its **API permissions** page only lists what it calls | On that registration's **Expose an API** page, add an enabled `user_impersonation` scope |
| `AADSTS65001`: consent required | User or admin consent not given | Grant admin consent, or let the user consent |
| UI logs `expected API scope is missing` | `OAUTH_AZURE_AD_SCOPES` lacks `api://<OAUTH_AZURE_AD_CLIENT_ID>/user_impersonation` | Fix the value, and make sure the client ID matches |
| UI logs `Graph scopes detected` | A Microsoft Graph scope is configured | Remove it |
| Orchestrator 401 `Invalid token` | User token audience or tenant does not match | Check `OAUTH_AZURE_AD_CLIENT_ID` and `OAUTH_AZURE_AD_TENANT_ID` on the orchestrator label |
| Orchestrator 401 `Caller not allowed` | Managed identity ID missing from the allowlist | Set `ORCHESTRATOR_ALLOWED_CALLER_IDS` to `<ui-identity-oid>` |
| Orchestrator 401 `Service authentication not configured` | Tenant, audience, or caller list is empty | Set all three on the orchestrator |
| UI cannot get a service token | Identity cannot request the API token | Check section 5, step 4, and the UI's logs |
| Key Vault reference does not resolve | Missing role or wrong secret URI | Assign Key Vault Secrets User and check the reference |

## 9. Rotation and rollback

- **Rotate the client secret:** create a second secret in Entra, store it as a
  new Key Vault version, restart both services, then delete the old secret.
- **Roll back a configuration change:** restore the previous App Configuration
  value, then restart both services. No Cosmos DB migration is involved.
- **User data:** conversations stay under each user's `oid` and are unaffected by
  these settings.

## 10. Demo-only retrieval override

If the API registration cannot yet be consented for Azure AI Search, set
`RETRIEVAL_SERVICE_ONLY_OVERRIDE=true` on the `agent-app-orchestrator` label and
restart the orchestrator. With the `maf_lite` strategy and the `ai_search`
backend, retrieval then uses the orchestrator's own identity and skips the
per-user token exchange. Sign-in and chat history still require a signed-in
user.

Effects while it is on:

- Every signed-in user can retrieve any document in the configured index, so use
  it only with a non-sensitive demo index.
- Document-level access fields in the index are not applied. The conversation
  filter for chat-scoped content still applies.
- The orchestrator logs `RETRIEVAL_SERVICE_ONLY_OVERRIDE is enabled` on each
  retrieval.
- Foundry IQ and other strategies ignore it.

Remove the setting, or set it to `false`, and restart to return to per-user
authorization. Grant admin consent for the API registration's Azure Cognitive
Search `user_impersonation` permission before removing it.

## 11. Notes on this guide

- This is a service-local guide. It has not been published to the Agent Landing
  Zone documentation site, so coordinate any publication with the documentation
  owner. See the
  [published documentation](https://azure.github.io/AI-Landing-Zones/agent-landing-zone/).
- Related decision:
  [ADR-0019, keyless orchestrator authentication](https://github.com/Azure/agent-landing-zone/blob/main/docs/adr/ADR-0019-keyless-orchestrator-auth.md).
- Live sign-in, consent, managed-identity token issuance, and Cosmos DB
  persistence still need acceptance testing in your deployment.
