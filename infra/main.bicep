// ============================================================================
// AI Landing Zone Bicep Deployment Template
// This infrastructure-as-code template follows best practices for modular,
// reusable, and configuration-aware deployments. Key principles:
//
// - **AZD Integration**: This template is optimized for use with the Azure Developer CLI (`azd`).
//   Use `azd provision` to deploy infrastructure and `azd deploy` to deploy your application.
//   It supports automated, repeatable, and configuration-aware workflows. The `main.json` file
//   can include placeholders (e.g., `${AZURE_LOCATION}`, `${AZURE_PRINCIPAL_ID}`) that are automatically
//   injected by `azd` during execution, enabling seamless parameter resolution.
//
// - **Parameterization**: All configuration values are defined in `main.json`.
//   You can create multiple parameter files to support different deployment configurations,
//   such as variations in scale, resource combinations, or cost constraints.
//
// - **Feature Flags**: Resource provisioning is modular and controlled via feature flags
//   (e.g., `deployAppConfig`). This enables selective deployment of components based on project needs.
//
// - **Azure Verified Modules (AVM)**: Official AVM modules are used as the foundation
//   for resource deployment, ensuring consistency, maintainability, and alignment with Microsoft standards.
//   Reference: https://azure.github.io/Azure-Verified-Modules/indexes/bicep/bicep-resource-modules/
//   When AVM does not cover a specific resource, custom Bicep module is used as fallback.
//
// - **Output Exposure**: Key outputs such as connection strings, endpoints, and resource IDs
//   are exposed as Bicep outputs and can be consumed by downstream processes or deployment scripts.
//
// - **Post-Provisioning Automation**: Supports optional post-provisioning scripts to perform data plane
//   operations or additional configurations. These scripts can run independently or as `azd` hooks,
//   enabling fine-grained control and custom automation after infrastructure deployment.
//
// ============================================================================

targetScope = 'resourceGroup'

//////////////////////////////////////////////////////////////////////////
// PARAMETERS
//////////////////////////////////////////////////////////////////////////

// Important notes about parameters:
// 1) Before running azd provision, set parameter values using main.parameters.json or 
// the command line: azd env set ENV_VARIABLE_NAME value, for parameters configured to allow substitution.
//
// 2) You can identify these substitutable parameters in main.parameters.json by this format:
// "parameterName": { "value": "${ENV_VARIABLE_NAME}" }.
// This allows the convenience of setting values via the command line (e.g., azd env set ENV_VARIABLE_NAME true).
//
// 3) Substitutable parameters: if an environment variable isn’t set before running `azd provision`, its value will be empty.
// To prevent this, each parameter that uses the substitution mechanism has a corresponding Bicep variable (`_parameterName`) with a default value.
// When adding new substitutable parameters in this Bicep file or in `main.parameters.bicep`, follow the same pattern.

// ---------------------------------------------------------------------
// Imports
// ----------------------------------------------------------------------
import * as const from 'constants/constants.bicep'
import * as storageTypes from 'constants/storage-types.bicep'

// ----------------------------------------------------------------------
// General Parameters
// ----------------------------------------------------------------------

@description('Name of the Azure Developer CLI environment')
param environmentName string

@description('The Azure region where your resources will be created.')
param location string = resourceGroup().location

@description('The Azure region where Cosmos DB will be created. Defaults to the resource group location.')
param cosmosLocation string = resourceGroup().location

@description('The Azure region where Azure AI Search services will be created. Defaults to the main deployment location. Override this when the primary region is out of capacity for AI Search.')
param searchServiceLocation string = ''

@description('The Azure region where the Azure AI Speech service will be created. Defaults to the main deployment location.')
param speechServiceLocation string = ''

@description('Principal ID for role assignments. This is typically the Object ID of the user or service principal running the deployment.')
param principalId string

@description('Principal type for role assignments. This can be "User", "ServicePrincipal", or "Group".')
param principalType string = 'User'

@description('Tags to apply to all resources in the deployment')
param deploymentTags object = {}

@description('Label used for App Configuration key-value pairs.')
param appConfigLabel string = 'ai-lz'

@description('Optional. Accelerator-specific App Configuration key-values appended verbatim to the App Configuration store. This lets a consuming accelerator publish its own settings without the landing zone needing to know about them. Values are stored as plaintext in App Configuration, so never pass secrets here (use Key Vault references instead). Each entry must have a unique name+label. On a name+label collision with a workload configuration key the landing zone already emits, the passthrough entry wins. Do not redefine reserved infrastructure keys emitted by other modules (the Cosmos identifiers COSMOS_DB_ACCOUNT_RESOURCE_ID and COSMOS_DB_ENDPOINT, and the per-app <APP>_APIKEY Key Vault references); reusing those names would create a duplicate key-value and fail the deployment. Note: this is only applied on non network-isolated deployments, where the landing zone writes App Configuration at deploy time. Network-isolated deployments configure App Configuration from the accelerator post-provision step, so pass these values through that path instead.')
param additionalAppConfigurationSettings additionalAppConfigurationSettingType[] = []

@description('Enable network isolation for the deployment. This will restrict public access to resources and require private endpoints where applicable.')
param networkIsolation bool = false

@description('Gap 8 — Deployment topology preset. Required to surface deployment intent explicitly. Allowed values: `standalone` (default — self-contained spoke, own firewall/bastion/NAT GW; suitable for sandbox or single-team subscriptions) or `ailz-integrated` (spoke designed to plug into an Azure Landing Zone-managed hub; consumer is expected to provide `hubIntegrationHubVnetResourceId`, `hubIntegrationEgressNextHopIp` and/or `hubIntegrationExistingRouteTableResourceId`, BYO Private DNS overrides, and optionally `existingLogAnalyticsWorkspaceResourceId` for centralized observability). The value is captured as a `deploymentMode` tag on the resource group so platform teams can audit deployment posture. The preset does NOT automatically override explicit operator flags; it primarily documents intent and powers the pre-flight script (`scripts/Invoke-PreflightChecks.ps1`, Gap 9).')
@allowed([
  'standalone'
  'ailz-integrated'
])
param deploymentMode string = 'standalone'

@description('Optional. When non-empty, opens each services public surface restricted to these CIDRs via native `ipRules` / `networkAcls.ipRules`. Empty (default) means no public allow-list. Applied to Storage, Key Vault, Cosmos DB, AI Search, Container Registry, and the AI Foundry / Cognitive Services accounts. App Configuration and Application Insights do not expose native ipRules and ignore this parameter (documented in docs/v2-migration.md). When `networkIsolation=true` AND `allowedIpRanges` is non-empty, services are switched to `publicNetworkAccess=Enabled` so the IP rules can take effect (defense-in-depth alongside private endpoints).')
param allowedIpRanges string[] = []

@description('''When set to true, Private DNS Zones and DNS zone groups will NOT be created by this module.
Use this option in environments where Azure Policy automatically manages Private DNS Zone linking for private endpoints
(e.g., CAF Enterprise-Scale Platform Landing Zone). Creating DNS zones in those environments causes conflicts with
policy-driven DNS management and results in deployment failures.
When false (default), the module creates and manages all Private DNS Zones and links them to the VNet.
Requires networkIsolation to be true to have any effect.''')
param policyManagedPrivateDns bool = false

// ----------------------------------------------------------------------
// Gap 2 — BYO Private DNS Zones (granular per-namespace overrides)
// ----------------------------------------------------------------------
// For each Private DNS zone the landing zone normally creates, an
// `existingPrivateDnsZone<Namespace>ResourceId` param accepts a full
// resource ID. When provided:
//   * The zone is NOT created by this deployment.
//   * The zone is NOT linked from the spoke VNet (assumed pre-linked via
//     the hub or another mechanism; cross-RG linking is an operator task
//     in v2.0.0 — see docs/v2-migration.md).
//   * The provided resource ID is used directly in every Private
//     Endpoint DNS Zone Group that consumes the zone, so PE→FQDN
//     resolution still works against the shared zone.
// `policyManagedPrivateDns=true` continues to win — when it is set,
// neither creation nor linking happens for any zone regardless of these
// BYO params (the pre-flight script flags this as a misconfiguration).

