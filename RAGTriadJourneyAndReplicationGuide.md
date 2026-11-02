DSC RAG Triad journey and replication guide
Microsoft GroundednessEvaluator RelevanceEvaluator and RetrievalEvaluator
Wella DSC Knowledge Agent  |  Prepared 27 October 2026
This guide explains how we added Microsoft model based evaluation to the deployed DSC chatbot, first for groundedness and then for relevance and retrieval quality. It is written for a teammate who needs to understand the journey and reproduce the changes in a Windows Test VM.
The final implementation evaluates the actual question, answer and retrieved evidence, sends structured evaluation results through the orchestrator stream, and displays independent blue scorecards in Chainlit. Each metric can be enabled separately through Azure App Configuration.
Replication starts from the reviewed deployed application baseline. The infrastructure release was agent landing zone v4.1.2; that release number does not identify every application repository commit. Capture the application remotes and commits before applying the baseline checked installers. Stop on a baseline mismatch and adapt the changes to the actual checkout.
How to use this guide
Read sections 1 to 5 for the deployment context and the original groundedness implementation. Follow sections 6 to 10 for the exact triad installation and validation sequence. Sections 11 to 14 explain controls, diagnostics and handover. Appendices A to C reproduce the complete triad paste scripts. Appendix D describes the supplied replication kit.
Command convention: paste each displayed PowerShell block as a whole. Run the next block only after the previous block returns successfully. Commands are intended for PowerShell inside the DSC Test VM unless another location is explicitly named. Do not paste Markdown code fence characters into PowerShell.
1 The implementation journey
Stage	What happened	Result
6 to 7 October	The previous deployment was removed and the agent landing zone infrastructure was provisioned in East US.	Private application environment and Test VM became available.
Initial application deployment	Post provisioning and application deployment were completed through several network and remote build fixes.	The chatbot and SharePoint ingestion became usable.
20 October	Groundedness SDK evaluation and a Chainlit scorecard were added.	An additional model evaluation checked the answer against retrieved evidence.
20 October fixes	The reasoning model setting and container image activation were corrected.	The blue groundedness card displayed a real score and explanation.
26 October	Relevance and retrieval evaluation were added, with independent flags and a master switch.	Screenshots showed all three metrics with separate scores and reasons.

The final three 5 out of 5 cards demonstrate that the live path returned scores for that question. They do not establish that every answer is correct, that every document was searched, or that the application has passed an independent evaluation suite.
Later work on citation downloads and broader retrieval is separate. Those changes were prepared after the triad and are not prerequisites for adding the three evaluators.
2 Repositories folders and Azure resources
The infrastructure repository was Azure/agent-landing-zone. The reference documentation was Azure AI Landing Zones. We used release v4.1.2 rather than treating the moving main branch as the historical baseline.
Infrastructure repository: https://github.com/Azure/agent-landing-zone
Documentation: https://azure.github.io/AI-Landing-Zones/
VM location	Responsibility
C:\github\agent-landing-zone-v4.1.2	Infrastructure checkout observed in the deployment session.
C:\github\ai-lz	Another infrastructure checkout seen in the VM. Do not assume both folders share the same azd environment.
C:\github\gpt-rag-ui	Chainlit frontend and evaluator scorecards.
C:\github\gpt-rag-orchestrator	Answer generation, retrieval context and evaluator calls.
C:\github\gpt-rag-ingestion	SharePoint document ingestion. It does not calculate the triad scores.

Several application folders were already present in the VM. We did not need a new clone of every component for each change. Before cloning or deploying, inspect the existing folder and its remote. Do not substitute a guessed upstream application URL for the actual customer checkout.
$repos = @(
    'C:\github\gpt-rag-ui',
    'C:\github\gpt-rag-orchestrator',
    'C:\github\gpt-rag-ingestion'
)
foreach ($repo in $repos) {
    Write-Host "Repository: $repo"
    git -C $repo remote -v
    git -C $repo rev-parse HEAD
    git -C $repo branch --show-current
    git -C $repo status --short
}

Save this output with the handover. The application repository versions are not inferred from the folder names or the infrastructure tag.
Setting	DSC value
Subscription	4a6faece-bff1-46d4-b992-04e3746bbaf4
Resource group	rg-wl-sandbox-ai-dscknowledgeagent
Region	eastus
App Configuration	https://appcs-a4psan-welladsc01-eus-001.azconfig.io
App Configuration label	agent-lz
Frontend Container App	ca-a4psanxnjczhu-frontend
Orchestrator Container App	ca-a4psanxnjczhu-orchestrator
Ingestion Container App	ca-a4psanxnjczhu-dataingest
Container registry	cra4psanwelladsc01eus001
ACR task pool	build-pool

These values target the existing DSC environment. A friend deploying to a different project must replace every environment value consistently. Do not use the DSC subscription or App Configuration endpoint for another project.
3 Azure login and the original deployment context
3 1 Login and verify the subscription
az login --use-device-code
az account set --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4'
az account show --query '{Subscription:name,Id:id,Tenant:tenantId}' --output table
azd version
git --version
az version

Complete the device login in a permitted browser. In the original session the sign in link could be opened outside the VM when its browser could not reach the sign in page. That did not give the external browser private access to the chatbot.
3 2 Historical infrastructure checkout
For an empty workspace, the equivalent version controlled checkout is below. Do not re-clone over the existing VM folders. The tag check deliberately stops if that historical tag is unavailable.
Set-Location C:\github
git clone https://github.com/Azure/agent-landing-zone.git agent-landing-zone-v4.1.2
if ($LASTEXITCODE -ne 0) { throw 'Clone failed.' }
Set-Location C:\github\agent-landing-zone-v4.1.2
git fetch --tags
git rev-parse --verify 'refs/tags/v4.1.2'
if ($LASTEXITCODE -ne 0) { throw 'Historical tag v4.1.2 is unavailable.' }
git checkout v4.1.2
git log -1 --format='%h %s'
Test-Path .\azure.yaml
azd env list

3 3 Provisioning and application deployment are different
The original infrastructure lifecycle used azd provision, post provisioning hooks or scripts, and then application deployment. Provision creates or updates Azure resources. Deploy builds and publishes application code. A running VM does not mean the application code is deployed, and an application build failure does not mean the VM needs rebuilding.
For the existing infrastructure environment, these are the context commands. Use the folder that actually contains that azd environment; selecting the environment in a different clone does not automatically import the original local environment state.
Set-Location C:\github\agent-landing-zone-v4.1.2
azd auth login --use-device-code
azd env list
azd env select welladsc01
azd env get-values

The last command can display environment settings. Review locally and redact secrets before sharing its output. It is not needed during routine triad deployment.
The historical provision and deploy commands were:
azd provision
# Wait for provisioning and its hooks to finish.
# Deploy from the intended configured checkout, not a second concurrent clone.
azd deploy

For a new infrastructure environment, select East US and the release supported network isolation settings before provisioning. The login and provision commands above are not a complete substitute for the release parameter configuration. Keep the pinned release deployment documentation with the deployment record.
A post provision script was run during troubleshooting both outside and inside the VM. That repetition is a description of the journey, not an instruction to rerun provisioning whenever an application changes. Inspect azure.yaml hooks first; do not run the same post provision work twice if the hook already completed successfully.
Get-Content .\azure.yaml
Get-ChildItem .\scripts -File | Where-Object Name -Match 'post.*provision'
# When this exact script exists and the release workflow requires a manual run:
# .\scripts\postProvision.ps1

The final triad changes use each application repository scripts/deploy.ps1 directly. They do not need azd down, azd provision, a VM rebuild, an ingestion rerun or a repeat of successful post provisioning. The earlier resource deletion is not repeated in this guide because it is not a triad installation step.
4 What each evaluator measures
Metric	Inputs we send	Question answered
Groundedness	User question, generated answer and actual retrieved context.	Are the answer claims supported by this evidence?
Answer relevance	User question and generated answer.	Does this answer address what the user asked?
Retrieval quality	User question and actual retrieved context.	How useful is the retrieved evidence for this question?

