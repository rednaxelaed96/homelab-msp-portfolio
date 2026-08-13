---
layout: post
title: "Session 1: Standing up Azure Container Apps, from environment to a verified rollout"
date: 2026-08-11
---

Session 1 goal: get a small API running on Azure Container Apps, backed by a VNet-integrated environment, pulling from Azure Container Registry, authenticated the right way instead of the easy way. Five distinct issues came up along the way, one of which turned into a genuine mini-incident involving an exposed credential. Logged the way I'd write up a production incident: symptom, diagnosis, resolution, skill demonstrated.

## Setup: app and registry, reasoning for each choice

- **FastAPI app with `/health` and `/version` endpoints**: kept intentionally minimal, the point of this session is the infrastructure around the app, not the app itself.
- **`psycopg2`/database dependencies deliberately excluded at this stage**: Postgres integration is Session 2's scope, adding it here would blur what this session is actually testing.
- **Pushed via `az acr build` rather than a local Docker build**: builds the image in Azure directly, no local Docker install required, and keeps the build environment consistent regardless of what machine I'm working from.

```bash
az acr build \
  --registry acrhomelabakd \
  --image lab-api:v1 \
  ./app
```

Confirmed the repository landed in the registry via the Azure portal before moving on.

## Issue 1: Log Analytics workspace, resource provider not registered

**Symptom:** creating the Container Apps environment with a custom Log Analytics workspace failed because the environment couldn't create one automatically.

**Diagnosis:** the `Microsoft.OperationalInsights` resource provider wasn't registered on my subscription yet, a one-time prerequisite that isn't obvious until you hit it.

**Resolution:**

```bash
az provider register -n Microsoft.OperationalInsights --wait
```

**Skill demonstrated:** recognizing that some Azure resource types require their resource provider explicitly registered on a subscription before first use, a common first-time gotcha unrelated to permissions or syntax.

## Issue 2: subnet delegation error, and a naming convention worth protecting

**Symptom:**

```
(ManagedEnvironmentSubnetDelegationError) The subnet of the environment must be
delegated to the service 'Microsoft.App/environments'.
```

**Diagnosis:** `snet-lab` had been provisioned earlier for general use, with no service delegation attached. Container Apps environments require the target subnet explicitly delegated to `Microsoft.App/environments` before they'll attach to it.

**Resolution:** fixed directly in the portal (Subnet, then Subnet Delegation), also scriptable:

```bash
az network vnet subnet update \
  --resource-group rg-homelab-msp \
  --vnet-name vnet-homelab \
  --name snet-lab \
  --delegations Microsoft.App/environments
```

While troubleshooting this, noticed the environment would auto-generate a Log Analytics workspace with a random name if none was specified, which would have broken the `law-` naming convention set for this lab. Created `law-homelab` manually instead and passed it in explicitly:

```bash
az containerapp env create \
  --name cae-homelab \
  --resource-group rg-homelab-msp \
  --location eastus \
  --infrastructure-subnet-resource-id <subnet-resource-id> \
  --logs-workspace-id <log-analytics-customer-id> \
  --logs-workspace-key <log-analytics-shared-key>
```

**Skill demonstrated:** understanding Azure subnet delegation as a prerequisite for platform-managed services, and catching an auto-generated resource before it drifted from the established naming convention.

## Issue 3: ACR authentication, choosing identity over static credentials

**Symptom:**

```
Failed to retrieve credentials for container registry acrhomelabakd.
Please provide the registry username and password
```

**Diagnosis:** by default, `az containerapp create` can't authenticate to a private ACR without either admin credentials or an identity explicitly granted pull access.

**Resolution:** rather than enabling ACR admin credentials, a shared static secret sitting on the registry, set up Entra ID integration with a user-assigned managed identity scoped to `AcrPull` only:

```bash
az identity create --resource-group rg-homelab-msp --name id-acr-pull

identityId=$(az identity show --resource-group rg-homelab-msp \
  --name id-acr-pull --query id -o tsv)
principalId=$(az identity show --resource-group rg-homelab-msp \
  --name id-acr-pull --query principalId -o tsv)
acrId=$(az acr show --name acrhomelabakd --resource-group rg-homelab-msp --query id -o tsv)

az role assignment create \
  --assignee-object-id $principalId \
  --assignee-principal-type ServicePrincipal \
  --role AcrPull \
  --scope $acrId

az containerapp create \
  --name lab-api \
  --resource-group rg-homelab-msp \
  --environment cae-homelab \
  --user-assigned $identityId \
  --registry-identity $identityId \
  --registry-server acrhomelabakd.azurecr.io \
  --image acrhomelabakd.azurecr.io/lab-api:v1 \
  --target-port 8000 \
  --ingress external \
  --min-replicas 1 \
  --max-replicas 3
```

**Skill demonstrated:** choosing identity-based authentication over a static shared credential, and scoping the role assignment to the minimum permission needed, pull only, not push or manage. Broader access, if ever needed, is a deliberate follow-up change, not a default.

## Issue 4: mistagged image

**Symptom:**

```
Failed to provision revision for container app 'lab-api'. Field 'template.containers.lab-api.image'
is invalid: GET https:: MANIFEST_UNKNOWN: manifest tagged by "v1" is not found
```

**Diagnosis:** the image had actually pushed successfully in the setup step, just under the tag `vi` instead of the intended `v1`, a typo made while typing the original build command. The error itself doesn't say "typo," it just reports the tag missing.

**Resolution:** confirmed what was actually in the registry before assuming a deeper problem:

```bash
az acr repository show-tags --name acrhomelabakd --repository lab-api -o table
```

Updated the container app to the correct tag, then cleaned up the mistagged image entirely rather than leaving it as clutter:

```bash
az containerapp update \
  --name lab-api \
  --resource-group rg-homelab-msp \
  --image acrhomelabakd.azurecr.io/lab-api:v1

az acr repository untag --name acrhomelabakd --image lab-api:vi

az acr repository delete \
  --name acrhomelabakd \
  --image lab-api@sha256:22bfe4b912e8fdec6169c543f73479751b61e18d7d1efe976ad33e9f920aea9c \
  --yes
```

**Skill demonstrated:** not taking an error message at face value. `MANIFEST_UNKNOWN` reads like a permissions or registry-connectivity issue, checking the registry's actual tag list first ruled that out quickly and pointed straight at the real cause.

## Issue 5: exposed Log Analytics shared key, rotation, then a bad API

**Symptom:** while writing up this session's notes, a Log Analytics workspace shared key ended up pasted into a document about to be shared. Not a technical failure, a real incident: a live credential had been exposed and needed to be treated as compromised immediately.

**Diagnosis:** the safest response to an exposed credential is to assume it's usable by someone else the moment it's exposed, regardless of how low the actual risk of misuse is. The right move is rotation, not just deleting the copy that leaked.

**Resolution attempt 1, regenerate via CLI:** `az monitor log-analytics workspace regenerate-shared-keys` doesn't actually exist as a command, the CLI's `log-analytics workspace` command group only supports `get-shared-keys` (retrieval), not regeneration.

**Resolution attempt 2, regenerate via portal:** Microsoft has been removing the Primary/Secondary key display from the workspace's **Agents** blade as part of a broader shift away from shared-key auth toward Azure Monitor Agent with Azure AD/Managed Identity-based ingestion. The keys still exist, but that UI path is gone for this workspace.

**Resolution attempt 3, regenerate via REST API directly:**

```bash
az rest --method post \
  --uri "https://management.azure.com<workspace-resource-id>/regenerateSharedKey?api-version=2025-02-01"
```

This matched Microsoft's current published API reference exactly, no request body required per the docs. Still failed:

```
(BadArgumentError) keyType value must equal primarySharedKey or secondarySharedKey
```