@description('Gap 2 — Resource ID of an existing `privatelink.cognitiveservices.azure.com` Private DNS Zone to reuse (Azure AI Foundry / Cognitive Services PE DNS). When set, the local zone is not created. Pre-link the zone to the spoke VNet (or rely on hub→spoke peering + hub-side link) — automatic spoke linking is not performed.')
param existingPrivateDnsZoneCogSvcsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.openai.azure.com` Private DNS Zone to reuse (Azure OpenAI PE DNS).')
param existingPrivateDnsZoneOpenAiResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.services.ai.azure.com` Private DNS Zone to reuse (AI Services / Foundry PE DNS).')
param existingPrivateDnsZoneAiServicesResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.search.windows.net` Private DNS Zone to reuse (Azure AI Search PE DNS).')
param existingPrivateDnsZoneSearchResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.documents.azure.com` Private DNS Zone to reuse (Azure Cosmos DB PE DNS).')
param existingPrivateDnsZoneCosmosResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.blob.<storage suffix>` Private DNS Zone to reuse (Azure Storage Blob PE DNS).')
param existingPrivateDnsZoneBlobResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.vaultcore.azure.net` Private DNS Zone to reuse (Azure Key Vault PE DNS).')
param existingPrivateDnsZoneKeyVaultResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.azconfig.io` Private DNS Zone to reuse (Azure App Configuration PE DNS).')
param existingPrivateDnsZoneAppConfigResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.<region>.azurecontainerapps.io` Private DNS Zone to reuse (Azure Container Apps PE DNS). Region-specific zone — must match the deployment region.')
param existingPrivateDnsZoneContainerAppsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.azurecr.io` Private DNS Zone to reuse (Azure Container Registry PE DNS).')
param existingPrivateDnsZoneAcrResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.monitor.azure.com` Private DNS Zone to reuse (Azure Monitor Private Link Scope PE DNS).')
param existingPrivateDnsZoneAzureMonitorResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.oms.opinsights.azure.com` Private DNS Zone to reuse (OMS Log Analytics PE DNS).')
param existingPrivateDnsZoneOmsOpsInsightsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.ods.opinsights.azure.com` Private DNS Zone to reuse (ODS Log Analytics ingestion PE DNS).')
param existingPrivateDnsZoneOdsOpsInsightsResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.agentsvc.azure.automation.net` Private DNS Zone to reuse (Azure Monitor agent service PE DNS).')
param existingPrivateDnsZoneAzureAutomationResourceId string?

@description('Gap 2 — Resource ID of an existing `privatelink.applicationinsights.io` Private DNS Zone to reuse. Only consumed when `enablePrivateLogAnalytics=true` and AMPLS is created locally; otherwise this BYO ID is ignored.')
param existingPrivateDnsZoneAppInsightsResourceId string?

@description('The Azure region where private endpoints will be created. Defaults to the main deployment location. Use this when your VNet is in a different region than the resources.')
param privateEndpointLocation string = ''

@description('The name of the resource group where private endpoints will be created. When empty, private endpoints are placed in the VNet resource group (for existing VNets with sideBySideDeploy disabled) or the deployment resource group.')
param privateEndpointResourceGroupName string = ''

@description('Use an existing Virtual Network. When false, a new VNet will be created.')
param useExistingVNet bool = false

@description('The full ARM resource ID of an existing Virtual Network. Format: /subscriptions/{subscriptionId}/resourceGroups/{resourceGroupName}/providers/Microsoft.Network/virtualNetworks/{vnetName}. Leave empty to create a new VNet.')
param existingVnetResourceId string = ''

param agentSubnetName string = 'agent-subnet'
param peSubnetName string = 'pe-subnet'
param gatewaySubnetName string = 'gateway-subnet'
param azureBastionSubnetName string = 'AzureBastionSubnet'
param azureFirewallSubnetName string = 'AzureFirewallSubnet'
param azureAppGatewaySubnetName string = 'AppGatewaySubnet'
param jumpboxSubnetName string = 'jumpbox-subnet'
param acaEnvironmentSubnetName string = 'aca-environment-subnet'
param devopsBuildAgentsSubnetName string = 'devops-build-agents-subnet'

@description('Address prefixes for the virtual network.')
param vnetAddressPrefixes array = [
  '192.168.0.0/21' // 192.168.0.0 – 192.168.7.255 (2048 IPs total)
]

@description('Gap 3 — Optional suffix appended to every Private DNS zone VNet link name created by this deployment. Set to a unique value (e.g., the spoke name or environment short-code) when multiple spokes link to the same shared Private DNS zone — without a unique suffix the link name collides and the second deployment fails. Leave empty for single-spoke or non-shared-zone deployments. Final link name: `<vnetName>-<zone-shortcode>-link<suffix>[<-byon if useExistingVNet>]`. Forbidden characters per Microsoft.Network/privateDnsZones/virtualNetworkLinks: must be 1–80 chars, alphanumeric / hyphens / underscores only.')
param dnsZoneLinkSuffix string = ''

//
// Subnet allocations (non-overlapping, optimized for production workloads)
// PE subnet increased to /26 to support multiple Private Endpoints without race conditions
//

@description('AI Foundry Agents subnet — Recommended /24 (256 IPs)')
param agentSubnetPrefix string = '192.168.0.0/24' // 192.168.0.0–192.168.0.255

@description('Azure Container Apps Environment subnet — /24 (256 IPs)') // Recommended minimum is /23
param acaEnvironmentSubnetPrefix string = '192.168.1.0/24' // 192.168.1.0–192.168.1.255

@description('Private Endpoints subnet — /26 (64 IPs) — Increased to prevent race conditions during parallel PE creation')
param peSubnetPrefix string = '192.168.2.0/26' // 192.168.2.0–192.168.2.63

@description('Azure Bastion subnet — Required /26 (64 IPs, CIDR-aligned)')
param azureBastionSubnetPrefix string = '192.168.2.64/26' // 192.168.2.64–192.168.2.127

@description('Azure Firewall subnet — /26 (64 IPs, CIDR-aligned)')
param azureFirewallSubnetPrefix string = '192.168.2.128/26' // 192.168.2.128–192.168.2.191

@description('Gateway subnet — Required /26 (64 IPs, CIDR-aligned)')
param gatewaySubnetPrefix string = '192.168.2.192/26' // 192.168.2.192–192.168.2.255

@description('Application Gateway subnet — /27 (32 IPs)')
param azureAppGatewaySubnetPrefix string = '192.168.3.0/27' // 192.168.3.0–192.168.3.31

@description('Jumpbox subnet — /27 (32 IPs)')
param jumpboxSubnetPrefix string = '192.168.3.64/27' // 192.168.3.64–192.168.3.95

@description('DevOps Build Agents subnet — /27 (32 IPs)')
param devopsBuildAgentsSubnetPrefix string = '192.168.3.96/27' // 192.168.3.96–192.168.3.127

// ----------------------------------------------------------------------
// Feature-flagging Params (as booleans with a default of true)
// ----------------------------------------------------------------------

// @description('If false, skips creating platform infrastructure such as Firewall, Jumpbox, Bastion, etc.')
// param greenFieldDeployment bool = true

@description('Whether to deploy Bing-powered grounding capabilities alongside your AI services.')
param deployGroundingWithBing bool = true

@description('Deploy Azure AI Foundry for building and managing AI models.')
param deployAiFoundry bool = true

@description('Deploy Azure AI Foundry agent subnet.')
param deployAiFoundrySubnet bool = true

@description('Deploy Azure App Configuration for centralized feature-flag and configuration management.')
param deployAppConfig bool = true

@description('How the landing zone should provide runtime configuration to the external Container Apps. ``appConfig`` (default) preserves the existing behavior: an Azure App Configuration store is populated with deployment outputs and each Container App receives an ``APP_CONFIG_ENDPOINT`` env var plus the ``App Configuration Data Reader`` RBAC. ``containerEnv`` skips the App Configuration population and instead injects a small set of bootstrap env vars (tenant, subscription, resource group, location, resource token, network/identity flags, plus the names of the deployed resources) directly on every Container App so consumers can resolve endpoints via SDK without going through App Configuration. ``none`` deploys the Container App shells with only the identity bootstrap env vars (``AZURE_TENANT_ID`` and ``AZURE_CLIENT_ID`` when applicable); callers are expected to supply runtime configuration through their own mechanism. Secrets are always sourced from secure parameters or Key Vault references regardless of mode. Set ``deployAppConfig=false`` to skip the store entirely when the mode is ``containerEnv`` or ``none``.')
@allowed([
  'appConfig'
  'containerEnv'
  'none'
])
param appRuntimeConfigurationMode string = 'appConfig'

@description('Deploy an Azure Key Vault to securely store secrets, keys, and certificates.')
param deployKeyVault bool = true

@description('Deploy an Azure Key Vault to securely store VM secrets, keys, and certificates.')
param deployVmKeyVault bool = false

@description('Deploy an Azure Log Analytics workspace for centralized log collection and query.')
param deployLogAnalytics bool = true

@description('Resource ID of an existing Log Analytics workspace to reuse instead of creating one (Gap 5). When non-empty, no LAW is created in this deployment and all diagnostic settings, AMPLS linkage, and App Configuration entries point at this central workspace. Cross-RG and cross-subscription IDs are supported.')
param existingLogAnalyticsWorkspaceResourceId string?

@description('When network isolation is enabled, also deploy an Azure Monitor Private Link Scope (AMPLS) with private endpoints and the related monitor/opinsights/automation private DNS zones to keep Log Analytics + Application Insights traffic on the private network. Disable to opt-out and avoid sharing those Azure Monitor private DNS zones with other workloads (preventing cross-workload DNS conflicts). Has no effect when networkIsolation is false or when an `existingLogAnalyticsWorkspaceResourceId` is provided (the central workspace is assumed to be private-linked centrally).')
param enablePrivateLogAnalytics bool = true

@description('Deploy Azure Application Insights for application performance monitoring and diagnostics.')
param deployAppInsights bool = true

@description('Resource ID of an existing Application Insights component to reuse instead of creating one (Gap 5). Pair with `existingApplicationInsightsConnectionString` so downstream consumers (Container Apps Environment, App Configuration) receive a working connection string without requiring same-RG access to the existing component. Cross-RG/cross-subscription IDs are supported.')
param existingApplicationInsightsResourceId string?

@description('Connection string for the existing Application Insights component referenced by `existingApplicationInsightsResourceId`. Required when reusing AppInsights so the Container Apps Environment and the `APPLICATIONINSIGHTS_CONNECTION_STRING` App Configuration entry are correctly populated. Operators retrieve this from `az monitor app-insights component show -g <rg> -a <name> --query connectionString -o tsv`.')
@secure()
param existingApplicationInsightsConnectionString string?

@description('When `existingApplicationInsightsResourceId` is provided WITHOUT a matching `existingLogAnalyticsWorkspaceResourceId`, the deployment normally fails the pre-flight check (Gap 5 §4.13) because telemetry would split between the central AppInsights workspace and this deployment\'s own LAW. Set to `true` only if the split is intentional and accepted.')
param allowMixedObservabilityWorkspaces bool = false

@description('Gap 6 — IP address of an external network virtual appliance (typically the hub Azure Firewall private IP) that should receive the spoke 0.0.0.0/0 default route when no spoke-local firewall is deployed. Effective only when `deployAzureFirewall=false`, `networkIsolation=true`, and no `hubIntegrationExistingRouteTableResourceId` is provided. Use this in AI-LZ-integrated topologies where the hub provides centralized egress filtering.')
param hubIntegrationEgressNextHopIp string?

@description('Gap 6 — Resource ID of an existing Route Table to attach the spoke workload subnets to. When set, the deployment skips creation of its local route table and reuses this RT (assumed pre-configured with the correct default route). Required for Landing Zone-managed topologies where the platform team owns the spoke RT. Mutually exclusive with `hubIntegrationEgressNextHopIp` (which builds a local RT). When set, both `deployAzureFirewall` and any local default-route creation are suppressed.')
param hubIntegrationExistingRouteTableResourceId string?

@description('Gap 7 — Resource ID of the hub Virtual Network the spoke should peer with. When set and `hubIntegrationCreateHubPeering=true`, the deployment creates a spoke→hub VNet peering. The reverse (hub→spoke) peering is the operator\'s responsibility — typically handled by a platform team script (`tests/scripts/Add-HubSpokePeering.ps1` for our test harness). Hub VNet may live in a different subscription/RG; the peering resource itself lives in the spoke VNet so the spoke deployment has the rights to create it.')
param hubIntegrationHubVnetResourceId string?

@description('Gap 7 — When true and `hubIntegrationHubVnetResourceId` is set, the deployment creates the spoke→hub peering inline. Set to `false` to defer peering creation entirely to the platform team (both directions handled externally). Only effective when the spoke VNet is created by this deployment (`useExistingVNet=false`); with BYO VNet, peering management is the operator\'s responsibility.')
param hubIntegrationCreateHubPeering bool = true

@description('Gap 7 — `allowGatewayTransit` flag on the spoke→hub peering. Set to `true` when the spoke owns a VPN/ExpressRoute gateway that the hub should be allowed to use as transit. Defaults to `false` (hub-owned gateway is the standard topology).')
param hubIntegrationPeeringAllowGatewayTransit bool = false

@description('Gap 7 — `useRemoteGateways` flag on the spoke→hub peering. Set to `true` to route on-premises traffic from the spoke through the hub-owned VPN/ExpressRoute gateway. Requires the reverse hub→spoke peering to have `allowGatewayTransit=true` and a gateway provisioned in the hub. Defaults to `false` for the standalone topology.')
param hubIntegrationPeeringUseRemoteGateways bool = false

@description('Deploy an Azure Cognitive Search service for indexing and querying content. When disabled, search-related connections are skipped and search app configuration values resolve to empty values.')
param deploySearchService bool = true

@description('Deploy an Azure AI Speech (SpeechServices) cognitive account with the same private-endpoint / DNS / RBAC posture as the rest of the AI services in this landing zone. Off by default so the change is non-breaking for existing consumers. When enabled under network isolation, the account is created with publicNetworkAccess=Disabled and a private endpoint into the existing privatelink.cognitiveservices.azure.com zone.')
param deploySpeechService bool = false

@description('SKU for the Azure AI Speech service. Only F0 (free) and S0 (standard) are supported via SDK.')
@allowed([
  'F0'
  'S0'
])
param speechServiceSku string = 'S0'

@description('Deploy an Azure Storage Account to hold blobs, queues, tables, and files.')
param deployStorageAccount bool = true

@description('Network ACL bypass for the solution Storage account only. AzureServices preserves existing behavior; None removes trusted-service bypass without changing public network access or IP rules.')
param storageAccountNetworkAclsBypass storageTypes.storageAccountNetworkAclsBypassType = 'AzureServices'

@description('Complete desired resource-instance network access rules for the solution Storage account. Empty means no resource-instance exceptions. Supply only approved resource IDs and tenant IDs; no live rules are imported and no Defender scanner, plan, or role is created.')
param storageAccountResourceAccessRules storageTypes.storageAccountResourceAccessRuleType[] = []

@description('Allow Shared Key authorization for the solution Storage account. Defaults to true for compatibility. Set false only after migrating affected key-based clients and SAS tokens; this does not remove the pinned AVM management-plane key-listing outputs.')
param storageAccountAllowSharedKeyAccess bool = true

@description('Deploy an Azure Cosmos DB account for globally distributed NoSQL data storage.')
param deployCosmosDb bool = true

@description('Deploy Azure Container Apps for running your microservices in a serverless Kubernetes environment.')
param deployContainerApps bool = true

@description('Deploy an Azure Container Registry to store and manage Docker container images.')
param deployContainerRegistry bool = true

@description('Deploy the Container Apps environment (log ingestion, VNet integration, etc.).')
param deployContainerEnv bool = true

// ---------------------------------------------------------------------------
// Hub-component deployment flags (Gap 4, issue #58)
// ---------------------------------------------------------------------------
// `deployVM` (v1.x) consolidated three independent deployments — jumpbox,
// Bastion, and NAT Gateway — under one switch. v2.0.0 splits them so each
// component can be controlled, reused (BYO) or skipped independently.
//
// Defaults are nullable. When null, the effective value is derived to match
// v1.x behavior (everything deploys when `networkIsolation=true`). Set any
// flag explicitly to override.
//
//   deployJumpbox      | jumpbox VM + CSE + RBAC + (optionally) VM Key Vault
//   deployBastion      | spoke-side Azure Bastion + Bastion NSG + Bastion PIP
//   deployNatGateway   | spoke NAT Gateway + NAT PIP for outbound egress
//
// Each component also accepts a matching `existing<Component>ResourceId` BYO
// parameter. When the BYO ID is non-empty, the corresponding `deploy*` flag
// defaults to `false` and the existing resource ID is consumed by downstream
// wiring (RBAC, diagnostics, runbook docs).
//
@description('Deploy the jumpbox Virtual Machine (and its CSE + RBAC + optional VM Key Vault). When null, defaults to `networkIsolation` to match v1.x behavior. Set to `false` for AI LZ-integrated topologies where the operator connects via central tooling.')
param deployJumpbox bool?

@description('Deploy a spoke-side Azure Bastion + Bastion NSG + Bastion PIP. When null, defaults to `networkIsolation && deployJumpbox` (preserves v1.x behavior). Set to `false` when reusing a central hub Bastion via VNet peering (Gap 7).')
param deployBastion bool?

@description('Deploy a NAT Gateway + NAT PIP for outbound spoke egress. When null, defaults to `networkIsolation && deployJumpbox` (preserves v1.x behavior). Set to `false` when egress is centralized via Azure Firewall in the hub (Gap 6).')
param deployNatGateway bool?

@description('Resource ID of an existing Bastion to reuse (BYO). Informational — used by docs/runbooks. When non-empty, `deployBastion` defaults to `false`.')
param existingBastionResourceId string?

@description('Resource ID of an existing NAT Gateway to associate with the spoke subnets (BYO). When non-empty, `deployNatGateway` defaults to `false`.')
param existingNatGatewayResourceId string?

@description('Resource ID of an existing jumpbox VM (BYO). Informational — used by docs/runbooks for post-provision flows. When non-empty, `deployJumpbox` defaults to `false`.')
param existingJumpboxResourceId string?

@description('DEPRECATED (v2.0.0). Legacy v1.x consolidated switch for jumpbox + Bastion + NAT Gateway. Provided as a transitional fallback so v1.x parameter files continue to deploy unmodified — explicit `deployJumpbox` / `deployBastion` / `deployNatGateway` values ALWAYS take precedence over this flag. Will be REMOVED in v3.0.0; migrate to the three component-specific flags.')
param deployVM bool?

@description('Deploy the virtual network subnets.')
param deploySubnets bool = true

@description('Will deploy network security groups.')
param deployNsgs bool = true

@description('Deploy Azure Firewall with UDR for egress traffic control. Defaults to true when networkIsolation is enabled.')
param deployAzureFirewall bool = true

@description('Enable DNS proxy on the spoke-local Azure Firewall policy. Defaults to false. Only effective when deployAzureFirewall and networkIsolation are true; does not change VNet or VPN client DNS settings or create a DNS resolver.')
param enableFirewallDnsProxy bool = false

@description('Deploy an ACR Task agent pool so image builds can run inside the VNet when the registry has public access disabled. Requires a Premium container registry (auto-selected when networkIsolation is true) and is gated on both deployContainerRegistry and networkIsolation.')
param deployAcrTaskAgentPool bool = true

@description('Prepare accelerator-neutral Microsoft Foundry hosted-agent prerequisites without requesting downstream agent deployment. Provisions the required project and registry RBAC and exposes project, registry, network, and private-build handoff values. deployHostedAgent implies this behavior. Defaults to false.')
param prepareHostedAgent bool = false

@description('Grant the deployment executor Foundry Project Manager when Hosted prerequisites are selected. Defaults to true for compatible foundation callers. Set false when the executor already has required project authorization; this never disables the project managed identity registry pull grant.')
param grantHostedAgentProjectManager bool = true

@description('Request the downstream Microsoft Foundry hosted-agent deployment handoff. Implies prepareHostedAgent behavior and requires hostedAgent.version to be an immutable OCI digest. The landing zone does not create the data-plane agent version and never changes Container Apps or data resources. Defaults to false.')
param deployHostedAgent bool = false

@description('Typed hosted-agent deployment handoff consumed by a downstream `azure.ai.agent` service. `image` is the repository path within the selected registry, `version` must be an immutable OCI digest (`sha256:` plus 64 lowercase hex characters), optional `startupCommand` maps to the official azure.yaml field, and `runtime` maps to `container.resources`. Values are validated only when deployHostedAgent is true.')
param hostedAgent hostedAgentConfigurationType = {
  name: ''
  image: ''
  version: ''
  startupCommand: ''
  runtime: {
    cpu: '1'
    memory: '1Gi'
  }
  protocols: [
    {
      protocol: 'responses'
      version: '2.0.0'
    }
  ]
}

@description('Optional resource ID of an existing Azure Container Registry used for hosted-agent images when deployContainerRegistry is false. The deploying principal must be able to create role assignments at this scope.')
param hostedAgentContainerRegistryResourceId string = ''

@description('Optional login endpoint of an existing Azure Container Registry used for hosted-agent images when deployContainerRegistry is false, for example `contoso.azurecr.io`. Private endpoint, DNS, and VNet-internal build connectivity for an existing registry remain consumer responsibilities.')
param hostedAgentContainerRegistryEndpoint string = ''

@description('Role assignment permissions mode of the existing hosted-agent registry when deployContainerRegistry is false. Use `rbac` for RBAC Registry Permissions or `rbac-abac` for RBAC Registry + ABAC Repository Permissions. The landing-zone registry always uses `rbac`.')
@allowed([ 'rbac', 'rbac-abac' ])
param hostedAgentContainerRegistryRoleAssignmentMode string = 'rbac'

@description('Name for the ACR Task agent pool. Max 20 characters.')
@maxLength(20)
param acrTaskAgentPoolName string = 'build-pool'

@description('SKU tier for the ACR Task agent pool: S1 (2 vCPU), S2 (4 vCPU), S3 (8 vCPU).')
@allowed([ 'S1', 'S2', 'S3' ])
param acrTaskAgentPoolTier string = 'S1'

@description('Initial instance count for the ACR Task agent pool. Set to 0 after provisioning to pause billing (az acr agentpool update -r <acr> -n <pool> --count 0).')
@minValue(0)
param acrTaskAgentPoolCount int = 1

@description('When true, extends the Azure Firewall Policy with the FQDN allow-list required by the default install.ps1 jumpbox bootstrap (Chocolatey, Python, Node, VS Code, GitHub clones, Azure CLI control plane). Disable if you manage egress centrally.')
param extendFirewallForJumpboxBootstrap bool = true

@description('When true, extends the Azure Firewall Policy with the FQDN allow-list required for ACR Tasks builds running inside the build-agents subnet to fetch language packages (npm, PyPI) and OS packages (Debian/Ubuntu apt repos, yarn). Only effective when networkIsolation, deployAzureFirewall and deployAcrTaskAgentPool are all enabled. Disable if you manage egress centrally or pre-bake all dependencies into the builder base image.')
param extendFirewallForAcrTaskBuilds bool = true

@description('Additional FQDNs to allow from the ACR Tasks build-agent subnet when extendFirewallForAcrTaskBuilds is true. Use this for application-specific build dependencies that are not part of the landing-zone default allow-list.')
param additionalAcrTaskBuildFqdns array = []

@description('List of trusted source IP CIDRs allowed to connect to the Bastion public IP on port 443. When empty, all internet inbound to port 443 is denied by default.')
param bastionAllowedSourceIPs array = []

@description('Bastion SKU. `Standard` supports native client (`az network bastion rdp/ssh`) and tunneling; `Premium` adds shareable link, session recording, and private-only mode. `Basic` does not support tunneling.')
@allowed(['Basic', 'Standard', 'Premium'])
param bastionSkuName string = 'Standard'

@description('Enable Bastion native client tunneling. Required for `az network bastion rdp/ssh`, RDP audio/clipboard/device redirection, and SSH agent forwarding. Off by default for parity with portal-only access. Requires `bastionSkuName` to be `Standard` or `Premium`.')
param bastionEnableTunneling bool = false

@description('When true, extends the Azure Firewall Policy with a Network Rule Collection allowing UDP/TCP egress from spoke subnets (jumpbox, ACA environment, agent) to the `AzureCloud` Service Tag. Required for any spoke workload that uses Azure Speech real-time avatar, Azure Communication Services Calling, or Microsoft Teams Media (WebRTC peer connections, STUN/TURN UDP 3478-3481 and TCP 443/3478-3481). Off by default to preserve least-privilege egress. Only effective when `networkIsolation` and `deployAzureFirewall` are both true.')
param enableAcsMediaEgress bool = false

// ----------------------------------------------------------------------
// Public Ingress (#49) — optional Application Gateway WAF v2 in front of the
// internal Container Apps environment. Default-disabled. WARNING: enabling
// this deploys WAF_v2 + a Standard Public IP, which incur hourly charges
// even when idle. To remove the stack, run `azd down` or delete the
// resources manually — `azd`/ARM incremental deployments will NOT delete
// these resources when `publicIngress.enabled` flips back to false after a
// previous deploy. See README "Optional Public Ingress" for the runbook.
// ----------------------------------------------------------------------

@export()
@description('Aggregate parameter for the optional public ingress (Application Gateway WAF v2). See README "Optional Public Ingress".')
type publicIngressType = {
  @description('Master toggle. When false (default) no public-ingress resources are deployed.')
  enabled: bool

  @description('Optional. Index of the entry in `containerAppsList` that the gateway routes to. Defaults to 0.')
  backendAppIndex: int?

  @description('Optional. Frontend host name presented to clients (e.g., app.contoso.com). Required to activate the HTTPS listener.')
  frontendHostName: string?

  @description('Optional. Versionless Key Vault secret ID for the TLS certificate. Required to activate the HTTPS listener.')
  sslCertSecretId: string?

  @description('Optional. CIDRs allowed to reach the gateway on TCP/443. Empty list keeps the gateway fully inert (skeleton mode).')
  allowedSourceAddressPrefixes: string[]?

  @description('Optional. WAF mode. Defaults to `Prevention`.')
  wafMode: ('Prevention' | 'Detection')?

  @description('Optional. WAF custom rules merged with the OWASP CRS 3.2 managed ruleset.')
  wafCustomRules: object[]?

  @description('Optional. AGW autoscale capacity (e.g., `{ minCapacity: 0, maxCapacity: 2 }`).')
  capacity: object?

  @description('Optional. AGW sslPolicy block. When omitted, the gateway uses the Azure default policy.')
  sslPolicy: object?
}

@export()
@sealed()
@description('Invocation protocol implemented by a hosted agent. Values match the Microsoft Foundry `azure.ai.agent` service contract.')
type hostedAgentProtocolType = {
  @description('Protocol implemented by the agent container.')
  protocol: 'responses' | 'invocations' | 'invocations_ws' | 'a2a'

  @description('Optional protocol version exposed by the agent.')
  version: string?
}

@export()
@sealed()
@description('Container CPU and memory settings passed to `azure.ai.agent` as `container.resources`.')
type hostedAgentRuntimeType = {
  @description('CPU allocation from `0.25` through `4.0`, for example `0.5` or `1`.')
  cpu: string

  @description('Memory allocation from `0.5Gi` through `8Gi`.')
  memory: string
}

@export()
@sealed()
@description('Accelerator-neutral handoff for a downstream Microsoft Foundry hosted-agent deployment.')
type hostedAgentConfigurationType = {
  @description('Stable hosted-agent name. Reusing this name creates a new immutable version.')
  name: string

  @description('Container image repository path inside the selected registry, without a tag or digest.')
  image: string

  @description('Immutable OCI image digest in `sha256:<64 lowercase hex characters>` form.')
  version: string

  @description('Optional command that starts the agent server. Maps to `startupCommand` in the official `azure.ai.agent` service contract.')
  startupCommand: string

  @description('Hosted-agent container resource settings.')
  runtime: hostedAgentRuntimeType

  @description('Invocation protocols implemented by the hosted agent.')
  protocols: hostedAgentProtocolType[]
}

@export()
@description('Shape for an accelerator-supplied App Configuration key-value that the landing zone passes through verbatim. Values are stored as plaintext, never pass secrets here (use Key Vault references instead).')
type additionalAppConfigurationSettingType = {
  @description('Required. App Configuration key name.')
  name: string

  @description('Required. Plaintext value. Do not put secrets here.')
  value: string

  @description('Optional. App Configuration label. Defaults to the landing zone appConfigLabel.')
  label: string?

  @description('Optional. Content type. Defaults to text/plain. Use application/json for JSON values.')
  contentType: string?
}

@description('Optional. Public Application Gateway WAF v2 ingress in front of the internal Container Apps environment. Disabled by default. WARNING: enabling this deploys WAF_v2 and a Standard Public IP, which incur hourly charges even when idle. See README "Optional Public Ingress" for the post-deploy runbook.')
param publicIngress publicIngressType = { enabled: false }

@description('Will deploy network resources side by side with the Azure resources.')
param sideBySideDeploy bool = true

@description('Deploy Virtual Machine software.')
param deploySoftware bool = true

@description('Deploy AI Foundry Project.')
param deployAfProject bool = true

@description('Deploy AI Foundry Service.')
param deployAAfAgentSvc bool = true

@description('Whether to disable local (API-key) authentication on the AI Foundry account, enforcing Microsoft Entra ID-only authentication. Local authentication is disabled by default for security.')
param aiFoundryDisableLocalAuth bool = true


@description('Deprecated. Kept for one release for compatibility with existing deployments. Use retrievalBackend and the Foundry IQ parameters instead.')
param enableAgenticRetrieval bool = false

@description('Retrieval backend stamped into application runtime configuration. New deployments default to foundry_iq. Existing deployments can keep ai_search until they explicitly migrate.')
@allowed([
  'ai_search'
  'foundry_iq'
])
param retrievalBackend string = 'foundry_iq'

@description('Deprecated: prefer publishing this via additionalAppConfigurationSettings so the landing zone stays workload-agnostic. Retained for backward compatibility. Foundry IQ knowledge pattern. azureBlob uses native Foundry IQ Blob or ADLS Gen2 ingestion and is the default. searchIndex registers the existing Agent Landing Zone Azure AI Search index as an opt-in legacy Pattern B knowledge source. managed is accepted as a compatibility alias for azureBlob.')
@allowed([
  'azureBlob'
  'managed'
  'searchIndex'
])
param foundryIqPattern string = 'azureBlob'

@description('Azure AI Search / Foundry IQ data-plane API version for knowledge base retrieval and knowledge source operations. Use 2026-05-01-preview when native permissions or Pattern B filterAddOn are required.')
param foundryIqApiVersion string = '2026-05-01-preview'

@description('Azure AI Search knowledgeRetrieval billing plan for agentic retrieval. free uses the included allowance; standard enables pay-as-you-go billing after the free allowance.')
@allowed([
  'free'
  'standard'
])
param foundryIqKnowledgeRetrievalBillingPlan string = 'free'

@description('Foundry IQ knowledge base name to stamp into runtime configuration.')
param knowledgeBaseName string = '${environmentName}-knowledge-base'

@description('Dedicated Azure AI Foundry connection name used by the knowledge base. Do not reuse SEARCH_CONNECTION_ID.')
param knowledgeBaseConnectionName string = '${environmentName}-knowledge-base-connection'

@description('Deprecated: prefer publishing this via additionalAppConfigurationSettings so the landing zone stays workload-agnostic. Retained for backward compatibility. Foundry IQ knowledge source name. For azureBlob this is the native Blob or ADLS Gen2 source. For searchIndex this is the registered Agent Landing Zone Azure AI Search index source.')
param foundryIqKnowledgeSourceName string = '${environmentName}-blob-ks'

@description('Foundry IQ knowledge source kind stamped into runtime configuration. Leave empty to derive it from foundryIqPattern. Set to azureBlob for native Blob/ADLS sources or searchIndex for Pattern B.')
@allowed([
  ''
  'azureBlob'
  'searchIndex'
])
param foundryIqKnowledgeSourceKind string = ''

@description('Storage container used by the native Foundry IQ azureBlob knowledge source.')
param foundryIqStorageContainerName string = 'documents'

@description('Optional folder path within the native Foundry IQ Blob or ADLS Gen2 knowledge source container. Empty ingests from the container root.')
param foundryIqStorageFolderPath string = ''

@description('Set true when the native Foundry IQ azureBlob knowledge source points to an ADLS Gen2 account/container with hierarchical namespace enabled.')
param foundryIqIsAdlsGen2 bool = false

@description('Native Foundry IQ content extraction mode for the azureBlob knowledge source. standard uses the Content Understanding skill for layout and OCR, which is required for scanned and image-only PDFs. minimal skips Content Understanding and ingests only text already present in the source.')
@allowed([
  'minimal'
  'standard'
])
param foundryIqContentExtractionMode string = 'standard'

@description('Optional Foundry AI Services endpoint for native Foundry IQ standard extraction. Leave empty to use https://<ai-foundry-account>.services.ai.azure.com/.')
param foundryIqAiServicesEndpoint string = ''

@description('Native Foundry IQ permission metadata to ingest. Blob sources with foundryIqIsAdlsGen2=false support rbacScope and sensitivityLabels. ADLS Gen2 sources can override this to include userIds and groupIds when ACL metadata is required.')
param foundryIqIngestionPermissionOptions array = [
  'rbacScope'
]

@description('JSON array override for native Foundry IQ permission metadata, intended for azd environment substitution from FOUNDRY_IQ_INGESTION_PERMISSION_OPTIONS. Leave empty to use foundryIqIngestionPermissionOptions.')
param foundryIqIngestionPermissionOptionsJson string = ''

@description('Deprecated: prefer publishing this via additionalAppConfigurationSettings so the landing zone stays workload-agnostic. Retained for backward compatibility. Existing Agent Landing Zone Azure AI Search index name to register as a Pattern B Foundry IQ searchIndex knowledge source.')
param foundryIqSearchIndexName string = 'agent-lz-index'

@description('Semantic configuration name on the Agent Landing Zone Azure AI Search index. Required by Azure AI Search agentic retrieval.')
param foundryIqSemanticConfigurationName string = 'default'

@description('Retrievable source data fields exposed from the Pattern B searchIndex knowledge source for citations.')
param foundryIqSourceDataFields array = [
  'id'
  'title'
  'filepath'
  'url'
  'content'
]

@description('Optional search fields for the Pattern B searchIndex knowledge source. Leave empty to let Azure AI Search search all eligible fields.')
param foundryIqSearchFields array = [
  'content'
]

@description('Deprecated: prefer publishing this via additionalAppConfigurationSettings so the landing zone stays workload-agnostic. Retained for backward compatibility. Optional persisted baseFilter for the Pattern B searchIndex knowledge source. Keep security trimming in query-time filterAddOn unless a static tenant/corpus filter is required.')
param foundryIqBaseFilter string = ''

@description('Deprecated: prefer publishing this via additionalAppConfigurationSettings so the landing zone stays workload-agnostic. Retained for backward compatibility. Enable query-time Pattern B filterAddOn in the Agent Landing Zone orchestrator. Requires foundryIqApiVersion 2026-05-01-preview.')
param foundryIqFilterAddOnEnabled bool = true

@description('Collection field used by the Agent Landing Zone for Pattern B security trimming filterAddOn.')
param foundryIqSecurityFieldName string = 'metadata_security_id'

@description('Optional maximum documents to return from Foundry IQ retrieval. Empty keeps the orchestrator default.')
param foundryIqMaxOutputDocuments string = ''

// ----------------------------------------------------------------------
// Reuse Existing Services Parameters
// Note: Reuse is optional. Leave empty to create new resources
// ----------------------------------------------------------------------

// AI Foundry Dependencies

@description('The AI Search Service full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiSearchResourceId string = ''

@description('The AI Storage Account full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiFoundryStorageAccountResourceId string = ''

@description('The SKU name for the AI Foundry Storage Account. Only used when a new account is created (aiFoundryStorageAccountResourceId is empty). The AVM ai-foundry module does not expose this, so we pre-create the storage account with the requested SKU. Defaults to Standard_LRS for broad regional availability (some regions, e.g. Poland Central, do not support the AVM default Standard_GRS).')
@allowed([
  'Standard_LRS'
  'Standard_GRS'
  'Standard_RAGRS'
  'Standard_ZRS'
  'Standard_GZRS'
  'Standard_RAGZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
param aiFoundryStorageSku string = 'Standard_LRS'

@description('The Cosmos DB account full ARM resource ID. Optional; if not provided, a new resource will be created.')
param aiFoundryCosmosDBAccountResourceId string = ''

// GenAI App Services

@description('The Key Vault full ARM resource ID. Optional; if not provided, a new vault will be created.')
param keyVaultResourceId string = ''

// ----------------------------------------------------------------------
// Feature-flagging Params (as booleans with a default of false)
// ----------------------------------------------------------------------
param useUAI bool = false // Use User Assigned Identity (UAI)
param useCAppAPIKey bool = false // Use API Keys to connect to container apps
param useZoneRedundancy bool = false // Use Zone Redundancy

// ----------------------------------------------------------------------
// Resource Naming params
// ----------------------------------------------------------------------

@description('Unique token used to build deterministic resource names, derived from subscription ID, environment name, and location.')
param resourceToken string = toLower(uniqueString(subscription().id, environmentName, location))

@description('Controls generated resource names. Use `caf` (default) for Cloud Adoption Framework-style generated names. Use `legacy` to preserve the older resource-token-based generated names. Explicit name parameters still override generated names in either mode.')
@allowed([
  'legacy'
  'caf'
])
param resourceNamingMode string = 'caf'

@description('CAF naming token for the workload or application. Leave empty (default) to use a short deterministic hash, stable per subscription, environment, and location, so deployments get unique names without manual input. Override with a meaningful name such as `chatapp` when desired. Used only when `resourceNamingMode` is `caf` and an explicit resource name parameter is not supplied.')
param cafWorkloadName string = ''

@description('CAF naming token for the environment, such as dev, test, or prod. Leave empty (default) to use the azd environment name. Used only when `resourceNamingMode` is `caf` and an explicit resource name parameter is not supplied.')
param cafEnvironmentName string = ''

@description('CAF naming token for the Azure region. Leave empty (default) to use the deployment location supplied by azd (`AZURE_LOCATION`), mapped to a short region code. Used only when `resourceNamingMode` is `caf` and an explicit resource name parameter is not supplied.')
param cafRegionName string = ''

@description('CAF naming instance token, such as 001. Increment only when deploying a second parallel copy of the same workload in the same environment and region. Used only when `resourceNamingMode` is `caf` and an explicit resource name parameter is not supplied.')
param cafInstance string = '001'

@description('Name of the Azure AI Foundry account to create or reference.')
param aiFoundryAccountName string = '${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the AI Foundry project resource.')
param aiFoundryProjectName string = '${const.abbrs.ai.aiFoundryProject}${resourceToken}'

@description('Optional display name for the AI Foundry project. When omitted, the default display name is used.')
param aiFoundryProjectDisplayName string?

@description('Optional description for the AI Foundry project. When omitted, the default description is used.')
param aiFoundryProjectDescription string?

@description('Name of the Storage Account used by AI Foundry for blobs, queues, tables, and files.')
param aiFoundryStorageAccountName string = replace('${const.abbrs.storage.storageAccount}${const.abbrs.ai.aiFoundry}${resourceToken}', '-', '')

@description('Name of the Cognitive Search service provisioned for AI Foundry.')
param aiFoundrySearchServiceName string = '${const.abbrs.ai.aiSearch}${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the Azure Cosmos DB account used by AI Foundry.')
param aiFoundryCosmosDbName string = '${const.abbrs.databases.cosmosDBDatabase}${const.abbrs.ai.aiFoundry}${resourceToken}'

@description('Name of the Bing Search resource for grounding capabilities.')
param bingSearchName string = '${const.abbrs.ai.bing}${resourceToken}'

@description('Name of the Azure App Configuration store for centralized settings.')
param appConfigName string = '${const.abbrs.configuration.appConfiguration}${resourceToken}'

@description('Name of the Application Insights instance for monitoring.')
param appInsightsName string = '${const.abbrs.managementGovernance.applicationInsights}${resourceToken}'

@description('Name of the Azure Container Apps environment (log ingestion, VNet integration, etc.).')
param containerEnvName string = '${const.abbrs.containers.containerAppsEnvironment}${resourceToken}'

@description('Name of the Azure Container Registry for storing Docker images.')
param containerRegistryName string = '${const.abbrs.containers.containerRegistry}${resourceToken}'

@description('Name of the Cosmos DB account (alias for database operations).')
param dbAccountName string = '${const.abbrs.databases.cosmosDBDatabase}${resourceToken}'

@description('Name of the Cosmos DB database to host application data.')
param dbDatabaseName string = '${const.abbrs.databases.cosmosDBDatabase}db${resourceToken}'

@description('Name of the Azure Key Vault for secrets, keys, and certificates.')
param keyVaultName string = '${const.abbrs.security.keyVault}${resourceToken}'

@description('Name of the Log Analytics workspace for collecting and querying logs.')
param logAnalyticsWorkspaceName string = '${const.abbrs.managementGovernance.logAnalyticsWorkspace}${resourceToken}'

@description('Name of the Cognitive Search service.')
param searchServiceName string = '${const.abbrs.ai.aiSearch}${resourceToken}'

@description('Optional override for the Azure AI Speech account name. When empty, a name is generated from the resource token. Also used as the customSubDomainName, so it must be globally unique within `cognitiveservices.azure.com`.')
param speechServiceName string = '${const.abbrs.ai.speechService}${resourceToken}'

@description('Name of the Azure Storage Account for general-purpose blob and file storage.')
param storageAccountName string = '${const.abbrs.storage.storageAccount}${resourceToken}'

@description('Name of the Virtual Network to isolate resources and enable private endpoints.')
param vnetName string = '${const.abbrs.networking.virtualNetwork}${resourceToken}'

// Trims a candidate name to a maximum length and drops a trailing hyphen so the
// result is never an invalid Azure resource name (e.g. `kv-...-` after truncation).
func cafTrim(candidate string, maxLength int) string =>
  endsWith(take(candidate, maxLength), '-') ? take(candidate, maxLength - 1) : take(candidate, maxLength)

// CAF region tokens are abbreviated to short codes so generated names stay within
// Azure resource name limits (storage 24, Key Vault 24, Container Apps env 32, etc.).
// Unknown regions fall back to a 5-character slug of the raw region string.
var _cafRegionAbbrs = {
  eastus: 'eus'
  eastus2: 'eus2'
  centralus: 'cus'
  northcentralus: 'ncus'
  southcentralus: 'scus'
  westcentralus: 'wcus'
  westus: 'wus'
  westus2: 'wus2'
  westus3: 'wus3'
  canadacentral: 'cnc'
  canadaeast: 'cne'
  brazilsouth: 'brs'
  brazilsoutheast: 'brse'
  mexicocentral: 'mxc'
  northeurope: 'neu'
  westeurope: 'weu'
  uksouth: 'uks'
  ukwest: 'ukw'
  francecentral: 'frc'
  francesouth: 'frs'
  germanywestcentral: 'gwc'
  switzerlandnorth: 'chn'
  switzerlandwest: 'chw'
  norwayeast: 'noe'
  swedencentral: 'sdc'
  polandcentral: 'plc'
  italynorth: 'itn'
  spaincentral: 'spc'
  uaenorth: 'uan'
  qatarcentral: 'qac'
  israelcentral: 'ilc'
  southafricanorth: 'san'
  australiaeast: 'aue'
  australiasoutheast: 'ause'
  southeastasia: 'sea'
  eastasia: 'ea'
  centralindia: 'inc'
  southindia: 'ins'
  westindia: 'inw'
  japaneast: 'jpe'
  japanwest: 'jpw'
  koreacentral: 'krc'
  koreasouth: 'krs'
}
var _cafRegionInput = empty(cafRegionName) ? location : cafRegionName
var _cafRegionRaw = toLower(replace(_cafRegionInput, ' ', ''))
var _cafRegion = contains(_cafRegionAbbrs, _cafRegionRaw) ? _cafRegionAbbrs[_cafRegionRaw] : take(_cafRegionRaw, 5)
var _cafWorkload = toLower(empty(cafWorkloadName) ? substring(uniqueString(subscription().id, environmentName, location), 0, 6) : cafWorkloadName)
var _cafEnv = toLower(empty(cafEnvironmentName) ? environmentName : cafEnvironmentName)
var _cafInstance = toLower(empty(cafInstance) ? '001' : cafInstance)
var _cafNameStem = '${_cafWorkload}-${_cafEnv}-${_cafRegion}-${_cafInstance}'
var _cafCompactStem = replace(_cafNameStem, '-', '')

var _legacyResourceNames = {
  aiFoundryAccountName: '${const.abbrs.ai.aiFoundry}${resourceToken}'
  aiFoundryProjectName: '${const.abbrs.ai.aiFoundryProject}${resourceToken}'
  aiFoundryStorageAccountName: replace('${const.abbrs.storage.storageAccount}${const.abbrs.ai.aiFoundry}${resourceToken}', '-', '')
  aiFoundrySearchServiceName: '${const.abbrs.ai.aiSearch}${const.abbrs.ai.aiFoundry}${resourceToken}'
  aiFoundryCosmosDbName: '${const.abbrs.databases.cosmosDBDatabase}${const.abbrs.ai.aiFoundry}${resourceToken}'
  bingSearchName: '${const.abbrs.ai.bing}${resourceToken}'
  appConfigName: '${const.abbrs.configuration.appConfiguration}${resourceToken}'
  appInsightsName: '${const.abbrs.managementGovernance.applicationInsights}${resourceToken}'
  containerEnvName: '${const.abbrs.containers.containerAppsEnvironment}${resourceToken}'
  containerRegistryName: '${const.abbrs.containers.containerRegistry}${resourceToken}'
  dbAccountName: '${const.abbrs.databases.cosmosDBDatabase}${resourceToken}'
  dbDatabaseName: '${const.abbrs.databases.cosmosDBDatabase}db${resourceToken}'
  keyVaultName: '${const.abbrs.security.keyVault}${resourceToken}'
  logAnalyticsWorkspaceName: '${const.abbrs.managementGovernance.logAnalyticsWorkspace}${resourceToken}'
  searchServiceName: '${const.abbrs.ai.aiSearch}${resourceToken}'
  speechServiceName: '${const.abbrs.ai.speechService}${resourceToken}'
  storageAccountName: '${const.abbrs.storage.storageAccount}${resourceToken}'
  vnetName: '${const.abbrs.networking.virtualNetwork}${resourceToken}'
}

var _cafResourceNames = {
  aiFoundryAccountName: cafTrim('aif-${_cafNameStem}', 64)
  aiFoundryProjectName: cafTrim('aifp-${_cafNameStem}', 64)
  aiFoundryStorageAccountName: cafTrim('staif${_cafCompactStem}', 24)
  aiFoundrySearchServiceName: cafTrim('srch-aif-${_cafNameStem}', 60)
  aiFoundryCosmosDbName: cafTrim('cosmos-aif-${_cafNameStem}', 44)
  bingSearchName: cafTrim('bing-${_cafNameStem}', 64)
  appConfigName: cafTrim('appcs-${_cafNameStem}', 50)
  appInsightsName: cafTrim('appi-${_cafNameStem}', 64)
  containerEnvName: cafTrim('cae-${_cafNameStem}', 32)
  containerRegistryName: cafTrim('cr${_cafCompactStem}', 50)
  dbAccountName: cafTrim('cosmos-${_cafNameStem}', 44)
  dbDatabaseName: cafTrim('cosmosdb-${_cafNameStem}', 63)
  keyVaultName: cafTrim('kv-${_cafNameStem}', 24)
  logAnalyticsWorkspaceName: cafTrim('log-${_cafNameStem}', 63)
  searchServiceName: cafTrim('srch-${_cafNameStem}', 60)
  speechServiceName: cafTrim('spch-${_cafNameStem}', 64)
  storageAccountName: cafTrim('st${_cafCompactStem}', 24)
  vnetName: cafTrim('vnet-${_cafNameStem}', 64)
}

var resourceNames = {
  aiFoundryAccountName: !empty(aiFoundryAccountName) && !(resourceNamingMode == 'caf' && aiFoundryAccountName == _legacyResourceNames.aiFoundryAccountName) ? aiFoundryAccountName : (resourceNamingMode == 'caf' ? _cafResourceNames.aiFoundryAccountName : _legacyResourceNames.aiFoundryAccountName)
  aiFoundryProjectName: !empty(aiFoundryProjectName) && !(resourceNamingMode == 'caf' && aiFoundryProjectName == _legacyResourceNames.aiFoundryProjectName) ? aiFoundryProjectName : (resourceNamingMode == 'caf' ? _cafResourceNames.aiFoundryProjectName : _legacyResourceNames.aiFoundryProjectName)
  aiFoundryStorageAccountName: !empty(aiFoundryStorageAccountName) && !(resourceNamingMode == 'caf' && aiFoundryStorageAccountName == _legacyResourceNames.aiFoundryStorageAccountName) ? aiFoundryStorageAccountName : (resourceNamingMode == 'caf' ? _cafResourceNames.aiFoundryStorageAccountName : _legacyResourceNames.aiFoundryStorageAccountName)
  aiFoundrySearchServiceName: !empty(aiFoundrySearchServiceName) && !(resourceNamingMode == 'caf' && aiFoundrySearchServiceName == _legacyResourceNames.aiFoundrySearchServiceName) ? aiFoundrySearchServiceName : (resourceNamingMode == 'caf' ? _cafResourceNames.aiFoundrySearchServiceName : _legacyResourceNames.aiFoundrySearchServiceName)
  aiFoundryCosmosDbName: !empty(aiFoundryCosmosDbName) && !(resourceNamingMode == 'caf' && aiFoundryCosmosDbName == _legacyResourceNames.aiFoundryCosmosDbName) ? aiFoundryCosmosDbName : (resourceNamingMode == 'caf' ? _cafResourceNames.aiFoundryCosmosDbName : _legacyResourceNames.aiFoundryCosmosDbName)
  bingSearchName: !empty(bingSearchName) && !(resourceNamingMode == 'caf' && bingSearchName == _legacyResourceNames.bingSearchName) ? bingSearchName : (resourceNamingMode == 'caf' ? _cafResourceNames.bingSearchName : _legacyResourceNames.bingSearchName)
  appConfigName: !empty(appConfigName) && !(resourceNamingMode == 'caf' && appConfigName == _legacyResourceNames.appConfigName) ? appConfigName : (resourceNamingMode == 'caf' ? _cafResourceNames.appConfigName : _legacyResourceNames.appConfigName)
  appInsightsName: !empty(appInsightsName) && !(resourceNamingMode == 'caf' && appInsightsName == _legacyResourceNames.appInsightsName) ? appInsightsName : (resourceNamingMode == 'caf' ? _cafResourceNames.appInsightsName : _legacyResourceNames.appInsightsName)
  containerEnvName: !empty(containerEnvName) && !(resourceNamingMode == 'caf' && containerEnvName == _legacyResourceNames.containerEnvName) ? containerEnvName : (resourceNamingMode == 'caf' ? _cafResourceNames.containerEnvName : _legacyResourceNames.containerEnvName)
  containerRegistryName: !empty(containerRegistryName) && !(resourceNamingMode == 'caf' && containerRegistryName == _legacyResourceNames.containerRegistryName) ? containerRegistryName : (resourceNamingMode == 'caf' ? _cafResourceNames.containerRegistryName : _legacyResourceNames.containerRegistryName)
  dbAccountName: !empty(dbAccountName) && !(resourceNamingMode == 'caf' && dbAccountName == _legacyResourceNames.dbAccountName) ? dbAccountName : (resourceNamingMode == 'caf' ? _cafResourceNames.dbAccountName : _legacyResourceNames.dbAccountName)
  dbDatabaseName: !empty(dbDatabaseName) && !(resourceNamingMode == 'caf' && dbDatabaseName == _legacyResourceNames.dbDatabaseName) ? dbDatabaseName : (resourceNamingMode == 'caf' ? _cafResourceNames.dbDatabaseName : _legacyResourceNames.dbDatabaseName)
  keyVaultName: !empty(keyVaultName) && !(resourceNamingMode == 'caf' && keyVaultName == _legacyResourceNames.keyVaultName) ? keyVaultName : (resourceNamingMode == 'caf' ? _cafResourceNames.keyVaultName : _legacyResourceNames.keyVaultName)
  logAnalyticsWorkspaceName: !empty(logAnalyticsWorkspaceName) && !(resourceNamingMode == 'caf' && logAnalyticsWorkspaceName == _legacyResourceNames.logAnalyticsWorkspaceName) ? logAnalyticsWorkspaceName : (resourceNamingMode == 'caf' ? _cafResourceNames.logAnalyticsWorkspaceName : _legacyResourceNames.logAnalyticsWorkspaceName)
  searchServiceName: !empty(searchServiceName) && !(resourceNamingMode == 'caf' && searchServiceName == _legacyResourceNames.searchServiceName) ? searchServiceName : (resourceNamingMode == 'caf' ? _cafResourceNames.searchServiceName : _legacyResourceNames.searchServiceName)
  speechServiceName: !empty(speechServiceName) && !(resourceNamingMode == 'caf' && speechServiceName == _legacyResourceNames.speechServiceName) ? speechServiceName : (resourceNamingMode == 'caf' ? _cafResourceNames.speechServiceName : _legacyResourceNames.speechServiceName)
  storageAccountName: !empty(storageAccountName) && !(resourceNamingMode == 'caf' && storageAccountName == _legacyResourceNames.storageAccountName) ? storageAccountName : (resourceNamingMode == 'caf' ? _cafResourceNames.storageAccountName : _legacyResourceNames.storageAccountName)
  vnetName: !empty(vnetName) && !(resourceNamingMode == 'caf' && vnetName == _legacyResourceNames.vnetName) ? vnetName : (resourceNamingMode == 'caf' ? _cafResourceNames.vnetName : _legacyResourceNames.vnetName)
}

// ----------------------------------------------------------------------
// Azure AI Foundry Service params
// ----------------------------------------------------------------------

@description('List of model deployments to create in the AI Foundry account')
param modelDeploymentList array

// ----------------------------------------------------------------------
// Container Apps params
// ----------------------------------------------------------------------

@description('List of container apps to create. Dapr is opt-in per app through `dapr.enabled=true`; apps without a `dapr` object deploy with Dapr disabled. Optional `image` keeps an already deployed image on reprovision; when empty the placeholder image is used.')
param containerAppsList array

@description('Workload profiles.')
param workloadProfiles array = []

param acrDnsSuffix string = (environment().name == 'AzureUSGovernment' ? 'azurecr.us' : environment().name == 'AzureChinaCloud'   ? 'azurecr.cn' : 'azurecr.io')

var effectiveFoundryIqKnowledgeSourceKind = retrievalBackend == 'foundry_iq'
  ? (!empty(foundryIqKnowledgeSourceKind) ? foundryIqKnowledgeSourceKind : (foundryIqPattern == 'searchIndex' ? 'searchIndex' : 'azureBlob'))
  : ''
var effectiveFoundryIqIngestionPermissionOptions = !empty(foundryIqIngestionPermissionOptionsJson) ? json(foundryIqIngestionPermissionOptionsJson) : foundryIqIngestionPermissionOptions

// ----------------------------------------------------------------------
// Cosmos DB Database params
// ----------------------------------------------------------------------

@description('Optional throughput (RU/s) for the Cosmos DB database. Omit or set to null for serverless accounts.')
param dbDatabaseThroughput int?

@description('List of Cosmos DB containers to create. Each entry supports optional throughput and indexingPolicy via safe access.')
param databaseContainersList array

@description('Enable Synapse Link / Analytical Storage on the workload Cosmos DB account. Default is false because (a) Azure rejects this on account creation in several region/subscription combinations with the literal error "Enabling analytical storage on account creation is not supported in this subscription/region. Please disable analytical storage on the account creation request and try again." (notably observed in swedencentral, see issue #93), and (b) the default landing-zone topology does not deploy any Analytical Store consumer (Synapse Link, Fabric Mirroring). The value only takes effect at account creation; Azure does not permit toggling it on an existing Cosmos DB account, so a failed provision requires deleting the account before retrying. Set to true only when a downstream pipeline actively consumes the analytical store and the target region/subscription is known to allow it. The preflight check Test-CosmosAnalyticalStorageRegionSupport will WARN if this is true in a known-restrictive region.')
param enableCosmosAnalyticalStorage bool = false

// ----------------------------------------------------------------------
// VM params
// ----------------------------------------------------------------------

@description('The name of the Test VM. If left empty, a random name will be generated.')
param vmName string = ''

@description('Test vm user name. Needed only when choosing network isolation and create bastion option. If not you can leave it blank.')
param vmUserName string = ''

@secure()
@description('Admin password for the test VM user')
param vmAdminPassword string

@description('Size of the test VM')
param vmSize string = 'Standard_D2s_v5'

@description('Image SKU (e.g., 2022-datacenter-azure-edition, win11-25h2-ent).')
param vmImageSku string = '2022-datacenter-azure-edition'

@description('Image publisher (Windows Server: MicrosoftWindowsServer, Windows 11: MicrosoftWindowsDesktop).')
param vmImagePublisher string = 'MicrosoftWindowsServer'

@description('Image offer (Windows Server: WindowsServer, Windows 11: windows-11).')
param vmImageOffer string = 'WindowsServer'

@description('Image version (use latest unless you need a pinned build).')
param vmImageVersion string = 'latest'


// ----------------------------------------------------------------------
// Storage Account params
// ----------------------------------------------------------------------

@description('List of containers to create in the Storage Account')
param storageAccountContainersList array

// ----------------------------------------------------------------------
// CMK params
// ----------------------------------------------------------------------
// Note : Customer Managed Keys (CMK) not implemented in this module yet
// @description('Use Customer Managed Keys for Storage Account and Key Vault')
// param useCMK      bool   = false

// ----------------------------------------------------------------------
// Component deployment invariants. A parameter-only nested deployment keeps
// these checks compatible with the repository's pinned Bicep version.
// ----------------------------------------------------------------------
module componentFlagValidation 'modules/validation/component-flags.bicep' = {
  name: 'componentFlagValidation'
  params: {
    containerAppsRequireEnvironment: !deployContainerApps || deployContainerEnv
    containerAppApiKeysHavePrerequisites: !useCAppAPIKey || (deployContainerApps && deployKeyVault && deployAppConfig && appRuntimeConfigurationMode == 'appConfig')
    existingSubnetNsgAssociationsAreProtected: !(networkIsolation && useExistingVNet && deploySubnets && !deployNsgs)
  }
}

//////////////////////////////////////////////////////////////////////////
// VARIABLES
//////////////////////////////////////////////////////////////////////////

// ----------------------------------------------------------------------
// General Variables
// ----------------------------------------------------------------------

// The repository-root manifest.json is the single release manifest: `components`
// feed the jumpbox clone list and `infra.source.tag` pins install.ps1 (ADR-0015).
var _manifest = loadJsonContent('../manifest.json')
var _infraSourceTag = _manifest.infra.source.tag
var _azdTags = { 'azd-env-name': environmentName }
var _modeTags = { deploymentMode: deploymentMode, 'ai-lz-version': 'v2.0.0' }
var _tags = union(_azdTags, _modeTags, deploymentTags)

// Derive the list of additional Git repositories to clone onto the jumpbox
// directly from `manifest.json#components`. Consumers that use this landing
// zone as a Bicep module / git submodule overlay their own `manifest.json`
// (the documented submodule pattern) and so control the components there as
// the single source of truth, without needing per-deployment Bicep params.
// The derived CSV strings are forwarded to install.ps1 via the CSE
// commandToExecute as `-ExtraRepoUrls/-ExtraRepoTags/-ExtraRepoNames`. See
// issue #22.
var _manifestComponents = _manifest.?components ?? []
var _extraRepoUrls  = [for c in _manifestComponents: c.repo]
var _extraRepoTags  = [for c in _manifestComponents: c.?tag ?? 'main']
var _extraRepoNames = [for c in _manifestComponents: c.?name ?? replace(last(split(c.repo, '/')), '.git', '')]