All three use Microsoft azure-ai-evaluation. The orchestrator makes an additional judge model evaluation for each enabled metric after answer generation. The metrics are separate assessments, even if the same Azure model deployment is used for generation and judging. They are not independent human review.
Each metric reports a score from 1 to 5 and an explanation. The UI displays score divided by 5 as a normalized percentage. For example, 5 out of 5 becomes 100 percent on the bar; it is not a 100 percent probability of correctness. The implementation does not average the three metrics into a composite score.
The retrieval evaluator judges the supplied evidence. It does not itself retrieve more documents, change chunking, rerank the index or search the entire SharePoint site. Retrieval improvements are a separate change.
5 The first groundedness implementation
5 1 Install the SDK in the orchestrator image
We pinned the SDK in the orchestrator requirements file. The image Dockerfile installs requirements during the build. Installing the SDK only in the VM Python environment would not install it in the running Container App.
Set-Location C:\github\gpt-rag-orchestrator
Select-String -Path .\requirements.txt -Pattern '^azure-ai-evaluation'
Get-Content .\Dockerfile

The required requirements entry was:
azure-ai-evaluation==1.18.1

If reproducing on a baseline without that entry, use this idempotent edit. If another version is already declared, reconcile the version deliberately rather than adding a second declaration.
$path = 'C:\github\gpt-rag-orchestrator\requirements.txt'
$text = [IO.File]::ReadAllText($path)
if ($text -notmatch '(?m)^azure-ai-evaluation\s*[=<>!~]') {
    Add-Content -LiteralPath $path -Value "`nazure-ai-evaluation==1.18.1"
}
Select-String -Path $path -Pattern '^azure-ai-evaluation' 

5 2 Capture the evidence actually used for this answer
We added src/strategies/groundedness_evaluator.py. A ContextVar keeps a separate evidence list for each request. The strategy opens capture_grounding_context around answer generation. SearchContextProvider records the formatted context it actually supplied to the model by calling record_grounding_context. This prevents one user turn from being judged against another turn or an invented reference answer.
The existing DSC search provider supplied in the session already contained these hooks:
from .groundedness_evaluator import record_grounding_context
 
context_text = build_context_text(parts)
record_grounding_context(context_text)
return Context(messages=[ChatMessage(role=Role.SYSTEM, text=context_text)])

The current triad strategy retains this same evidence capture and calls the coordinator after collecting the full answer. When adapting a different release, preserve its retrieval security, conversation filters and streaming lifecycle; add the capture calls at the equivalent boundaries rather than replacing an unrelated strategy wholesale.
5 3 Evaluate and send structured metadata
Groundedness evaluation runs outside the answer generation event loop using bounded workers. Valid finite scores from 1 to 5 are accepted. Missing evidence, invalid output, configuration errors and timeouts produce Unavailable rather than a fake zero or a fabricated score.
Evaluation results are serialized as JSON, encoded as URL safe base64 and framed by these markers in the orchestrator stream:
<<<GROUNDEDNESS_JSON>>>
BASE64_ENCODED_EVALUATION_JSON
<<<END_GROUNDEDNESS_JSON>>>

These markers remain named GROUNDEDNESS for backward compatibility after adding the triad. They are transport metadata, not answer text, not an encryption mechanism and not a replacement for authentication.
5 4 Decode the stream and render the card
The UI client decodes the marker payload through GroundednessStreamDecoder. Its on_groundedness callback collects the result. The chat service creates a Chainlit CustomElement named GroundednessCard, and public/elements/GroundednessCard.jsx renders the score and reason. The decoder must tolerate markers split across arbitrary network chunks; simply splitting each incoming chunk on a marker is insufficient.
groundedness_results = []
generator = call_orchestrator_stream(
    conversation_id,
    question,
    auth_info,
    question_id=message.id,
    on_groundedness=groundedness_results.append,
)
# The existing chat streaming loop consumes generator.
# After the response is complete:
if groundedness_results:
    card = cl.CustomElement(
        name="GroundednessCard",
        props=groundedness_results[-1],
        display="inline",
    )

This excerpt explains the callback contract. Use the complete reviewed chat/client files in the kit to inspect the actual placement; do not paste the excerpt as a replacement for the full streaming loop.
5 5 The reasoning model error and its fix
The first live evaluation failed with HTTP 400: max_tokens is not supported with this model; use max_completion_tokens instead. The answer generation call worked, but the evaluator was using a model parameter configuration incompatible with the deployed judge.
We set GROUNDEDNESS_IS_REASONING_MODEL=true for the current judge, passed it to the Microsoft SDK as is_reasoning_model, and restarted the orchestrator to reload cached configuration. This corrected the evaluator call. It was not a reason to upgrade azd or re-provision Azure resources.
az appconfig kv set --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --endpoint 'https://appcs-a4psan-welladsc01-eus-001.azconfig.io' --auth-mode login --label agent-lz --key GROUNDEDNESS_IS_REASONING_MODEL --value true --yes --output none