Adding the body the error asked for, on both the current and an older API version, produced the same error. This matches a long-standing, still-unresolved bug reported against the Azure CLI (Azure/azure-cli#24961), the regenerate operation rejects valid input at a layer before the request body is properly validated.

**Final resolution:** rather than keep fighting an undocumented API bug, deleted and recreated the Log Analytics workspace outright. For a lab environment with no historical log data worth preserving, this guarantees the exposed key is permanently dead rather than just rotated:

```bash
az monitor log-analytics workspace delete \
  --resource-group rg-homelab-msp \
  --workspace-name law-homelab \
  --force true --yes

az monitor log-analytics workspace create \
  --resource-group rg-homelab-msp \
  --workspace-name law-homelab
```

Repointed the Container Apps environment at the new workspace's ID and key, and confirmed connectivity by listing available tables rather than querying a specific one blind:

```bash
az monitor log-analytics workspace table list \
  --resource-group rg-homelab-msp \
  --workspace-name law-homelab \
  -o table
```

`ContainerAppConsoleLogs_CL` doesn't exist in a fresh workspace until the first log entry actually lands in it, querying it directly before any traffic hit the app returned a semantic error that looked like a config problem but wasn't one. Generating real requests against the app first, then re-checking the table list a few minutes later, confirmed logging was flowing correctly.

**Addendum: the key was still in git history.** Rotating the credential handled live risk, but the old key was still sitting in the repo's commit history in plaintext. Used `git-filter-repo` on a fresh clone to scrub it:

```bash
python -m git_filter_repo --replace-text ../secrets.txt --force
```

The first two attempts reported success but the key was still findable in `git log --all -p` afterward. The cause was a UTF-8 byte-order-mark, three invisible bytes (`EF BB BF`) that PowerShell silently added to the front of the replacement file when saved with `-Encoding utf8`. `--replace-text` requires an exact literal match, so a file that looks identical to the human eye but starts with three different invisible bytes silently fails to match anything, no error or warning. Confirmed it with:

```powershell
Format-Hex ..\secrets.txt | Select-Object -First 1
```

which showed `EF BB BF` where the file should have started directly with the letter `s`. Rewrote the file without a BOM using .NET's file writer instead of PowerShell's redirect operators, redid the fresh clone and rewrite, and verified clean:

```bash
git log --all -p | Select-String "GSEtbGwP41t8u34UxvFsun"
```

Empty result. Force-pushed, confirmed on GitHub the commit diff now shows `***REMOVED***` in place of the real key.

**Skill demonstrated:** treating credential exposure as an incident requiring immediate rotation regardless of perceived risk, working through a genuinely broken first-party API path methodically rather than assuming user error, recognizing an empty query result as an ingestion-timing artifact rather than a broken pipeline, and tracking down a silent, byte-level encoding bug by checking raw file contents instead of re-running the same command and hoping for a different result.

## Verification and a deliberate rollout

Once the app was live, confirmed both endpoints:

```bash
curl https://lab-api.calmstone-7f1b5d3b.eastus.azurecontainerapps.io/health
curl https://lab-api.calmstone-7f1b5d3b.eastus.azurecontainerapps.io/version
```

Then, as a deliberate exercise rather than a fix, practiced a real revision rollout: bumped the app to `2.0.0`, enabled multiple-revision mode, deployed `v2` alongside `v1`, split traffic 50/50, and confirmed both versions responded before cutting over fully:

```bash
az containerapp revision set-mode \
  --name lab-api --resource-group rg-homelab-msp --mode multiple

az acr build --registry acrhomelabakd --image lab-api:v2 ./app

az containerapp update \
  --name lab-api --resource-group rg-homelab-msp \
  --image acrhomelabakd.azurecr.io/lab-api:v2 --revision-suffix v2
```

Hit `/version` several times in a row during the split and saw both `1.0.0` and `2.0.0` come back before cutting fully over to `v2`.

## What's next

Session 2 moves into Postgres Flexible Server, connecting it to this app, and actually testing a backup and restore instead of just enabling the toggle and assuming it works.