var _networkIsolation = empty(string(networkIsolation)) ? false : bool(networkIsolation)
var _hostedAgentPrerequisitesEnabled = prepareHostedAgent || deployHostedAgent

#disable-next-line BCP318
var _hostedAgentContainerRegistryResourceId = deployContainerRegistry ? containerRegistry.id : hostedAgentContainerRegistryResourceId
var _hostedAgentContainerRegistryEndpoint = deployContainerRegistry ? '${resourceNames.containerRegistryName}.${acrDnsSuffix}' : hostedAgentContainerRegistryEndpoint
var _hostedAgentImageReference = deployHostedAgent ? '${_hostedAgentContainerRegistryEndpoint}/${hostedAgent.image}@${hostedAgent.version}' : ''
var _containerRegistryRepositoryReaderRoleId = 'b93aa761-3e63-49ed-ac28-beffa264f7ac'
var _hostedAgentContainerRegistryPullRoleId = deployContainerRegistry || hostedAgentContainerRegistryRoleAssignmentMode == 'rbac'
  ? const.roles.AcrPull.guid
  : _containerRegistryRepositoryReaderRoleId

// -----------------------------------------------------------------------------
// Public network access derivation (Gap 1, issue #58)
// -----------------------------------------------------------------------------
// `publicNetworkAccess` for every workload service is now derived from two
// flat inputs rather than coupled directly to `_networkIsolation`:
//
//   _applyIpRules:        true when the operator provided one or more CIDRs.
//   _publicNetworkAccess: 'Enabled' when the topology is public OR an
//                         IP allow-list is in effect; otherwise 'Disabled'.
//
// Two parameters cover all four scenarios documented in issue #58:
//
//   networkIsolation=true,  allowedIpRanges=[]      -> Private only
//   networkIsolation=true,  allowedIpRanges=[CIDR]  -> Private + public allow-list
//   networkIsolation=false, allowedIpRanges=[]      -> Public
//   networkIsolation=false, allowedIpRanges=[CIDR]  -> Public restricted to listed IPs
//
// Per-service rule arrays are pre-shaped because each Azure RP exposes a
// slightly different schema (Storage/ACR use `{value, action}`, KV/Search/
// Cognitive use `{value}`, Cosmos accepts a flat string[]).
var _applyIpRules        = !empty(allowedIpRanges)
var _publicNetworkAccess = (!_networkIsolation || _applyIpRules) ? 'Enabled' : 'Disabled'
var _storageIpRules      = [for ip in allowedIpRanges: { value: ip, action: 'Allow' }]
var _acrIpRules          = [for ip in allowedIpRanges: { value: ip, action: 'Allow' }]
var _keyVaultIpRules     = [for ip in allowedIpRanges: { value: ip }]
var _searchIpRules       = [for ip in allowedIpRanges: { value: ip }]
var _cognitiveIpRules    = [for ip in allowedIpRanges: { value: ip }]
var _cosmosIpRules       = allowedIpRanges
// ---------------------------------------------------------------------------
// Hub-component effective deployment derivations (Gap 4, issue #58)
// ---------------------------------------------------------------------------
// Nullable inputs coalesce to v1.x defaults so existing parameter files
// (without the new flags) behave identically. BYO resource IDs flip the
// default to `false` automatically — explicit `true/false` always wins.
var _hasExistingJumpbox     = !empty(existingJumpboxResourceId ?? '')
var _hasExistingBastion     = !empty(existingBastionResourceId ?? '')
var _hasExistingNatGateway  = !empty(existingNatGatewayResourceId ?? '')

