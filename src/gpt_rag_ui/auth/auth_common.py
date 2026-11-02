import logging
import uuid

from gpt_rag_ui.config.appconfig import AppConfigClient
from gpt_rag_ui.config.errors import ConfigurationError


logger = logging.getLogger("gpt_rag_ui.auth_common")

OAUTH_API_CLIENT_ID_SETTING = "OAUTH_AZURE_AD_API_CLIENT_ID"
ORCHESTRATOR_API_SCOPE_NAME = "user_impersonation"


def expected_orchestrator_api_scope(
    ui_client_id: str,
    api_client_id: str | None = None,
) -> str:
    """Return the exact orchestrator API scope standalone OAuth must request.

    By default the UI sign-in app also exposes the API, so the scope is
    ``api://<ui_client_id>/user_impersonation``. When the optional split
    registration setting ``OAUTH_AZURE_AD_API_CLIENT_ID`` is provided, the API
    is exposed by that separate app and the scope is derived from it instead.

    An unset or empty ``api_client_id`` selects the default. Any other value
    must be a lowercase canonical GUID; anything else fails closed rather than
    silently falling back to the UI client id. The rejected value is never
    echoed in the error.
    """

    if api_client_id is None or api_client_id == "":
        return f"api://{ui_client_id}/{ORCHESTRATOR_API_SCOPE_NAME}"

    try:
        canonical = str(uuid.UUID(api_client_id))
    except (AttributeError, ValueError):
        canonical = None
    if canonical != api_client_id:
        raise ConfigurationError(
            f"{OAUTH_API_CLIENT_ID_SETTING} must be the API app's Application "
            "(client) ID as a lowercase canonical GUID "
            "(xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx), not an api:// URI, URL, "
            "or padded/uppercase value. Unset the setting to use "
            "OAUTH_AZURE_AD_CLIENT_ID."
        )
    return f"api://{api_client_id}/{ORCHESTRATOR_API_SCOPE_NAME}"


def normalize_guid(value: str, *, claim_name: str) -> str:
    try:
        return str(uuid.UUID(str(value or "").strip()))
    except (AttributeError, ValueError) as exc:
        raise ValueError(f"{claim_name} must be a GUID.") from exc


def canonical_principal_id(tenant_id: str, object_id: str) -> str:
    tenant = normalize_guid(tenant_id, claim_name="tid")
    principal = normalize_guid(object_id, claim_name="oid")
    return f"{tenant}:{principal}"


def _read_list(config: AppConfigClient, key: str) -> list[str]:
    value = config.get(key, "", str) or ""
    return [item.strip() for item in value.split(",") if item.strip()]


def is_user_authorized(
    config: AppConfigClient,
    principal_name: str,
    principal_id: str,
) -> bool:
    allowed_names = {
        value.casefold() for value in _read_list(config, "ALLOWED_USER_NAMES")
    }
    allowed_ids = {
        value.lower() for value in _read_list(config, "ALLOWED_USER_PRINCIPALS")
    }

    if not (allowed_names or allowed_ids):
        return True

    normalized_principal_id = str(principal_id or "").strip().lower()
    candidate_ids = {normalized_principal_id}
    if ":" in normalized_principal_id:
        _, object_id = normalized_principal_id.split(":", 1)
        if object_id:
            # Existing deployments commonly allow-list a bare oid. Keep
            # accepting it while storing the tenant-qualified identity.
            candidate_ids.add(object_id)

    if (
        str(principal_name or "").strip().casefold() in allowed_names
        or not candidate_ids.isdisjoint(allowed_ids)
    ):
        return True

    logger.warning(
        "Access denied for principal '%s' (%s). No matching allow list entry.",
        principal_name,
        principal_id,
    )
    return False