Keep true for the judge used in this deployment. A different judge must use a setting appropriate to that model; this is not a universal switch to turn on for every Azure model.
5 6 Blue card styling
The triad card reuses the existing wella groundedness CSS classes. On the working DSC frontend, the polished blue styling was already present. The block below is a reproducible blue style equivalent for a baseline that still has the earlier plain card; it is not a claim that every historical styling command was retained verbatim.
Set-Location C:\github\gpt-rag-ui
$cssPath = '.\public\custom.css'
$marker = '/* DSC RAG Triad blue cards */'
$css = @'
/* DSC RAG Triad blue cards */
.wella-groundedness {
  margin: 1rem 0; padding: 1rem 1.15rem;
  border: 1px solid #bfdbfe; border-left: 4px solid #2563eb;
  border-radius: 14px; background: #f5faff; color: #172554;
  max-width: 48rem; line-height: 1.55;
}
.wella-groundedness-heading {
  display: flex; justify-content: space-between; gap: 1rem;
  align-items: center; color: #1d4ed8;
}
.wella-groundedness-heading span {
  background: #dbeafe; padding: .2rem .65rem;
  border-radius: 999px; font-weight: 700;
}
.wella-groundedness-provider { font-size: .85rem; color: #475569; }
.wella-groundedness summary { color: #1d4ed8; cursor: pointer; }
.wella-groundedness progress {
  width: 100%; height: .55rem; accent-color: #2563eb;
}
.wella-groundedness progress::-webkit-progress-value { background: #2563eb; }
.wella-groundedness progress::-moz-progress-bar { background: #2563eb; }
'@
if (-not (Test-Path -LiteralPath $cssPath)) {
    New-Item -ItemType File -Path $cssPath -Force | Out-Null
}
$currentCss = [IO.File]::ReadAllText((Join-Path (Get-Location) $cssPath))
if (-not $currentCss.Contains($marker)) {
    Add-Content -LiteralPath $cssPath -Value ("`n" + $css)
}
Get-Content .\.chainlit\config.toml

Ensure the existing [UI] section in .chainlit/config.toml points custom_css to /public/custom.css. Keep all other configuration entries. Add that property only if it is absent; do not create a second [UI] section or replace the entire configuration. The changed CSS/configuration must be included in the UI image deployment.
[UI]
custom_css = "/public/custom.css"

6 Extending groundedness to the RAG triad
We kept the working groundedness path and generalized its wrapper to select GroundednessEvaluator, RelevanceEvaluator or RetrievalEvaluator from azure.ai.evaluation. We added rag_evaluators.py to coordinate the enabled metrics, then updated maf_lite_strategy.py to call it after each generated answer.
File	Change
Orchestrator src/strategies/groundedness_evaluator.py	Preserves evidence capture and encoding; supports all three Microsoft evaluator classes and validates their results.
Orchestrator src/strategies/rag_evaluators.py	New coordinator with master and per metric switches, judge configuration fallbacks and independent failure handling.
Orchestrator src/strategies/maf_lite_strategy.py	Uses the coordinator with the question, full answer and captured evidence, then emits structured metadata.
UI src/gpt_rag_ui/services/groundedness_stream.py	Decodes both the old groundedness payload and the new metrics array; rejects malformed data.
UI public/elements/GroundednessCard.jsx	Keeps the existing Chainlit element name and renders one blue card for each enabled metric.

Existing UI integration files services/chat.py and clients/orchestrator_client.py remained important: they already supplied the callback and custom element wiring from the first groundedness implementation. The triad installers do not recreate that wiring on a clean, unmodified frontend.
PowerShell did not replace Python or JSX. The installers contained the new source text, checked the current files, wrote the source changes and made backups. Deployment then built those changed files into container images. This is the same code change and deploy lifecycle, with automated editing instead of manual Visual Studio edits.
The old root payload remains groundedness only. A new metrics array contains the three named results. If groundedness is off, relevance is not mislabeled as groundedness. Each metric fails independently, so one unavailable score does not suppress the other enabled metrics.
7 Apply the three triad installers
Starting gate: the frontend already displays the groundedness card, the SDK is present in the orchestrator image, the reasoning flag is correct, and the supplied source matches the reviewed baseline. A newly cloned upstream release may differ; do not bypass a source hash check to make a patch apply.
Open each TXT installer on your local computer, select all its contents, copy, and paste the complete block into PowerShell inside the VM. No file transfer into the VM is necessary. Run them separately in this order:
Order	Installer	What it changes
1	01_UI_Evaluators_PASTE_IN_VM.txt	Stream decoder and triad card.
2	02_Backend_Evaluators_PASTE_IN_VM.txt	Generalized evaluator wrapper and coordinator.
3	03_Strategy_Evaluators_PASTE_IN_VM.txt	MafLiteStrategy integration.

The complete contents are in appendices A, B and C and in the replication ZIP. Each installer checks normalized source hashes and stops before writing if a target differs. It backs up existing targets under C:\github\DSC-triad-backup-<id>. Keep the reported backup path.
Do not deploy after a red error. A mismatch requires comparing the actual current file with the reviewed change. It is not an instruction to delete a guard, overwrite an unrelated branch or restore an older release blindly.
Set-Location C:\github\gpt-rag-ui
git diff -- src/gpt_rag_ui/services/groundedness_stream.py public/elements/GroundednessCard.jsx
Set-Location C:\github\gpt-rag-orchestrator
git diff -- src/strategies/groundedness_evaluator.py src/strategies/maf_lite_strategy.py
git status --short

A new untracked rag_evaluators.py appears in git status but not in an ordinary git diff until staged. It must still exist in the build context. Do not commit or publish customer code to a public repository as part of this installation.
8 Deploy the UI and then the orchestrator
8 1 Set the private remote build environment
The build runs on the existing ACR task pool inside the configured network. Local Docker is not required for this build mode. The VM needs permitted outbound access to Azure control endpoints and the private resources it uses. ACR workers also need their own access to dependency feeds; the VM opening a website does not prove the build pool can reach it.
Deploy the UI first because its decoder/card supports both the previous groundedness payload and the triad payload. Keep relevance and retrieval disabled until both deployments are ready.
$ErrorActionPreference = 'Stop'
$env:APP_CONFIG_ENDPOINT = 'https://appcs-a4psan-welladsc01-eus-001.azconfig.io'
$env:NETWORK_ISOLATION = 'true'
$env:BUILD_MODE = 'acr-task'
$env:ACR_TASK_AGENT_POOL = 'build-pool'
Set-Location C:\github\gpt-rag-ui
$env:tag = 'dsc-triad-ui-' + (Get-Date -Format 'yyyyMMddHHmmss')
.\scripts\deploy.ps1

Wait for successful completion, then paste this separate block in the same PowerShell session:
Set-Location C:\github\gpt-rag-orchestrator
$env:tag = 'dsc-triad-orch-' + (Get-Date -Format 'yyyyMMddHHmmss')
.\scripts\deploy.ps1

If using a new PowerShell window, repeat the four environment variable assignments before the orchestrator command. Shell environment variables are not automatically copied to another window.
8 2 Why unique tags were essential
A previous build reused the existing git commit tag even though local source files had changed. The Container App image reference stayed the same, so a successful build did not reliably activate the new application code. We fixed this with a new image reference; the repeatable deployment blocks above use timestamp tags to avoid that ambiguity.
Check that the deployment output prints the new dsc-triad tag. The reviewed frontend deploy script supports env:tag. The complete current orchestrator deploy script was not captured in the triad source export, so its printed tag must be checked. If it ignores the override, do not assume the build deployed new code; use the exact image digest that was built or adapt its tag override.
az containerapp list --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --resource-group 'rg-wl-sandbox-ai-dscknowledgeagent' --query "[?name=='ca-a4psanxnjczhu-frontend' || name=='ca-a4psanxnjczhu-orchestrator'].{App:name,Latest:properties.latestRevisionName,Ready:properties.latestReadyRevisionName}" --output table
az containerapp show --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --resource-group 'rg-wl-sandbox-ai-dscknowledgeagent' --name ca-a4psanxnjczhu-orchestrator --query '{Images:properties.template.containers[].image,Mode:properties.configuration.activeRevisionsMode,Traffic:properties.configuration.ingress.traffic}' --output json

Latest and Ready should match. In multiple revision mode, confirm the URL sends traffic to the intended new revision. A ready revision alone does not prove that the tested URL uses it.
8 3 Optional digest based activation
This is a recovery path, not an additional normal deployment. Use it only when the build completed but the intended image is not active. It reads the repository from the current app image and asks for the exact tag printed by the successful build; it does not guess a digest.
& {
    $ErrorActionPreference = 'Stop'
    $sub = '4a6faece-bff1-46d4-b992-04e3746bbaf4'
    $rg = 'rg-wl-sandbox-ai-dscknowledgeagent'
    $app = 'ca-a4psanxnjczhu-orchestrator'
    $registry = 'cra4psanwelladsc01eus001'
    $server = "$registry.azurecr.io"
    $builtTag = Read-Host 'Exact tag from the successful orchestrator build'
    $image = az containerapp show --subscription $sub --resource-group $rg --name $app --query 'properties.template.containers[0].image' --output tsv
    if ($LASTEXITCODE -ne 0 -or -not $image.StartsWith("$server/")) {
        throw 'Unexpected image registry. Stop and inspect the app.'
    }
    $repository = $image.Substring($server.Length + 1) -replace '@sha256:.*$','' -replace ':[^/]+$',''
    $digest = az acr repository show --subscription $sub --name $registry --image "${repository}:$builtTag" --query digest --output tsv
    if ($LASTEXITCODE -ne 0 -or $digest -notmatch '^sha256:[0-9a-f]{64}$') {
        throw 'The requested built image digest could not be verified.'
    }
    az containerapp update --subscription $sub --resource-group $rg --name $app --image "$server/$repository@$digest" --output none
    if ($LASTEXITCODE -ne 0) { throw 'Image update failed.' }
}

For the frontend, use its app name and its own successfully built UI tag. Do not activate an orchestrator image in the frontend or vice versa.
9 Enable and control the evaluators
Key	Purpose	DSC final value
EVALUATORS_ENABLED	Master switch. False skips all three.	true
ENABLE_GROUNDEDNESS_EVALUATION	Groundedness only.	true
ENABLE_RELEVANCE_EVALUATION	Answer relevance only.	true
ENABLE_RETRIEVAL_EVALUATION	Retrieved evidence quality only.	true
GROUNDEDNESS_IS_REASONING_MODEL	Existing judge compatibility setting inherited by the triad.	true for this judge

The master defaults to true for compatibility with the previous groundedness implementation. Each individual metric defaults to false if its key is absent. Disabled metrics make no SDK evaluation call and display no new scorecard. A failed enabled metric displays Unavailable; this is different from disabled.
After both deployments succeed, paste this entire block. It sets the intended flags and restarts the ready orchestrator revision so the cached App Configuration client reloads them.
$ErrorActionPreference = 'Stop'
$sub = '4a6faece-bff1-46d4-b992-04e3746bbaf4'
$rg = 'rg-wl-sandbox-ai-dscknowledgeagent'
$endpoint = 'https://appcs-a4psan-welladsc01-eus-001.azconfig.io'
$settings = [ordered]@{
    EVALUATORS_ENABLED = 'true'
    ENABLE_GROUNDEDNESS_EVALUATION = 'true'
    ENABLE_RELEVANCE_EVALUATION = 'true'
    ENABLE_RETRIEVAL_EVALUATION = 'true'
    GROUNDEDNESS_IS_REASONING_MODEL = 'true'
}
foreach ($entry in $settings.GetEnumerator()) {
    az appconfig kv set --subscription $sub --endpoint $endpoint --auth-mode login --label agent-lz --key $entry.Key --value $entry.Value --yes --only-show-errors --output none
    if ($LASTEXITCODE -ne 0) { throw "Could not save $($entry.Key)" }
}
$app = 'ca-a4psanxnjczhu-orchestrator'
$raw = az containerapp show --subscription $sub --resource-group $rg --name $app --output json
if ($LASTEXITCODE -ne 0) { throw 'Could not read orchestrator.' }
$state = $raw | ConvertFrom-Json
if (-not $state.properties.latestReadyRevisionName -or $state.properties.latestRevisionName -ne $state.properties.latestReadyRevisionName) {
    throw 'The newest orchestrator revision is not ready. Wait before restarting.'
}
$revision = $state.properties.latestReadyRevisionName
az containerapp revision restart --subscription $sub --resource-group $rg --name $app --revision $revision
if ($LASTEXITCODE -ne 0) { throw 'Restart failed.' }

A restart can interrupt active answers. Run it between test questions. Changing a flag does not need an image rebuild, but this implementation does require an orchestrator restart for reliable reload. It does not provide a browser settings switch or automatic hot refresh.
9 1 Optional shared judge settings
No new model deployment was required for the triad. By default we reused the working groundedness endpoint, judge deployment, credential and model type setting.
Optional override	Fallback
EVALUATOR_AZURE_ENDPOINT	GROUNDEDNESS_AZURE_ENDPOINT, then chat endpoint.
EVALUATOR_MODEL	GROUNDEDNESS_EVALUATOR_MODEL, then chat deployment.
EVALUATOR_IS_REASONING_MODEL	GROUNDEDNESS_IS_REASONING_MODEL, then false.
EVALUATOR_TIMEOUT_SECONDS	GROUNDEDNESS_TIMEOUT_SECONDS, then 30 per metric.
EVALUATOR_MAX_EVIDENCE_CHARS	GROUNDEDNESS_MAX_EVIDENCE_CHARS, then 24000.

These optional keys are supported by the coordinator; they are not required to reproduce the working deployment. Use the exact Azure deployment name for EVALUATOR_MODEL, not just a generic model family name. An existing EVALUATOR_IS_REASONING_MODEL value overrides the older GROUNDEDNESS setting.
10 Validate the deployment in the private UI
Open the frontend inside the Test VM, hard refresh with Ctrl F5, and start a new conversation. Do not expect a newly deployed evaluator to rewrite old answers or attach cards to previously saved messages.
Frontend: https://ca-a4psanxnjczhu-frontend.ashystone-1faa997f.eastus.azurecontainerapps.io
Use a substantive question that produces retrieved evidence, for example:
In wet DSC/HPDSC of human hair, what transition is commonly assigned to the main endothermic peak, and which hair components are represented in the two phase interpretation?
Expected result: the answer is followed by Groundedness, Answer relevance and Retrieval quality cards. Each has its own score out of 5, explanation and normalized progress bar. All three may score 5 for one example; scores need not differ.
The live screenshots showed all three cards with 5.0 out of 5 and question specific explanations. That confirms the visible triad path for this example. It does not validate every case or prove the judge is unbiased.
10 1 Check the backend logs
az containerapp logs show --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --resource-group 'rg-wl-sandbox-ai-dscknowledgeagent' --name ca-a4psanxnjczhu-orchestrator --type console --tail 100

Portal alternative: Container App > Log stream > Console. The frontend 200 OK request logs alone cannot diagnose evaluator failures; inspect orchestrator logs for the evaluation warning, metric name and exception type. Redact tokens and confidential answer/context text before sharing logs.
10 2 Test the switches
Change the settings hashtable in section 9, run its entire block including the restart, and ask a new question after the revision is ready. Restore all three metrics after testing.
Master	Groundedness	Relevance	Retrieval	Expected new cards
false	true	true	true	None
true	true	false	false	Groundedness
true	false	true	false	Answer relevance
true	false	false	true	Retrieval quality
true	true	true	true	All three

For a greeting without evidence, groundedness or retrieval may be Unavailable instead of receiving a score. Use substantive evidence backed questions for the initial acceptance test.
10 3 Demonstrate that the scores are calculated
For controlled validation, call the evaluators with fixed question/answer/context inputs. Add an unsupported contradictory claim to test groundedness, give an off topic answer to test relevance, and supply unrelated evidence to test retrieval. Compare the returned raw score and reason with the rendered card. These are deliberate validation tests, not changes to customer answers.
Preserve the inputs, judge deployment, SDK version, enabled flags and raw result for repeatability. The evaluator is model based and can be generous or variable. Never lower or vary scores artificially to make the display appear realistic.
The Sheet1 citation resolved to Golden Data Set Template_completed_DSC_QA 2_FINAL.xlsx. That workbook contains sample questions and expected answers. An answer can legitimately be grounded in it while failing to demonstrate retrieval from original research documents. Keep evaluation examples separate from production knowledge when conducting independent validation. Excluding the workbook was part of later retrieval work, not the original triad patch.
11 Issues we encountered and what fixed them
11 1 Build failed before evaluator code ran
ACR build failures included npm ECONNRESET to a package feed, npm install not finishing, and tsc not found after dependencies failed to install. These are build dependency or network problems, not evidence that the evaluator SDK cannot work. The exact successful package feed edits were not retained as a complete reproducible patch; do not substitute an invented lockfile rewrite. Inspect the failing remote build log and the repository lockfile before changing a feed.
az acr task list-runs --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --registry cra4psanwelladsc01eus001 --output table
$runId = Read-Host 'Failed ACR run ID from the build output'
az acr task show-run --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --registry cra4psanwelladsc01eus001 --run-id $runId --output json
az acr task logs --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --registry cra4psanwelladsc01eus001 --run-id $runId

11 2 Registry denied a public worker
A build failed with a public worker IP denied by the private registry. The intended private build pool was missing from that shell. Explicit BUILD_MODE=acr-task and ACR_TASK_AGENT_POOL=build-pool corrected which worker environment the script requested. Opening the registry to the Internet was not necessary for this workflow.
az acr agentpool show --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --registry cra4psanwelladsc01eus001 --name build-pool --output json
az acr agentpool show --subscription '4a6faece-bff1-46d4-b992-04e3746bbaf4' --registry cra4psanwelladsc01eus001 --name build-pool --queue-count

11 3 Build queued for a long time
The pool had one worker and queued builds were observed. ProvisioningState Succeeded on the pool means the pool resource exists; it does not mean a queued build has started or an image is deployed. Avoid running duplicate deployments in multiple windows. Inspect the actual run status and logs; wait when a preceding run is using the worker.
11 4 Cards absent after a successful build
We checked whether the actual frontend callback/CustomElement wiring existed, whether metadata was decoded, whether the correct flags were loaded, and whether the intended image revision was active. Reusing the same git hash image tag caused confusion. A new tag or verified digest, a ready revision and a browser hard refresh resolved the stale deployment issue.
11 5 Card displayed Unavailable
The confirmed model parameter error was max_tokens versus max_completion_tokens. GROUNDEDNESS_IS_REASONING_MODEL=true corrected the working judge configuration. Other causes remain possible: missing evidence, oversized evidence, wrong judge endpoint or deployment, identity permission errors, model quota or network failure. Read the metric specific orchestrator warning instead of assigning a guessed zero score.
11 6 More time per answer
The three evaluator calls run sequentially and each defaults to a 30 second application timeout. Three slow evaluations can therefore add roughly 90 seconds after answer generation, plus normal overhead. A timeout returns Unavailable but does not forcibly terminate a running SDK request. The two worker slots remain occupied until the underlying calls finish; SDK retries can add provider requests and cost.
The answer text streams before the final evaluation cards are ready. A missing card while evaluation is still running is different from a permanently missing callback or a disabled metric. The customer accepted a latency tradeoff, but measure response and card arrival time under realistic concurrency.
12 Local verification and live evidence
The triad package passed 14 local test methods using stub Microsoft evaluators. Checks covered all 16 master/metric switch combinations, exact evaluator input contracts, reasoning flag and credential propagation, independent failures, missing or oversized evidence, invalid scores and legacy result keys.
Additional checks covered per turn context isolation, timeout worker capacity, every stream split position, compatibility with the original groundedness payload, and rejection of malformed metadata. Modified Python passed syntax checks, and installer transformations were emulated against the reviewed files.
Those local tests did not exercise a real Azure model, the full installed SDK environment, PowerShell execution or browser rendering. The later screenshots provide live UI evidence for the three scores on one example. Keep both kinds of evidence distinct in the handover.
# Optional source syntax check inside the VM if Python is available.
Set-Location C:\github\gpt-rag-orchestrator
python -m py_compile .\src\strategies\groundedness_evaluator.py .\src\strategies\rag_evaluators.py .\src\strategies\maf_lite_strategy.py

A syntax check does not prove imports, authentication or model calls will succeed. The real acceptance test remains a new evidence backed question with the intended deployed revision and settings.
13 Rollback and handover
For a quick operational rollback, set EVALUATORS_ENABLED=false through the section 9 block and restart the ready orchestrator revision. The new answer should have no evaluator cards. This does not undo source edits or delete scores already displayed on prior messages.
For a code rollback, use each installer reported backup to restore the exact modified files, then build and deploy with another unique tag. Inspect the backup tree first: the triad scripts preserve repository relative paths under the backup folder. Do not restore a whole unrelated repository or delete new files until their ownership is confirmed.
Get-ChildItem C:\github -Directory -Filter 'DSC-triad-backup-*'
# Inspect the specific backup reported by the installer before restoring.
# Get-ChildItem 'C:\github\DSC-triad-backup-EXACT_ID' -Recurse -File

Handover record: application remotes and commits; uncommitted source diff; SDK pin; changed files; App Configuration labels and values; judge deployment and reasoning setting; build tags and digests; ready and traffic serving revisions; sample scores and explanations; latency; known limitations; backup paths. Store secrets in the existing secret management system, never in this document or a shared script.
Do not present the triad as a retrieval improvement. It measures supplied answers and evidence. Broader retrieval, citation downloading, chat history and Wella branding are separate work items with their own implementation and validation status.
14 References
Agent Landing Zone repository
https://github.com/Azure/agent-landing-zone
AI Landing Zones documentation
https://azure.github.io/AI-Landing-Zones/
Microsoft GroundednessEvaluator
https://learn.microsoft.com/en-us/python/api/azure-ai-evaluation/azure.ai.evaluation.groundednessevaluator?view=azure-python
Microsoft RelevanceEvaluator
https://learn.microsoft.com/en-us/python/api/azure-ai-evaluation/azure.ai.evaluation.relevanceevaluator?view=azure-python
Microsoft RetrievalEvaluator
https://learn.microsoft.com/en-us/python/api/azure-ai-evaluation/azure.ai.evaluation.retrievalevaluator?view=azure-python
The implementation retained azure-ai-evaluation 1.18.1. Current Microsoft reference pages explain the evaluators but do not imply that we upgraded the deployed SDK or application release.
Appendix A Complete UI triad installer
01_UI_Evaluators_PASTE_IN_VM.txt
Copy this complete script as one block into VM PowerShell. Use the TXT copy in the replication kit to preserve plain text. It requires the reviewed working groundedness baseline; stop if a guard reports a mismatch.
# Paste the ENTIRE text into PowerShell INSIDE the DSC VM.
$ErrorActionPreference = 'Stop'
$root = 'C:\github'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$pending = [ordered]@{}
function Read-ReviewedSource([string]$Relative,[string]$ExpectedHash) {
    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file missing: $path" }
    $text = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n").TrimEnd([char]10)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $actual = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($actual -ne $ExpectedHash) { throw "Current code differs from reviewed baseline: $path. Nothing saved by this script. Share the current file before proceeding." }
    return $text
}
function Replace-Once([string]$Text,[string]$Before,[string]$After) {
    $Before = $Before.Replace("`r`n", "`n")
    $After = $After.Replace("`r`n", "`n")
    $pos = $Text.IndexOf($Before,[StringComparison]::Ordinal)
    if ($pos -lt 0 -or $Text.IndexOf($Before,$pos+$Before.Length,[StringComparison]::Ordinal) -ge 0) { throw 'Patch anchor is missing or ambiguous. Nothing saved by this script.' }
    return $Text.Substring(0,$pos)+$After+$Text.Substring($pos+$Before.Length)
}
 
$text = Read-ReviewedSource 'gpt-rag-ui/src/gpt_rag_ui/services/groundedness_stream.py' '4c293317dbbc917435dc49339d5cfed5879cb00624443775b518e7dc6e8f168e'
$pending['gpt-rag-ui/src/gpt_rag_ui/services/groundedness_stream.py'] = @'
"""Bounded metadata decoder for arbitrary HTTP chunk boundaries."""
import base64
import json
import math
START = '<<<GROUNDEDNESS_JSON>>>'
END = '<<<END_GROUNDEDNESS_JSON>>>'
 
class GroundednessStreamDecoder:
    def __init__(self):
        self.buffer = ''
        self.inside = False
        self.overflow = False
        self.results = []
 
    def feed(self, chunk):
        self.buffer += chunk
        visible = []
        while self.buffer:
            marker = END if self.inside else START
            index = self.buffer.find(marker)
            if index >= 0:
                before = self.buffer[:index]
                self.buffer = self.buffer[index + len(marker):]
                if self.inside:
                    if not self.overflow:
                        self._decode(before)
                    self.inside = False
                    self.overflow = False
                else:
                    visible.append(before)
                    self.inside = True
                continue
            if self.inside:
                if len(self.buffer) > 65536:
                    self.overflow = True
                    self.buffer = self.buffer[-(len(END)-1):]
                break
            keep = 0
            for size in range(1, min(len(self.buffer), len(START)-1)+1):
                if self.buffer.endswith(START[:size]):
                    keep = size
            if keep:
                visible.append(self.buffer[:-keep])
                self.buffer = self.buffer[-keep:]
            else:
                visible.append(self.buffer)
                self.buffer = ''
            break
        return ''.join(visible)
 
    def _decode(self, encoded):
        try:
            if len(encoded) > 65536:
                return
            payload = json.loads(base64.b64decode(encoded, altchars=b'-_', validate=True))
            if not isinstance(payload, dict):
                return
            metrics = payload.get('metrics')
            if metrics is not None:
                if not isinstance(metrics, list) or len(metrics) > 3:
                    return
                valid = []
                seen = set()
                for metric in metrics:
                    normalized = self._normalize(metric)
                    if normalized is not None and normalized['metric'] not in seen:
                        seen.add(normalized['metric'])
                        valid.append(normalized)
                if valid:
                    self.results.append({'metrics': valid, 'schema_version': 2})
            else:
                legacy = dict(payload, metric='groundedness')
                normalized = self._normalize(legacy)
                if normalized is not None:
                    self.results.append(normalized)
        except (ValueError, TypeError, UnicodeError):
            pass
 
    @staticmethod
    def _normalize(payload):
        if not isinstance(payload, dict):
            return None
        metric = payload.get('metric')
        status = payload.get('status')
        if metric not in {'groundedness', 'relevance', 'retrieval'}:
            return None
        if status not in {'completed', 'unavailable'}:
            return None
        score = payload.get('microsoft_score')
        if status == 'completed':
            if isinstance(score, bool) or not isinstance(score, (int, float)):
                return None
            if not math.isfinite(score) or not 1 <= score <= 5:
                return None
        else:
            score = None
        return dict(metric=metric, status=status, microsoft_score=score,
            reason=str(payload.get('reason') or '')[:3000],
            microsoft_reason=str(payload.get('microsoft_reason') or '')[:3000])
 
    def take_results(self):
        results, self.results = self.results, []
        return results
 
    def finish(self):
        tail = '' if self.inside or START.startswith(self.buffer) else self.buffer
        self.buffer = ''
        return tail
'@
 
$text = Read-ReviewedSource 'gpt-rag-ui/public/elements/GroundednessCard.jsx' '8177d5c85d8056cdb7b2e32f62eeb9ebb95ef8228e111270f3cd4e9235a1620b'
$pending['gpt-rag-ui/public/elements/GroundednessCard.jsx'] = @'
import React from "react";
 
const labels = {
  groundedness: ["Groundedness", "Is the answer supported by the retrieved evidence?"],
  relevance: ["Answer relevance", "Does the answer address the question?"],
  retrieval: ["Retrieval quality", "How useful is the retrieved evidence for the question?"]
};
 
function MetricCard({ metric }) {
  const name = metric.metric || "groundedness";
  const label = labels[name];
  if (!label) return null;
  const score = metric.microsoft_score;
  const complete = metric.status === "completed" && typeof score === "number" &&
    Number.isFinite(score) && score >= 1 && score <= 5;
  const reason = String(metric.microsoft_reason || metric.reason || "");
  return (
    <section className="wella-groundedness" aria-label={label[0]}>
      <div className="wella-groundedness-heading">
        <strong>{label[0]}</strong>
        <span>{complete ? `${score.toFixed(1)}/5` : "Unavailable"}</span>
      </div>
      <p className="wella-groundedness-provider">Microsoft Azure AI Evaluation</p>
      <p>{label[1]}</p>
      {complete && <>
        <progress max="5" value={score} style={{accentColor: "#2563eb"}}
          aria-label={`${label[0]} ${score} out of 5`} />
        <p>{(score / 5 * 100).toFixed(0)}% normalized score · Not a probability of accuracy</p>
      </>}
      <details>
        <summary>{complete ? "Why this score?" : "Why unavailable?"}</summary>
        <p>{reason || "No evaluator explanation was returned."}</p>
      </details>
    </section>
  );
}
 
// Keep the deployed Chainlit element name and callback wiring.
export default function GroundednessCard() {
  const metrics = Array.isArray(props?.metrics) ? props.metrics :
    (props?.status ? [{...props, metric: "groundedness"}] : []);
  if (!metrics.length) return null;
  return (
    <div aria-label="Answer quality evaluations">
      {metrics.length > 1 && <p><strong>Answer quality</strong></p>}
      {metrics.map(metric => <MetricCard key={metric.metric || "groundedness"} metric={metric} />)}
    </div>
  );
}
'@
 
$backup = Join-Path $root ('DSC-triad-backup-' + [guid]::NewGuid().ToString('N'))
foreach ($relative in $pending.Keys) {
    $target = Join-Path $root $relative
    if (Test-Path -LiteralPath $target) {
        $saved = Join-Path $backup $relative
        New-Item -ItemType Directory -Path (Split-Path $saved) -Force | Out-Null
        Copy-Item -LiteralPath $target -Destination $saved
    }
}
foreach ($relative in $pending.Keys) {
    $target = Join-Path $root $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    [System.IO.File]::WriteAllText($target,$pending[$relative],$utf8)
}
Write-Host "Applied $($pending.Count) source changes. Backup: $backup" -ForegroundColor Green
Write-Host 'This script did not deploy or modify Azure resources.'
Appendix B Complete evaluator backend installer
02_Backend_Evaluators_PASTE_IN_VM.txt
Copy this complete script as one block into VM PowerShell. Use the TXT copy in the replication kit to preserve plain text. It requires the reviewed working groundedness baseline; stop if a guard reports a mismatch.
# Paste the ENTIRE text into PowerShell INSIDE the DSC VM.
$ErrorActionPreference = 'Stop'
$root = 'C:\github'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$pending = [ordered]@{}
function Read-ReviewedSource([string]$Relative,[string]$ExpectedHash) {
    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file missing: $path" }
    $text = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n").TrimEnd([char]10)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $actual = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($actual -ne $ExpectedHash) { throw "Current code differs from reviewed baseline: $path. Nothing saved by this script. Share the current file before proceeding." }
    return $text
}
function Replace-Once([string]$Text,[string]$Before,[string]$After) {
    $Before = $Before.Replace("`r`n", "`n")
    $After = $After.Replace("`r`n", "`n")
    $pos = $Text.IndexOf($Before,[StringComparison]::Ordinal)
    if ($pos -lt 0 -or $Text.IndexOf($Before,$pos+$Before.Length,[StringComparison]::Ordinal) -ge 0) { throw 'Patch anchor is missing or ambiguous. Nothing saved by this script.' }
    return $Text.Substring(0,$pos)+$After+$Text.Substring($pos+$Before.Length)
}
 
$text = Read-ReviewedSource 'gpt-rag-orchestrator/src/strategies/groundedness_evaluator.py' '2ad4f623748b949556c7bd5fe6a10e0cf892b5c8c88d53ec8039ca1f1bb02c70'
$pending['gpt-rag-orchestrator/src/strategies/groundedness_evaluator.py'] = @'
"""Microsoft RAG evaluators; evidence capture remains scoped to each turn."""
from __future__ import annotations
import asyncio
import base64
import json
import logging
import math
import threading
from contextlib import contextmanager
from contextvars import ContextVar
from typing import Any
 
_LOG = logging.getLogger(__name__)
_CONTEXT: ContextVar[list[str] | None] = ContextVar('grounding_context', default=None)
_SLOTS = threading.BoundedSemaphore(2)
_PENDING: set[asyncio.Task] = set()
START = '<<<GROUNDEDNESS_JSON>>>'
END = '<<<END_GROUNDEDNESS_JSON>>>'
 
@contextmanager
def capture_grounding_context():
    evidence: list[str] = []
    token = _CONTEXT.set(evidence)
    try:
        yield evidence
    finally:
        _CONTEXT.reset(token)
 
def record_grounding_context(context: str) -> None:
    evidence = _CONTEXT.get()
    if evidence is not None and context and context not in evidence:
        evidence.append(context)
 
def encode_groundedness(payload: dict[str, Any]) -> str:
    encoded = base64.urlsafe_b64encode(json.dumps(payload, ensure_ascii=False,
        allow_nan=False).encode('utf-8')).decode('ascii')
    return START + encoded + END
 
def unavailable(reason: str) -> dict[str, Any]:
    return dict(status='unavailable', groundedness_score=None, microsoft_score=None,
        display_score='Unavailable', reason=reason, microsoft_reason='',
        evaluator_provider='microsoft_azure_ai_evaluation', schema_version=1)
 
class GroundednessEvaluator:
    def __init__(self, *, endpoint: str, deployment: str, credential: Any,
                 api_version: str, reasoning_model: bool = False, metric: str = "groundedness",
                 timeout_seconds: float = 30, max_context_chars: int = 24000):
        if metric not in {"groundedness", "relevance", "retrieval"}:
            raise ValueError("Unknown evaluator metric")
        self.metric = metric
        self.endpoint = endpoint
        self.deployment = deployment
        self.credential = credential
        self.api_version = api_version
        self.reasoning_model = reasoning_model
        self.timeout = max(1, min(float(timeout_seconds), 120))
        self.max_context_chars = max(1000, int(max_context_chars))
 
    def _score(self, question: str, answer: str, context: str) -> dict:
        try:
            # Imports and initialization are also covered by the caller timeout.
            import azure.ai.evaluation as microsoft
            evaluator_class = getattr(microsoft, {
                "groundedness": "GroundednessEvaluator",
                "relevance": "RelevanceEvaluator",
                "retrieval": "RetrievalEvaluator",
            }[self.metric])
            evaluator = evaluator_class(model_config={
                'azure_endpoint': self.endpoint,
                'azure_deployment': self.deployment,
                'api_version': self.api_version,
            }, credential=self.credential, is_reasoning_model=self.reasoning_model)
            # Each evaluator gets only the inputs its Microsoft contract requires.
            inputs = {"query": question}
            if self.metric != "retrieval":
                inputs["response"] = answer
            if self.metric != "relevance":
                inputs["context"] = context
            result = evaluator(**inputs)
            raw = result.get(self.metric)
            if raw is None:
                raw = result.get("gpt_" + self.metric)
            if isinstance(raw, bool):
                raise ValueError('Invalid score type')
            score = float(raw)
            if not math.isfinite(score) or not 1 <= score <= 5:
                raise ValueError('Invalid Microsoft score')
            reason = str(result.get(self.metric + "_reason") or
                         result.get("gpt_" + self.metric + "_reason") or '').strip()
            reason = reason[:3000]
            _LOG.info("RAG evaluator completed: metric=%s score=%s", self.metric, score)
            return dict(status='completed', metric=self.metric, microsoft_score=score,
                groundedness_score=round(score / 5 * 100, 1),
                display_score=f'{score:g}/5', reason=reason, microsoft_reason=reason,
                evaluator_provider='microsoft_azure_ai_evaluation', schema_version=1,
                evaluator_deployment=self.deployment,
                methodology='Microsoft score 1 to 5; percentage is normalized, not accuracy.')
        finally:
            _SLOTS.release()
 
    async def evaluate(self, *, question: str, answer: str, contexts: list[str]) -> dict:
        context = '\n\n'.join(contexts).strip()
        if not question.strip():
            return unavailable('No question was supplied for this turn.')
        if self.metric != "retrieval" and not answer.strip():
            return unavailable('No generated answer was supplied for this turn.')
        if self.metric != "relevance" and not context:
            return unavailable('No retrieved evidence was supplied for this turn.')
        if not self.endpoint or not self.deployment:
            return unavailable('Evaluator endpoint or deployment is not configured.')
        # Never silently judge an arbitrary prefix while claiming full evidence coverage.
        if self.metric != "relevance" and len(context) > self.max_context_chars:
            return unavailable('Evidence exceeds the configured evaluation size limit.')
        # A timed-out SDK worker keeps its slot until it actually terminates.
        if not _SLOTS.acquire(blocking=False):
            return unavailable('Evaluator is busy. Please retry evaluation later.')
        try:
            task = asyncio.create_task(asyncio.to_thread(self._score, question, answer, context))
        except BaseException:
            _SLOTS.release()
            raise
        _PENDING.add(task)
        def consume(done):
            _PENDING.discard(done)
            if not done.cancelled():
                done.exception()
        task.add_done_callback(consume)
        try:
            return await asyncio.wait_for(asyncio.shield(task), timeout=self.timeout)
        except asyncio.TimeoutError:
            _LOG.warning('RAG evaluator timed out: metric=%s', self.metric)
            return unavailable('Evaluation timed out; the answer remains available.')
        except Exception as exc:
            # No tokens, source text, or raw provider errors are returned to the browser.
            _LOG.warning('RAG evaluator unavailable: metric=%s error_type=%s', self.metric, type(exc).__name__)
            return unavailable('Microsoft evaluation could not complete this check.')
'@
$pending['gpt-rag-orchestrator/src/strategies/rag_evaluators.py'] = @'
"""Independent Microsoft evaluators with a master switch and per-metric controls."""
from __future__ import annotations
import asyncio
import logging
from .groundedness_evaluator import GroundednessEvaluator, unavailable
 
_LOG = logging.getLogger(__name__)
METRICS = ("groundedness", "relevance", "retrieval")
 
async def evaluate_rag_triad(*, cfg, endpoint, deployment, credential,
                            api_version, question, answer, contexts):
    # cfg uses the application's existing App Configuration label/cache behavior.
    if not cfg.get("EVALUATORS_ENABLED", True, type=bool):
        _LOG.info("RAG evaluators disabled by master switch")
        return None
    enabled = [name for name in METRICS if cfg.get(
        "ENABLE_" + name.upper() + "_EVALUATION", False, type=bool)]
    if not enabled:
        _LOG.info("RAG evaluators disabled: no metrics selected")
        return None
    results = []
    for metric in enabled:
        try:
            judge = GroundednessEvaluator(
                metric=metric,
                endpoint=cfg.get("EVALUATOR_AZURE_ENDPOINT",
                    cfg.get("GROUNDEDNESS_AZURE_ENDPOINT", endpoint)),
                deployment=cfg.get("EVALUATOR_MODEL",
                    cfg.get("GROUNDEDNESS_EVALUATOR_MODEL", deployment)),
                credential=credential, api_version=api_version,
                reasoning_model=cfg.get("EVALUATOR_IS_REASONING_MODEL",
                    cfg.get("GROUNDEDNESS_IS_REASONING_MODEL", False, type=bool), type=bool),
                timeout_seconds=float(cfg.get("EVALUATOR_TIMEOUT_SECONDS",
                    cfg.get("GROUNDEDNESS_TIMEOUT_SECONDS", 30))),
                max_context_chars=int(cfg.get("EVALUATOR_MAX_EVIDENCE_CHARS",
                    cfg.get("GROUNDEDNESS_MAX_EVIDENCE_CHARS", 24000))),
            )
            result = await judge.evaluate(question=question, answer=answer, contexts=contexts)
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            _LOG.warning("RAG evaluator setup unavailable: metric=%s error_type=%s",
                         metric, type(exc).__name__)
            result = unavailable("Evaluation configuration could not be used.")
        # Sequential calls respect the existing two-worker capacity; failures do
        # not cancel the other metrics. Timeout applies independently per metric.
        results.append({"metric": metric, "status": result["status"],
            "microsoft_score": result.get("microsoft_score"),
            "reason": str(result.get("reason") or "")[:3000],
            "microsoft_reason": str(result.get("microsoft_reason") or "")[:3000]})
    # Compatibility root contains only groundedness, never another metric's score.
    ground = next((x for x in results if x["metric"] == "groundedness"), None)
    root = dict(ground) if ground else unavailable("Groundedness is disabled.")
    root.update(metrics=results, schema_version=2,
                evaluator_provider="microsoft_azure_ai_evaluation")
    return root
'@
 
$backup = Join-Path $root ('DSC-triad-backup-' + [guid]::NewGuid().ToString('N'))
foreach ($relative in $pending.Keys) {
    $target = Join-Path $root $relative
    if (Test-Path -LiteralPath $target) {
        $saved = Join-Path $backup $relative
        New-Item -ItemType Directory -Path (Split-Path $saved) -Force | Out-Null
        Copy-Item -LiteralPath $target -Destination $saved
    }
}
foreach ($relative in $pending.Keys) {
    $target = Join-Path $root $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    [System.IO.File]::WriteAllText($target,$pending[$relative],$utf8)
}
Write-Host "Applied $($pending.Count) source changes. Backup: $backup" -ForegroundColor Green
Write-Host 'This script did not deploy or modify Azure resources.'
Appendix C Complete strategy integration installer
03_Strategy_Evaluators_PASTE_IN_VM.txt
Copy this complete script as one block into VM PowerShell. Use the TXT copy in the replication kit to preserve plain text. It requires the reviewed working groundedness baseline; stop if a guard reports a mismatch.
# Paste the ENTIRE text into PowerShell INSIDE the DSC VM.
$ErrorActionPreference = 'Stop'
$root = 'C:\github'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$pending = [ordered]@{}
function Read-ReviewedSource([string]$Relative,[string]$ExpectedHash) {
    $path = Join-Path $root $Relative
    if (-not (Test-Path -LiteralPath $path)) { throw "Required file missing: $path" }
    $text = [System.IO.File]::ReadAllText($path).Replace("`r`n", "`n").TrimEnd([char]10)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $actual = ([BitConverter]::ToString($sha.ComputeHash($utf8.GetBytes($text)))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
    if ($actual -ne $ExpectedHash) { throw "Current code differs from reviewed baseline: $path. Nothing saved by this script. Share the current file before proceeding." }
    return $text
}
function Replace-Once([string]$Text,[string]$Before,[string]$After) {
    $Before = $Before.Replace("`r`n", "`n")
    $After = $After.Replace("`r`n", "`n")
    $pos = $Text.IndexOf($Before,[StringComparison]::Ordinal)
    if ($pos -lt 0 -or $Text.IndexOf($Before,$pos+$Before.Length,[StringComparison]::Ordinal) -ge 0) { throw 'Patch anchor is missing or ambiguous. Nothing saved by this script.' }
    return $Text.Substring(0,$pos)+$After+$Text.Substring($pos+$Before.Length)
}
 
$text = Read-ReviewedSource 'gpt-rag-orchestrator/src/strategies/maf_lite_strategy.py' 'b47812d901f0db6eb58f8cb578734f0bdd4538f9f54154477fcfd443a92684d3'
$before = @'
from .composite_context_provider import CompositeContextProvider
from .search_context_provider import SearchContextProvider
from .groundedness_evaluator import (
    GroundednessEvaluator, capture_grounding_context, encode_groundedness,
)
from .foundry_iq_context_provider import FoundryIQContextProvider
from .maf_plugins import UserProfile, UserProfileMemory
from .retrieval_intent import (
'@
$after = @'
from .composite_context_provider import CompositeContextProvider
from .search_context_provider import SearchContextProvider
from .groundedness_evaluator import (
    capture_grounding_context, encode_groundedness,
)
from .rag_evaluators import evaluate_rag_triad
from .foundry_iq_context_provider import FoundryIQContextProvider
from .maf_plugins import UserProfile, UserProfileMemory
from .retrieval_intent import (
'@
$text = Replace-Once $text $before $after
$before = @'
 
        # Reasoning effort for models that support it (e.g. gpt-5-mini)
        self.reasoning_effort = cfg.get("REASONING_EFFORT", "medium")
 
        # Off until the matching UI stream decoder and scorecard are deployed.
        self.groundedness_enabled = cfg.get(
            "ENABLE_GROUNDEDNESS_EVALUATION", False, type=bool)
        self._groundedness_evaluator = None
 
        # Runtime state
        self._chat_client: Optional[OpenAIChatClient] = None
'@
$after = @'
 
        # Reasoning effort for models that support it (e.g. gpt-5-mini)
        self.reasoning_effort = cfg.get("REASONING_EFFORT", "medium")
 
        # Runtime state
        self._chat_client: Optional[OpenAIChatClient] = None
'@
$text = Replace-Once $text $before $after
$before = @'
                        yield chunk.text
            logging.info("[MafLiteStrategy] agent_stream: %.2fs (response_len=%d)", time.time() - stream_start, len(full_response))
 
            if self.groundedness_enabled:
                if self._groundedness_evaluator is None:
                    self._groundedness_evaluator = GroundednessEvaluator(
                        endpoint=self.cfg.get("GROUNDEDNESS_AZURE_ENDPOINT", self.model_endpoint),
                        deployment=self.cfg.get("GROUNDEDNESS_EVALUATOR_MODEL", self.model_name),
                        credential=self._sync_credential,
                        api_version=self.openai_api_version,
                        reasoning_model=self.cfg.get(
                            "GROUNDEDNESS_IS_REASONING_MODEL", False, type=bool),
                        timeout_seconds=float(self.cfg.get("GROUNDEDNESS_TIMEOUT_SECONDS", 30)),
                        max_context_chars=int(self.cfg.get("GROUNDEDNESS_MAX_EVIDENCE_CHARS", 24000)),
                    )
                evaluation = await self._groundedness_evaluator.evaluate(
                    question=user_message, answer=full_response,
                    contexts=grounded_context,
                )
                # Transport metadata is never appended to assistant history.
                yield encode_groundedness(evaluation)
 
            # Persist conversation history locally
'@
$after = @'
                        yield chunk.text
            logging.info("[MafLiteStrategy] agent_stream: %.2fs (response_len=%d)", time.time() - stream_start, len(full_response))
 
            evaluation = await evaluate_rag_triad(
                cfg=self.cfg, endpoint=self.model_endpoint,
                deployment=self.model_name, credential=self._sync_credential,
                api_version=self.openai_api_version,
                question=user_message, answer=full_response,
                contexts=grounded_context,
            )
            if evaluation is not None:
                # Reuse the deployed wire format; metadata is not assistant history.
                yield encode_groundedness(evaluation)
 
            # Persist conversation history locally
'@
$text = Replace-Once $text $before $after
$pending['gpt-rag-orchestrator/src/strategies/maf_lite_strategy.py'] = $text
 
$backup = Join-Path $root ('DSC-triad-backup-' + [guid]::NewGuid().ToString('N'))
foreach ($relative in $pending.Keys) {
    $target = Join-Path $root $relative
    if (Test-Path -LiteralPath $target) {
        $saved = Join-Path $backup $relative
        New-Item -ItemType Directory -Path (Split-Path $saved) -Force | Out-Null
        Copy-Item -LiteralPath $target -Destination $saved
    }
}
foreach ($relative in $pending.Keys) {
    $target = Join-Path $root $relative
    New-Item -ItemType Directory -Path (Split-Path $target) -Force | Out-Null
    [System.IO.File]::WriteAllText($target,$pending[$relative],$utf8)
}
Write-Host "Applied $($pending.Count) source changes. Backup: $backup" -ForegroundColor Green
Write-Host 'This script did not deploy or modify Azure resources.'
Appendix D Replication kit contents
DSC_RAG_Triad_Replication_Kit.zip accompanies this guide. Extract it on your local computer to open and copy the text installers; you do not have to transfer the ZIP into the VM.
Kit item	Use
01 UI 02 Backend 03 Strategy TXT installers	Exact scripts reproduced in appendices A to C. Run in order on the reviewed baseline.
backend folder	Final groundedness_evaluator.py, rag_evaluators.py and maf_lite_strategy.py for source review and comparison.
ui folder	Final GroundednessStreamDecoder module and GroundednessCard.jsx.
reviewed_UI_integration folder	Complete reviewed chat.py and orchestrator_client.py showing the existing callback wiring. Reference snapshots, not a blanket overwrite instruction.
reviewed_search_context_provider.py	Reviewed evidence recording hook used by the working DSC search path.
HISTORICAL_GROUNDEDNESS_UI_INSTALLER.txt	Earlier first groundedness UI patch for historical reference. It is not needed on the current working groundedness baseline and is not a triad upgrade step.
tests folder	Local triad tests with stub evaluators, not Azure live test results.
TRIAD_INSTALLATION_README.md and READ_FIRST.txt	Installation scope and baseline requirements.

If starting from a different release, compare the final source and integration snapshots with your application. Recreate the same contracts while preserving that release security and startup behavior. The strict patch guards intentionally prevent an unsupported clean checkout from being silently overwritten.