// Legacy fallback (v1.x compatibility): when `deployVM` is non-null, it acts
// as a global default for all three new flags so existing parameter files
// (e.g. the Agent Landing Zone manifest-driven overlay) keep working unmodified. Explicit
// new flags ALWAYS win — `deployVM` is purely a fallback layer. Slated for
// removal in v3.0.0; emits a deployment-time warning when consumed.
var _legacyDeployVMSet      = !(deployVM == null)
#disable-next-line BCP318
var _legacyDeployVMValue    = _legacyDeployVMSet ? deployVM! : false
var _deployJumpbox          = deployJumpbox    ?? (_legacyDeployVMSet ? (_legacyDeployVMValue && _networkIsolation && !_hasExistingJumpbox)    : (_networkIsolation && !_hasExistingJumpbox))
var _deployBastion          = deployBastion    ?? (_legacyDeployVMSet ? (_legacyDeployVMValue && _networkIsolation && _deployJumpbox && !_hasExistingBastion)    : (_networkIsolation && _deployJumpbox && !_hasExistingBastion))
var _deployNatGateway       = deployNatGateway ?? (_legacyDeployVMSet ? (_legacyDeployVMValue && _networkIsolation && _deployJumpbox && !_hasExistingNatGateway) : (_networkIsolation && _deployJumpbox && !_hasExistingNatGateway))

// Effective NAT Gateway ID — when we deploy our own NAT GW, use that. When
// the operator BYO'd one, use theirs. Otherwise empty (subnet leaves
// natGateway unset). Wired into `baseSubnets[jumpbox].natGatewayResourceId`
// so both code paths (greenfield + useExistingVNet) attach the subnet
// to the NAT GW.
#disable-next-line BCP318
var _effectiveNatGatewayId  = _deployNatGateway ? natGateway.id : (_hasExistingNatGateway ? existingNatGatewayResourceId! : '')

// ---------------------------------------------------------------------------
// Observability reuse derivations (Gap 5, issue #58)
// ---------------------------------------------------------------------------
// When the operator supplies an existing LAW or AppInsights resource ID, we
// SKIP creating those resources locally and route every consumer — diagnostic
// settings, AMPLS, Container Apps Environment telemetry, App Configuration
// publishing — to the existing IDs instead.
//
//   _hasExistingLaw / _hasExistingAI  : BYO ID provided?
//   _createLogAnalytics / _createAppInsights : do we deploy our own?
//   _lawResourceId / _appInsightsResourceId  : effective IDs to wire downstream
//   _appInsightsConnectionString             : effective connection string for
//                                              Container Apps + App Config
//
// Cross-RG-safe: we never call `.id` / `.properties` against `existing`
// resources here — those are passed through unchanged as raw strings.
var _hasExistingLaw           = !empty(existingLogAnalyticsWorkspaceResourceId ?? '')
var _hasExistingAI            = !empty(existingApplicationInsightsResourceId ?? '')
var _createLogAnalytics       = deployLogAnalytics && !_hasExistingLaw
var _createAppInsights        = deployAppInsights && !_hasExistingAI && (_createLogAnalytics || _hasExistingLaw)
#disable-next-line BCP318
var _lawResourceId            = _hasExistingLaw ? existingLogAnalyticsWorkspaceResourceId! : (_createLogAnalytics ? logAnalytics.id : '')
#disable-next-line BCP318
var _appInsightsResourceId    = _hasExistingAI ? existingApplicationInsightsResourceId! : (_createAppInsights ? appInsights.id : '')
#disable-next-line BCP318
var _appInsightsConnectionString = _hasExistingAI ? (existingApplicationInsightsConnectionString ?? '') : (_createAppInsights ? appInsights.properties.ConnectionString : '')
// Instrumentation key is the first KV pair in a v2 connection string
// ("InstrumentationKey=<guid>;..."). We split safely so an empty string
// returns an empty key rather than failing the template.
var _appInsightsInstrumentationKey = !empty(_appInsightsConnectionString)
  ? split(split(_appInsightsConnectionString, ';')[0], '=')[1]
  : ''
var _hasEffectiveLaw          = !empty(_lawResourceId)
var _hasEffectiveAI           = !empty(_appInsightsResourceId)

// ----------------------------------------------------------------------
// Gap 6 — External egress / route table reuse
// ----------------------------------------------------------------------
// Three valid configurations are now supported for the spoke 0.0.0.0/0 default route:
//   1. Standalone (deployAzureFirewall=true)                : local FW, local RT, route → local FW IP.
//   2. AI-LZ-integrated, hub-FW shared                       : deployAzureFirewall=false +
//                                                             hubIntegrationEgressNextHopIp set → local RT,
//                                                             route → hub FW IP.
//   3. AI-LZ-integrated, platform-team-owned RT              : hubIntegrationExistingRouteTableResourceId set →
//                                                             no local RT, no local default route. The
//                                                             platform team's RT is attached to spoke subnets
//                                                             and is assumed to already define egress routing.
// Any other combination is invalid and surfaced by the pre-flight script (Gap 9).
var _hasExistingRouteTable = !empty(hubIntegrationExistingRouteTableResourceId ?? '')
var _hasExternalEgress     = !empty(hubIntegrationEgressNextHopIp ?? '')
var _createRouteTable      = _networkIsolation && !_hasExistingRouteTable
#disable-next-line BCP318
var _effectiveRouteTableId = _hasExistingRouteTable
  ? hubIntegrationExistingRouteTableResourceId!
  : (_createRouteTable ? routeTable.id : '')
var _createDefaultRoute    = _createRouteTable && (deployAzureFirewall || _hasExternalEgress)
var _defaultRouteNextHopIp = deployAzureFirewall
  ? firewall.outputs.privateIp
  : (_hasExternalEgress ? hubIntegrationEgressNextHopIp! : '')

// ----------------------------------------------------------------------
// Gap 7 — Hub VNet peering (spoke side)
// ----------------------------------------------------------------------
// Spoke→hub peering is created inline when the spoke owns its VNet
// (useExistingVNet=false) and the operator opts in. The hub VNet may
// reside in a different subscription/RG; we parse its segments so the
// peering resource (which lives under the spoke VNet) can reference
// the remote VNet correctly. The reverse hub→spoke peering is the
// operator's responsibility — see tests/scripts/Add-HubSpokePeering.ps1.
var _hasHubVnet      = !empty(hubIntegrationHubVnetResourceId ?? '')
var _createSpokeToHubPeering = _hasHubVnet && hubIntegrationCreateHubPeering && _networkIsolation && !useExistingVNet
var _hubVnetSegs   = _hasHubVnet ? split(hubIntegrationHubVnetResourceId!, '/') : ['']
var _hubVnetName   = length(_hubVnetSegs) >= 9 ? _hubVnetSegs[8] : ''

// AMPLS (Azure Monitor Private Link Scope) and the related monitor/opinsights/automation
// private DNS zones + private endpoint are only deployed when network isolation is on AND
// the operator explicitly opts in via enablePrivateLogAnalytics AND we're creating our
// own LAW locally (a BYO/central LAW is assumed to be private-linked centrally already,
// so deploying a duplicate AMPLS would conflict on the shared monitor private DNS zones).
var _deployAmpls = _networkIsolation && _createAppInsights && _createLogAnalytics && enablePrivateLogAnalytics
var _deployPrivateDnsZones = _networkIsolation && !policyManagedPrivateDns
var _searchServiceLocation = empty(searchServiceLocation) ? location : searchServiceLocation
var _speechServiceLocation = empty(speechServiceLocation) ? location : speechServiceLocation
var _deployAiFoundryAgentService = deployAiFoundry && deployAAfAgentSvc
var _useExistingAiFoundrySearch = !empty(aiSearchResourceId)
var _useExistingAiFoundryStorage = !empty(aiFoundryStorageAccountResourceId)
var _useExistingAiFoundryCosmos = !empty(aiFoundryCosmosDBAccountResourceId)
var _deployAiFoundrySearch = _deployAiFoundryAgentService && !_useExistingAiFoundrySearch
var _deployAiFoundryStorage = _deployAiFoundryAgentService && !_useExistingAiFoundryStorage


// ----------------------------------------------------------------------
// Container vars
// ----------------------------------------------------------------------

// Placeholder image deployed initially; replaced by the operator's real image
// via `azd deploy`. Pinned to `aspnetapp-9.0` because:
//   - it listens on port 8080 by default (matches our `target_port` default,
//     so the placeholder serves a working page out of the box and lets the
//     operator validate ingress before deploying their app);
//   - it is published on MCR (no auth required from ACA pull egress);
//   - the explicit tag prevents drift when Microsoft retags `:aspnetapp`.
var _containerDummyImageName = 'mcr.microsoft.com/dotnet/samples:aspnetapp-9.0'

// ----------------------------------------------------------------------
// Networking vars
// ----------------------------------------------------------------------

// Parse existing VNet Resource ID if provided
var varVnetIdSegments = empty(existingVnetResourceId) ? [''] : split(existingVnetResourceId, '/')
var varExistingVnetSubscriptionId = length(varVnetIdSegments) >= 3 ? varVnetIdSegments[2] : subscription().subscriptionId
var varExistingVnetResourceGroupName = length(varVnetIdSegments) >= 5 ? varVnetIdSegments[4] : resourceGroup().name
var varExistingVnetName = length(varVnetIdSegments) >= 9 ? varVnetIdSegments[8] : ''

var virtualNetworkResourceId = _networkIsolation ? (useExistingVNet ? existingVnetResourceId : virtualNetwork!.outputs.resourceId) : ''

#disable-next-line BCP318
var _peSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${peSubnetName}' : ''
#disable-next-line BCP318
var _caEnvSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${acaEnvironmentSubnetName}' : ''
#disable-next-line BCP318
var _jumpbxSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${jumpboxSubnetName}' : ''
#disable-next-line BCP318
var _agentSubnetId = _networkIsolation ? '${virtualNetworkResourceId}/subnets/${agentSubnetName}' : ''

var _peLocation = !empty(privateEndpointLocation) ? privateEndpointLocation : location
var _defaultPeResourceGroupName = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _peResourceGroupName = !empty(privateEndpointResourceGroupName) ? privateEndpointResourceGroupName : _defaultPeResourceGroupName

// ----------------------------------------------------------------------
// VM vars
// ----------------------------------------------------------------------

var _vmBaseName = !empty(vmName) ? vmName : 'testvm${resourceToken}'
var _vmName = substring(_vmBaseName, 0, 15)
var _vmUserName = !empty(vmUserName) ? vmUserName : 'testvmuser'

// ----------------------------------------------------------------------
// Container App vars
// ----------------------------------------------------------------------

var _containerAppsKeyVaultKeysTemp =  [
  for app in containerAppsList: {
    name: '${app.canonical_name}_APIKEY'
    value: resourceToken
    contentType: 'string'
  }
]
var _containerAppsKeyVaultKeys = _useCAppAPIKey && _deployContainerApps && deployKeyVault && deployAppConfig && _runtimeConfigIsAppConfig ? _containerAppsKeyVaultKeysTemp : []

// ----------------------------------------------------------------------
// // Feature-flagging vars 
// ----------------------------------------------------------------------
var _useUAI         = empty(string(useUAI)) ? false : bool(useUAI)
var _useCAppAPIKey  = empty(string(useCAppAPIKey))? false : bool(useCAppAPIKey)
var _containerAppApiKeyPrerequisitesMet = !_useCAppAPIKey || (deployKeyVault && deployAppConfig && _runtimeConfigIsAppConfig)
var _deployContainerApps = deployContainerApps && deployContainerEnv && _containerAppApiKeyPrerequisitesMet

// ----------------------------------------------------------------------
// App runtime configuration mode (Issue #89)
// ----------------------------------------------------------------------
// ``appConfig``     -> existing behavior: App Configuration store is populated
//                       with deployment outputs and Container Apps receive
//                       APP_CONFIG_ENDPOINT + the AppConfigurationDataReader RBAC.
// ``containerEnv``  -> App Configuration population is skipped; Container Apps
//                       receive a curated bootstrap env (tenant, subscription,
//                       RG, location, resource token, network/identity flags
//                       and the names of the deployed resources) so consumers
//                       can resolve everything else through the Azure SDK
//                       without going through App Configuration.
// ``none``          -> Container Apps are deployed with only the identity
//                       bootstrap (AZURE_TENANT_ID, AZURE_CLIENT_ID when UAI);
//                       callers supply runtime configuration through their own
//                       mechanism. Secrets remain on secure params / Key Vault.
var _runtimeConfigIsAppConfig    = appRuntimeConfigurationMode == 'appConfig'
var _runtimeConfigIsContainerEnv = appRuntimeConfigurationMode == 'containerEnv'

//////////////////////////////////////////////////////////////////////////
// RESOURCES
//////////////////////////////////////////////////////////////////////////

// Security
///////////////////////////////////////////////////////////////////////////

// Network Watcher
// Note: Automatically provisioned when network isolation is enabled (VNet deployment)

// Azure Defender for Cloud
// Note: By default, free tier (foundational recommendations) is enabled at the subscription level.
//       To enable its advanced threat protection features, Defender plans must be explicitly configured
//       using the Microsoft.Security/pricings resource (e.g., for Storage, Key Vault, App Services).

// Purview Compliance Manager
// Note: Not applicable, it's part of Microsoft 365 Compliance Center, not Azure Resource Manager.

// Networking
///////////////////////////////////////////////////////////////////////////

// Bastion NSG — restricts inbound 443 to trusted IPs only
module bastionNsg 'modules/networking/bastion-nsg.bicep' = if (_deployBastion && deployNsgs) {
  name: 'bastionNsgDeployment'
  params: {
    name: 'nsg-${resourceNames.vnetName}-${azureBastionSubnetName}'
    location: location
    bastionAllowedSourceIPs: bastionAllowedSourceIPs
  }
}

// Public Ingress NSG (#49) — declared in main.bicep because the Application
// Gateway subnet's `networkSecurityGroupResourceId` must be set in the same
// subnet declaration that creates the subnet. Splitting NSG creation out of
// the public-ingress module avoids a circular dependency between the subnet
// and the gateway.
module appGwNsg 'modules/networking/appgw-nsg.bicep' = if (_publicIngressEnabled) {
  name: 'appGwNsgDeployment'
  params: {
    name: 'nsg-${resourceNames.vnetName}-${azureAppGatewaySubnetName}'
    location: location
    allowedSourceAddressPrefixes: _publicIngressAllowedSources
  }
}

var _deployAcrTaskAgentPool = deployContainerRegistry && _networkIsolation && deployAcrTaskAgentPool

// Public Ingress (#49) — only effective in network-isolated mode with Container
// Apps deployed. The gateway fronts an internal ACA environment, so it is a
// no-op outside that topology.
var _publicIngressEnabled = publicIngress.enabled && _networkIsolation && deployContainerEnv && deployContainerApps && length(containerAppsList) > 0
var _publicIngressBackendIndex = publicIngress.?backendAppIndex ?? 0
var _publicIngressAllowedSources = publicIngress.?allowedSourceAddressPrefixes ?? []

// Route Table for egress traffic control through Azure Firewall (or external NVA, Gap 6).
// Created only when network isolation is on AND no existing RT is provided via
// `hubIntegrationExistingRouteTableResourceId`.
resource routeTable 'Microsoft.Network/routeTables@2024-07-01' = if (_createRouteTable) {
  name: '${const.abbrs.networking.routeTable}${resourceToken}'
  location: location
  tags: _tags
  properties: {
    disableBgpRoutePropagation: true
  }
}

// Base subnets that are always included
var baseSubnets = [
      {
        name: agentSubnetName
        addressPrefix: agentSubnetPrefix 
        // Issue #110: the serviceName must be the canonical 'Microsoft.App/environments'
        // (capital 'A'). The AVM virtual-network module emits the same string for both
        // the delegation `name` and `properties.serviceName`, and AmlRp's capability
        // host validator does a case-sensitive lookup on `serviceName` when creating
        // `<account>@aml_aiagentservice`. With lowercase 'app', capability host create
        // fails ~47min into provision with "Invalid vnet resource ID provided, or the
        // virtual network could not be found." even though the VNet/subnet are healthy.
        delegation: 'Microsoft.App/environments'
        routeTableResourceId: _effectiveRouteTableId
        serviceEndpoints: [
          'Microsoft.CognitiveServices'
        ]
      }
      {
        name: peSubnetName
        addressPrefix: peSubnetPrefix 
        routeTableResourceId: _effectiveRouteTableId
        serviceEndpoints: [
          'Microsoft.AzureCosmosDB'
        ]        
        delegation: ''
      }
      {
        name: gatewaySubnetName
        addressPrefix: gatewaySubnetPrefix 
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureBastionSubnetName
        addressPrefix: azureBastionSubnetPrefix
        #disable-next-line BCP318
        networkSecurityGroupResourceId: (_deployBastion && deployNsgs) ? bastionNsg!.outputs.id : ''
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureFirewallSubnetName
        addressPrefix: azureFirewallSubnetPrefix 
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: azureAppGatewaySubnetName
        addressPrefix: azureAppGatewaySubnetPrefix  
        #disable-next-line BCP318
        networkSecurityGroupResourceId: _publicIngressEnabled ? appGwNsg!.outputs.id : ''
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: jumpboxSubnetName
        addressPrefix: jumpboxSubnetPrefix 
        natGatewayResourceId: _effectiveNatGatewayId
        routeTableResourceId: _effectiveRouteTableId
        delegation: ''
        serviceEndpoints : []
      }
      {
        name: acaEnvironmentSubnetName
        addressPrefix: acaEnvironmentSubnetPrefix  
        // Match the agent-subnet delegation casing (see comment above). Canonical
        // 'Microsoft.App/environments' avoids any case-sensitive lookup downstream.
        delegation: 'Microsoft.App/environments'
        routeTableResourceId: _effectiveRouteTableId
        serviceEndpoints: [
          'Microsoft.AzureCosmosDB'
        ]
      }
      {
        name: devopsBuildAgentsSubnetName
        addressPrefix: devopsBuildAgentsSubnetPrefix 
        routeTableResourceId: _effectiveRouteTableId
        delegation: ''
        serviceEndpoints : []
      }
]

var subnets = baseSubnets

module virtualNetworkSubnets 'modules/networking/subnets.bicep' = if (_networkIsolation && useExistingVNet && deploySubnets && deployNsgs) {
  name: 'virtualNetworkSubnetsDeployment'
  params: {
    vnetName: useExistingVNet ? varExistingVnetName : resourceNames.vnetName
    location: location
    resourceGroupName: useExistingVNet ? varExistingVnetResourceGroupName : resourceGroup().name
    subscriptionId: useExistingVNet ? varExistingVnetSubscriptionId : subscription().subscriptionId
    tags: _tags
    addressPrefixes: vnetAddressPrefixes
    subnets: subnets
    deploySubnets : deploySubnets
    deployNsgs: deployNsgs
    useExistingVNet: useExistingVNet
    virtualNetworkResourceId: virtualNetworkResourceId
  }
}

// VNet
// Note on IP address sizing: https://learn.microsoft.com/en-us/azure/ai-foundry/agents/how-to/virtual-networks#known-limitations
module virtualNetwork 'br/public:avm/res/network/virtual-network:0.7.0' = if (_networkIsolation && !useExistingVNet) {
  name: 'virtualNetworkDeployment'
  params: {
    // VNet sized /16 to fit all subnets
    addressPrefixes: vnetAddressPrefixes
    name: resourceNames.vnetName
    location: location

    tags: _tags
    subnets: subnets
  }
}

// Gap 7 — Spoke→hub VNet peering.
// Lives under the locally-created spoke VNet; the existing resource
// reference below ensures Bicep can attach the peering as a child without
// the AVM module having to expose a peerings property.
resource spokeVnetForPeering 'Microsoft.Network/virtualNetworks@2024-07-01' existing = if (_createSpokeToHubPeering) {
  name: resourceNames.vnetName
}

resource spokeToHubPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2024-07-01' = if (_createSpokeToHubPeering) {
  parent: spokeVnetForPeering
  name: 'to-hub-${_hubVnetName}'
  properties: {
    allowVirtualNetworkAccess: true
    // Required so the hub Azure Firewall (or any hub NVA) can forward spoke
    // traffic on behalf of the spoke. Without this, asymmetric routing
    // through the hub firewall breaks.
    allowForwardedTraffic: true
    allowGatewayTransit: hubIntegrationPeeringAllowGatewayTransit
    useRemoteGateways: hubIntegrationPeeringUseRemoteGateways
    remoteVirtualNetwork: {
      #disable-next-line BCP318
      id: hubIntegrationHubVnetResourceId!
    }
  }
  dependsOn: [
    virtualNetwork
  ]
}

// Bastion Host
// Bastion Host — replaced the AVM `bastion-host` module with a raw resource so
// `enableTunneling` can be set (the AVM module up to 0.8.2 does not expose it).
// Native-client tunneling is required for `az network bastion rdp/ssh`, RDP
// audio/clipboard/device redirection, and SSH agent forwarding from inside the
// spoke. Behavior-equivalent to the previous module call: same subnet
// (AzureBastionSubnet), Standard static PIP, optional zone redundancy, tags.
resource bastionPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (_deployBastion) {
  name: '${const.abbrs.networking.publicIPAddress}bastion-${resourceToken}'
  location: location
  tags: _tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  zones: useZoneRedundancy ? ['1', '2', '3'] : []
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource testVmBastionHost 'Microsoft.Network/bastionHosts@2024-07-01' = if (_deployBastion) {
  name: '${const.abbrs.security.bastion}testvm-${resourceToken}'
  location: location
  tags: _tags
  sku: {
    name: bastionSkuName
  }
  zones: useZoneRedundancy ? ['1', '2', '3'] : []
  properties: {
    // enableTunneling is silently coerced to false on Basic SKU because the
    // Basic SKU does not support native client tunneling. Standard and Premium
    // accept the value.
    enableTunneling: bastionEnableTunneling && bastionSkuName != 'Basic'
    ipConfigurations: [
      {
        name: 'IpConfAzureBastionSubnet'
        properties: {
          subnet: {
            #disable-next-line BCP318
            id: '${virtualNetworkResourceId}/subnets/AzureBastionSubnet'
          }
          publicIPAddress: {
            id: bastionPublicIp.id
          }
        }
      }
    ]
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

// Azure Firewall for egress traffic control
///////////////////////////////////////////////////////////////////////////

module firewall 'modules/networking/azure-firewall.bicep' = {
  name: 'firewall'
  params: {
    deployAzureFirewall: deployAzureFirewall
    enableFirewallDnsProxy: enableFirewallDnsProxy
    networkIsolation: _networkIsolation
    enableAcsMediaEgress: enableAcsMediaEgress
    deploySpeechService: deploySpeechService
    deployAcrTaskAgentPool: _deployAcrTaskAgentPool
    extendFirewallForJumpboxBootstrap: extendFirewallForJumpboxBootstrap
    extendFirewallForAcrTaskBuilds: extendFirewallForAcrTaskBuilds
    additionalAcrTaskBuildFqdns: additionalAcrTaskBuildFqdns
    resourceToken: resourceToken
    location: location
    tags: _tags
    virtualNetworkResourceId: virtualNetworkResourceId
    azureFirewallSubnetName: azureFirewallSubnetName
    jumpboxSubnetPrefix: jumpboxSubnetPrefix
    devopsBuildAgentsSubnetPrefix: devopsBuildAgentsSubnetPrefix
    acaEnvironmentSubnetPrefix: acaEnvironmentSubnetPrefix
    agentSubnetPrefix: agentSubnetPrefix
    hasEffectiveLaw: _hasEffectiveLaw
    lawResourceId: _lawResourceId
  }
  dependsOn: [
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

// Default route through Azure Firewall (local) or external NVA/hub firewall (Gap 6).
// Skipped entirely when the operator brings their own Route Table via
// `hubIntegrationExistingRouteTableResourceId` (we don't write into a foreign RT).
resource defaultRoute 'Microsoft.Network/routeTables/routes@2024-07-01' = if (_createDefaultRoute) {
  parent: routeTable
  name: 'default-to-firewall'
  properties: {
    addressPrefix: '0.0.0.0/0'
    nextHopType: 'VirtualAppliance'
    nextHopIpAddress: _defaultRouteNextHopIp
  }
}

//Test VM User Managed Identity
resource testVmUAI 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = if (_useUAI) {
  name: '${const.abbrs.security.managedIdentity}${_vmName}'
  location: location
}

// Test VM
module testVm 'br/public:avm/res/compute/virtual-machine:0.15.0' = if (_deployJumpbox) {
  name: 'testVmDeployment'
  params: {
    name: _vmName
    location: location
    adminUsername: _vmUserName
    adminPassword: vmAdminPassword
    managedIdentities: {
      systemAssigned: _useUAI ? false : true
      #disable-next-line BCP318
      userAssignedResourceIds: _useUAI ? [testVmUAI.id] : []
    }
    imageReference: {
      publisher: vmImagePublisher
      offer:     vmImageOffer
      sku:       vmImageSku
      version:   vmImageVersion
    }
    encryptionAtHost: false 
    vmSize: vmSize
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: 250
      managedDisk: {
        storageAccountType: 'Standard_LRS'
      }
      
    }
    osType: 'Windows'
    zone: 0
    nicConfigurations: [
      {
        nicSuffix: '-nic-01'
        ipConfigurations: [
          {
            name: 'ipconfig01'
            #disable-next-line BCP318
            subnetResourceId: _jumpbxSubnetId
          }
        ]
      }
    ]
  }
  dependsOn: [
    testVmBastionHost
    #disable-next-line BCP321
    !useExistingVNet ? virtualNetwork : null
    #disable-next-line BCP321
    useExistingVNet ? virtualNetworkSubnets : null
  ]
}

resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = if (_deployNatGateway) {
  name: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.natGateway}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
    idleTimeoutInMinutes: 30
    dnsSettings: {
      domainNameLabel: '${const.abbrs.networking.publicIPAddress}${const.abbrs.networking.natGateway}${resourceToken}'
    }
  }
  tags: _tags
}

#disable-next-line BCP081
resource natGateway 'Microsoft.Network/natGateways@2024-10-01' = if (_deployNatGateway) {
  name: '${const.abbrs.networking.natGateway}${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// TestVM role assignments (consolidated into a single array-driven module call
// to keep the compiled ARM template under the 4 MB deployment limit).
// ---------------------------------------------------------------------------
var _testVmPrincipalId = _deployJumpbox
  #disable-next-line BCP318
  ? (_useUAI ? testVmUAI.properties.principalId : testVm.outputs.systemAssignedMIPrincipalId!)
  : ''

var _testVmRoles = _deployJumpbox ? concat(
  [
    // Reader on the resource group itself so the jumpbox SAMI can enumerate
    // ARM resources from inside the VNet (`az resource list`,
    // `az cosmosdb list`, `az containerapp list`, …). Required by consumer
    // postProvision / data-seed scripts that resolve resource names by
    // discovery when env vars / App Config values are missing or the script
    // is being run interactively for troubleshooting. Without this, every
    // ARM list call returns `[]` even though the SAMI already has the
    // data-plane roles needed for the actual operations. Scoped to the
    // resource group (empty `resourceId` => deployment scope, which is RG).
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.Reader.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
  ],
  (deployAppConfig && deployContainerRegistry) ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerAppsContributor.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ManagedIdentityOperator.guid)
      principalId: _testVmPrincipalId
      resourceId: ''
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryRepositoryWriter.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryContributorDataAccessConfigurationAdministrator.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.ContainerRegistryTasksContributor.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployAppConfig ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AppConfigurationDataOwner.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: appConfig.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployContainerRegistry ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.AcrPush.guid)
      #disable-next-line BCP318
      resourceId: containerRegistry.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployKeyVault ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultContributor.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultSecretsOfficer.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.KeyVaultCertificatesOfficer.guid)
      #disable-next-line BCP318
      resourceId: keyVault.id
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deploySearchService ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchServiceContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.SearchIndexDataContributor.guid)
      #disable-next-line BCP318
      resourceId: searchService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployAiFoundry ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      principalId: _testVmPrincipalId
      resourceId: aiFoundryAccountResourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesOpenAIUser.guid)
      resourceId: aiFoundryAccountResourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deploySpeechService ? [
    {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesContributor.guid)
      principalId: _testVmPrincipalId
      #disable-next-line BCP318
      resourceId: speechService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.CognitiveServicesUser.guid)
      #disable-next-line BCP318
      resourceId: speechService.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : [],
  deployStorageAccount ? [
    {
      principalId: _testVmPrincipalId
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', const.roles.StorageBlobDataContributor.guid)
      #disable-next-line BCP318
      resourceId: storageAccount.outputs.resourceId
      principalType: 'ServicePrincipal'
    }
  ] : []
) : []

module assignTestVmRoles 'modules/security/resource-role-assignment.bicep' = if (_deployJumpbox) {
  name: 'assignTestVmRoles'
  params: {
    name: 'assignTestVmRoles'
    roleAssignments: _testVmRoles
  }
}

// Cosmos DB Account - Cosmos DB Built-in Data Contributor -> TestVm
module assignCosmosDBCosmosDbBuiltInDataContributorTestVm 'modules/security/cosmos-data-plane-role-assignment.bicep' = if (_deployJumpbox && deployCosmosDb) {
  name: 'assignCosmosDBCosmosDbBuiltInDataContributorTestVm'
  params: {
    #disable-next-line BCP318
    cosmosDbAccountName: cosmosDBAccount.outputs.name
    principalId: _testVmPrincipalId
    roleDefinitionGuid: const.roles.CosmosDBBuiltInDataContributor.guid
    scopePath: '/subscriptions/${subscription().subscriptionId}/resourceGroups/${resourceGroup().name}/providers/Microsoft.DocumentDB/databaseAccounts/${resourceNames.dbAccountName}'
  }
}

var _fileUris = [
  'https://raw.githubusercontent.com/Azure/bicep-ptn-aiml-landing-zone/refs/tags/${_infraSourceTag}/install.ps1'
]

// Windows CustomScriptExtension has a FIXED 90-minute platform provisioning
// timeout (`VMExtensionProvisioningTimeout`) that cannot be extended from the
// extension definition — there is no supported `timeout` setting here. Under
// Zero Trust all jumpbox egress traverses the Azure Firewall, so package feeds
// and external downloads can be slow or transiently blocked. `install.ps1` is
// therefore self-limiting: it caps every network operation and tracks an
// overall wall-clock budget (~75 min) so it always reports a terminal status
// before the 90-minute cap, skipping OPTIONAL steps (Python, win-acme,
// component/extra repos) under low budget while keeping CORE steps fatal. See
// issue #82. NOTE: this script is fetched from the tag pinned in
// `manifest.json#infra.source.tag` (and passed as `-release`), so a fix to
// install.ps1 only takes effect once a new tag containing it is published AND
// `infra.source.tag` is bumped to that tag.
resource cse 'Microsoft.Compute/virtualMachines/extensions@2024-11-01' = if (_deployJumpbox && deploySoftware) {
  name: '${_vmName}/cse'
  location: location
  properties: {
    publisher: 'Microsoft.Compute'
    type: 'CustomScriptExtension'
    typeHandlerVersion: '1.10'
    autoUpgradeMinorVersion: true
    forceUpdateTag: deployment().name
    settings: {
      fileUris: _fileUris
      commandToExecute: 'powershell.exe -ExecutionPolicy Unrestricted -File install.ps1 -release ${_infraSourceTag} -UseUAI ${_useUAI} -ResourceToken ${resourceToken} -AzureTenantId ${subscription().tenantId} -AzureLocation ${location} -AzureSubscriptionId ${subscription().subscriptionId} -AzureResourceGroupName ${resourceGroup().name} -AzdEnvName ${environmentName} -ExtraRepoUrls "${join(_extraRepoUrls, ',')}" -ExtraRepoTags "${join(_extraRepoTags, ',')}" -ExtraRepoNames "${join(_extraRepoNames, ',')}"'
    }
    protectedSettings: {
      
    }
  }
  dependsOn: [
    testVm
    appConfigPopulate
    assignTestVmRoles
    assignCosmosDBCosmosDbBuiltInDataContributorTestVm
    firewall
  ]
}

// Private DNS Zones (consolidated into a single for-loop module to keep compiled ARM template under 4 MB).
///////////////////////////////////////////////////////////////////////////

var _dnsZonesTargetRg = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _dnsZonesLinkSuffix = '${useExistingVNet ? '-byon' : ''}${empty(dnsZoneLinkSuffix) ? '' : '-${dnsZoneLinkSuffix}'}'

// Gap 2 — Per-zone BYO flags (true ⇒ skip local creation for that zone).
var _byoZoneCogSvcs        = !empty(existingPrivateDnsZoneCogSvcsResourceId ?? '')
var _byoZoneOpenAi         = !empty(existingPrivateDnsZoneOpenAiResourceId ?? '')
var _byoZoneAiServices     = !empty(existingPrivateDnsZoneAiServicesResourceId ?? '')
var _byoZoneSearch         = !empty(existingPrivateDnsZoneSearchResourceId ?? '')
var _byoZoneCosmos         = !empty(existingPrivateDnsZoneCosmosResourceId ?? '')
var _byoZoneBlob           = !empty(existingPrivateDnsZoneBlobResourceId ?? '')
var _byoZoneKeyVault       = !empty(existingPrivateDnsZoneKeyVaultResourceId ?? '')
var _byoZoneAppConfig      = !empty(existingPrivateDnsZoneAppConfigResourceId ?? '')
var _byoZoneContainerApps  = !empty(existingPrivateDnsZoneContainerAppsResourceId ?? '')
var _byoZoneAcr            = !empty(existingPrivateDnsZoneAcrResourceId ?? '')
var _byoZoneAppInsights    = !empty(existingPrivateDnsZoneAppInsightsResourceId ?? '')
var _byoZoneAzureMonitor   = !empty(existingPrivateDnsZoneAzureMonitorResourceId ?? '')
var _byoZoneOmsOpInsights  = !empty(existingPrivateDnsZoneOmsOpsInsightsResourceId ?? '')
var _byoZoneOdsOpInsights  = !empty(existingPrivateDnsZoneOdsOpsInsightsResourceId ?? '')
var _byoZoneAzureAutomation= !empty(existingPrivateDnsZoneAzureAutomationResourceId ?? '')

var _dnsZonesList = _deployPrivateDnsZones ? concat(
  _byoZoneCogSvcs       ? [] : [ { dnsName: 'privatelink.cognitiveservices.azure.com', virtualNetworkLinkName: '${resourceNames.vnetName}-cogsvcs-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneOpenAi        ? [] : [ { dnsName: 'privatelink.openai.azure.com',            virtualNetworkLinkName: '${resourceNames.vnetName}-openai-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneAiServices    ? [] : [ { dnsName: 'privatelink.services.ai.azure.com',       virtualNetworkLinkName: '${resourceNames.vnetName}-aiservices-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneSearch        ? [] : [ { dnsName: 'privatelink.search.windows.net',          virtualNetworkLinkName: '${resourceNames.vnetName}-search-std-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneCosmos        ? [] : [ { dnsName: 'privatelink.documents.azure.com',         virtualNetworkLinkName: '${resourceNames.vnetName}-cosmos-std-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneBlob          ? [] : [ { dnsName: 'privatelink.blob.${environment().suffixes.storage}', virtualNetworkLinkName: '${resourceNames.vnetName}-blob-std-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneKeyVault      ? [] : [ { dnsName: 'privatelink.vaultcore.azure.net',         virtualNetworkLinkName: '${resourceNames.vnetName}-kv-link${_dnsZonesLinkSuffix}' } ],
  _byoZoneAppConfig     ? [] : [ { dnsName: 'privatelink.azconfig.io',                 virtualNetworkLinkName: '${resourceNames.vnetName}-appcfg-link${_dnsZonesLinkSuffix}' } ],
  (deployContainerEnv && !_byoZoneContainerApps) ? [
    { dnsName: 'privatelink.${location}.azurecontainerapps.io', virtualNetworkLinkName: '${resourceNames.vnetName}-containerapps-link${_dnsZonesLinkSuffix}' }
  ] : [],
  (deployContainerRegistry && !_byoZoneAcr) ? [
    { dnsName: 'privatelink.${acrDnsSuffix}',                         virtualNetworkLinkName: '${resourceNames.vnetName}-containerregistry-link${_dnsZonesLinkSuffix}' }
  ] : [],
  _deployAmpls ? concat(
    _byoZoneAppInsights     ? [] : [ { dnsName: 'privatelink.applicationinsights.io',      virtualNetworkLinkName: '${resourceNames.vnetName}-appi-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneAzureMonitor    ? [] : [ { dnsName: 'privatelink.monitor.azure.com',           virtualNetworkLinkName: '${resourceNames.vnetName}-azure-monitor-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneOmsOpInsights   ? [] : [ { dnsName: 'privatelink.oms.opinsights.azure.com',    virtualNetworkLinkName: '${resourceNames.vnetName}-oms-opinsights-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneOdsOpInsights   ? [] : [ { dnsName: 'privatelink.ods.opinsights.azure.com',    virtualNetworkLinkName: '${resourceNames.vnetName}-ods-opinsights-link${_dnsZonesLinkSuffix}' } ],
    _byoZoneAzureAutomation ? [] : [ { dnsName: 'privatelink.agentsvc.azure.automation.net', virtualNetworkLinkName: '${resourceNames.vnetName}-azure-automation-link${_dnsZonesLinkSuffix}' } ]
  ) : []
) : []

module privateDnsZones 'modules/networking/private-dns-zones.bicep' = if (_deployPrivateDnsZones && !empty(_dnsZonesList)) {
  name: 'dep-private-dns-zones'
  params: {
    zones: _dnsZonesList
    tags: _tags
    resourceGroupName: _dnsZonesTargetRg
    virtualNetworkResourceId: virtualNetworkResourceId
  }
  dependsOn: [
    virtualNetwork!
    virtualNetworkSubnets!
  ]
}

// Private Endpoints (consolidated into a single for-loop module with @batchSize(1) to keep compiled ARM template under 4 MB while preserving serialized PE creation).
///////////////////////////////////////////////////////////////////////////

var _peDnsZoneGroups = {
  blob: policyManagedPrivateDns ? null : {
    name: 'blobDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'blobARecord', privateDnsZoneResourceId: _dnsZoneBlobId }
    ]
  }
  cosmos: policyManagedPrivateDns ? null : {
    name: 'cosmosDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'cosmosARecord', privateDnsZoneResourceId: _dnsZoneCosmosId }
    ]
  }
  search: policyManagedPrivateDns ? null : {
    name: 'searchDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'searchARecord', privateDnsZoneResourceId: _dnsZoneSearchId }
    ]
  }
  keyVault: policyManagedPrivateDns ? null : {
    name: 'kvDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'kvARecord', privateDnsZoneResourceId: _dnsZoneKeyVaultId }
    ]
  }
  appConfig: policyManagedPrivateDns ? null : {
    name: 'appConfigDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'appConfigARecord', privateDnsZoneResourceId: _dnsZoneAppConfigId }
    ]
  }
  containerApps: policyManagedPrivateDns ? null : {
    name: 'ccaDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'ccaARecord', privateDnsZoneResourceId: _dnsZoneContainerAppsId }
    ]
  }
  acr: policyManagedPrivateDns ? null : {
    name: 'acrDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'acr', privateDnsZoneResourceId: _dnsZoneAcrId }
    ]
  }
  cognitiveServices: policyManagedPrivateDns ? null : {
    name: 'cogSvcsDnsZoneGroup'
    privateDnsZoneGroupConfigs: [
      { name: 'cogSvcsARecord', privateDnsZoneResourceId: _dnsZoneCogSvcsId }
    ]
  }
}

var _peList = concat(
  (_networkIsolation && deployStorageAccount) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.storageAccountName}'
      privateLinkServiceConnections: [
        {
          name: 'blobConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: storageAccount.outputs.resourceId, groupIds: ['blob'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?blob
    }
  ] : [],
  (_networkIsolation && deployCosmosDb) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.dbAccountName}'
      privateLinkServiceConnections: [
        {
          name: 'cosmosConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: cosmosDBAccount.outputs.resourceId, groupIds: ['Sql'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?cosmos
    }
  ] : [],
  (_networkIsolation && deploySearchService) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.searchServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'searchConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: searchService.outputs.resourceId, groupIds: ['searchService'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?search
    }
  ] : [],
  (_networkIsolation && _deployAiFoundrySearch) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.aiFoundrySearchServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'searchAIFConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: searchServiceAIFoundry.outputs.resourceId, groupIds: ['searchService'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?search
    }
  ] : [],
  (_networkIsolation && deployKeyVault) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.keyVaultName}'
      privateLinkServiceConnections: [
        {
          name: 'kvConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: keyVault.id, groupIds: ['vault'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?keyVault
    }
  ] : [],
  (_networkIsolation && deployAppConfig) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.appConfigName}'
      privateLinkServiceConnections: [
        {
          name: 'appConfigConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: appConfig.id, groupIds: ['configurationStores'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?appConfig
    }
  ] : [],
  (_networkIsolation && deployContainerEnv) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.containerEnvName}'
      privateLinkServiceConnections: [
        {
          name: 'ccaConnection'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: containerEnv.id, groupIds: ['managedEnvironments'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?containerApps
    }
  ] : [],
  (_networkIsolation && deployContainerRegistry) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.containerRegistryName}'
      privateLinkServiceConnections: [
        {
          name: '${resourceNames.containerRegistryName}-registry-connection'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: containerRegistry.id, groupIds: ['registry'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?acr
    }
  ] : [],
  (_networkIsolation && deploySpeechService) ? [
    {
      name: '${const.abbrs.networking.privateEndpoint}${resourceNames.speechServiceName}'
      privateLinkServiceConnections: [
        {
          name: 'speechConnection${useExistingVNet?'-byon':''}'
          #disable-next-line BCP318
          properties: { privateLinkServiceId: speechService.outputs.resourceId, groupIds: ['account'] }
        }
      ]
      privateDnsZoneGroup: _peDnsZoneGroups.?cognitiveServices
    }
  ] : []
)

module privateEndpoints 'modules/networking/private-endpoints.bicep' = if (_networkIsolation) {
  name: 'dep-private-endpoints'
  params: {
    endpoints: _peList
    location: _peLocation
    resourceGroupName: _peResourceGroupName
    tags: _tags
    subnetResourceId: _peSubnetId
  }
  dependsOn: [
    privateDnsZones
    storageAccount!
    cosmosDBAccount!
    searchService!
    #disable-next-line BCP321
    _deployAiFoundrySearch ? searchServiceAIFoundry : null
    keyVault!
    appConfig!
    containerEnv!
    containerRegistry!
    speechService!
  ]
}


// Azure Application Gateway
//////////////////////////////////////////////////////////////////////////
// Coming Soon

// Azure Firewall
//////////////////////////////////////////////////////////////////////////
// Coming Soon

// AI Foundry Standard Setup
//////////////////////////////////////////////////////////////////////////


var _dnsZonesSubscriptionId = useExistingVNet && !sideBySideDeploy ? varExistingVnetSubscriptionId : subscription().subscriptionId
var _dnsZonesResourceGroupName = useExistingVNet && !sideBySideDeploy ? varExistingVnetResourceGroupName : resourceGroup().name
var _dnsZoneCogSvcsId         = !empty(existingPrivateDnsZoneCogSvcsResourceId ?? '')         ? existingPrivateDnsZoneCogSvcsResourceId!         : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.cognitiveservices.azure.com')
var _dnsZoneOpenAiId          = !empty(existingPrivateDnsZoneOpenAiResourceId ?? '')          ? existingPrivateDnsZoneOpenAiResourceId!          : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.openai.azure.com')
var _dnsZoneAiServicesId      = !empty(existingPrivateDnsZoneAiServicesResourceId ?? '')      ? existingPrivateDnsZoneAiServicesResourceId!      : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.services.ai.azure.com')
var _dnsZoneSearchId          = !empty(existingPrivateDnsZoneSearchResourceId ?? '')          ? existingPrivateDnsZoneSearchResourceId!          : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.search.windows.net')
var _dnsZoneCosmosId          = !empty(existingPrivateDnsZoneCosmosResourceId ?? '')          ? existingPrivateDnsZoneCosmosResourceId!          : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.documents.azure.com')
var _dnsZoneBlobId            = !empty(existingPrivateDnsZoneBlobResourceId ?? '')            ? existingPrivateDnsZoneBlobResourceId!            : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/privateDnsZones', 'privatelink.blob.${environment().suffixes.storage}')
var _dnsZoneKeyVaultId        = !empty(existingPrivateDnsZoneKeyVaultResourceId ?? '')        ? existingPrivateDnsZoneKeyVaultResourceId!        : resourceId(_dnsZonesSubscriptionId, _dnsZonesResourceGroupName, 'Microsoft.Network/pr