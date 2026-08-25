---
layout: post
title: "Session 6: CI/CD with OIDC, and the what-if that caught a real outage before it happened"
date: 2026-08-25
---

Session 6 goal: a GitHub Actions pipeline that builds, pushes, and deploys the Bicep infrastructure from Session 5 automatically, authenticated without any long-lived credential sitting in GitHub's secret store. This turned into the richest session of the project so far, not because any single service was hard, but because wiring together two different platforms' security models (Azure's identity federation and GitHub's evolving OIDC token format) surfaced a genuinely current, actively-changing piece of platform behavior, and because the very first real `what-if` run against production caught something that would have caused a real outage.

## Setup: OIDC over stored credentials, and a deliberate scoping decision

- **OIDC federated credentials, not an Azure service principal secret**: every credential decision this project has made has trended the same direction, managed identity over ACR admin keys, Entra ID over Postgres and Redis passwords. This is the same principle applied to the pipeline itself: GitHub's token service and Azure trust each other directly per workflow run, no long-lived secret sits in GitHub at all, closing off the exact category of risk that caused the Session 1 incident, by design this time.
- **An Entra App Registration, not another user-assigned managed identity**: managed identities authenticate Azure resources to other Azure resources. GitHub Actions runs outside Azure entirely, it needs an identity type that external services can authenticate as, which is what an App Registration and its service principal provide.
- **Contributor plus Role Based Access Control Administrator, scoped to `rg-homelab-msp` only**: Contributor alone isn't enough, since `identities.bicep` creates a role assignment, and granting any role assignment requires the separate RBAC Administrator permission. Both scoped to one resource group, not the subscription, same least-privilege pattern applied to every identity in this project.
- **Deployed against the real `rg-homelab-msp`, deliberately, not a disposable test group**: Session 5 left this open on purpose. Given how thoroughly the Bicep templates were already verified, this felt like the more honest demonstration of what CI/CD is actually for.

## Issue 1: the service principal command didn't accept the app I'd already created

```
unrecognized arguments: --id 6550d417-94f5-443f-9f2f-da9b35604ce5
```

**Diagnosis:** `az ad sp create-for-rbac` creates an app registration *and* its service principal together in one step, it has no mode for attaching a service principal to an app that already exists. Since the App Registration had already been created separately, this command was the wrong tool entirely.

**Resolution:** `az ad sp create --id $appId`, the command actually designed for creating a service principal against an existing application.

## Issue 2: PowerShell tooling friction, JSON quoting and file encoding

Passing JSON directly as a `--parameters` string argument failed:

```
Failed to parse string as JSON: {name:gh-actions-main,issuer:...}
```

PowerShell strips the double quotes out of a single-quoted string before Azure CLI ever receives it. **Resolution:** write the JSON to a file with a PowerShell here-string, then reference it with `@filename`, sidestepping shell quoting entirely.

That fix then hit a second, smaller issue: `Set-Content -Encoding utf8NoBOM` isn't a valid option on Windows PowerShell 5.1, that encoding name was only added in PowerShell 6+. Writing the file this way on 5.1 with plain `UTF8` would have reintroduced the exact byte-order-mark problem from Session 1. **Resolution:** `[System.IO.File]::WriteAllText(path, content, [System.Text.UTF8Encoding]::new($false))`, the .NET framework directly, version-independent and BOM-free regardless of which PowerShell is running.

**Skill demonstrated:** recognizing a previously-solved problem (BOM corruption) resurfacing in a new context, and reapplying the same underlying fix rather than treating it as new.

## Issue 3: the workflow existed but never ran

Pushing the new workflow file produced no run at all. **Diagnosis:** the trigger's `paths:` filter only watched `app/`, `pgbouncer/`, and `infra/`, the workflow file itself lives in `.github/workflows/`, outside all three, so the very push that created it never satisfied its own trigger condition. **Resolution:** added `workflow_dispatch:` to the trigger, giving a manual **Run workflow** button independent of the path filter, useful for testing regardless of which files changed.

## Issue 4: GitHub's OIDC subject claim format changed underneath this project, twice

This is the standout platform-level finding of the session, worth walking through in full since it happened in two distinct stages.

**Stage one:** the first workflow run failed authentication entirely:

```
AADSTS700213: No matching federated identity record found for presented assertion
subject 'repo:rednaxelaed96@21231937/homelab-msp-portfolio@1304647603:ref:refs/heads/main'.
```

**Diagnosis:** GitHub rolled out an "immutable subject claim" format for OIDC tokens, embedding the permanent, numeric owner and repository IDs alongside the names (`owner@ownerID/repo@repoID`), specifically to prevent a security issue where a renamed or recreated repository could inherit trust it shouldn't. This repository was already using the new format by default; the federated credential created earlier used the older, name-only format, and no longer matched.

**Resolution:** rather than compute the new subject format by hand, used the exact string GitHub's own error message provided, created a new federated credential matching it, and removed the now-obsolete name-only one.

**Stage two, after adding a human approval gate:** tying the deploy job to a GitHub Environment (for required-reviewer approval) produced a *second* authentication failure, with a subtly different subject:

```
subject 'repo:rednaxelaed96@21231937/homelab-msp-portfolio@1304647603:environment:production'
```

**Diagnosis:** GitHub computes a different subject shape depending on *how* a job runs, not just which repo and branch. A job tied to an environment presents an environment-scoped subject (`environment:production`) instead of the branch-scoped one (`ref:refs/heads/main`), even for the exact same repository and workflow. The existing federated credential only trusted the branch-scoped shape.

**Resolution:** added a third, separate federated credential specifically for the environment-scoped subject. The two jobs in this pipeline, `build-and-push` (plain branch trigger) and `deploy-infra` (environment-gated), genuinely need separate trust entries, since they produce genuinely different tokens.

**Skill demonstrated:** diagnosing a live, actively-rolling-out platform change rather than assuming a static, always-correct configuration once and never revisiting it, and recognizing that OIDC trust isn't just "this repo, this branch," it's "this exact token shape," which depends on job configuration details easy to overlook.

## Issue 5: a fourth instance of the Bicep pass-through pattern from Session 5

```
ERROR: unrecognized template parameter 'labApiImageTag'. Allowed parameters: acrName,
appInsightsConnectionString, dbHost, location, redisHost, resourceGroupName
```

The workflow passed `labApiImageTag` and `pgbouncerImageTag`, using the commit SHA as the image tag so every deployment ties to exact source, but neither was declared and forwarded at the `main.bicep` level, same missing-link pattern documented in Session 5, showing up a fourth time. Fixed the same way: declare, forward, done.

## Issue 6: subscription-scope permissions don't fit a resource-group-scoped pipeline identity

The first real `what-if` attempt failed with:

```
(AuthorizationFailed) ... does not have authorization to perform action
'Microsoft.Resources/deployments/whatIf/action' over scope '/subscriptions/***'
```

**Diagnosis:** `main.bicep` used `targetScope = 'subscription'` so it could create the resource group itself, useful for Session 5's disposable test groups. But every operation against a subscription-scoped template, including a preview, happens at subscription scope, and the pipeline's identity was deliberately scoped down to just `rg-homelab-msp`. Widening the pipeline's permissions just to preserve a capability it didn't need would have meant trading away least-privilege for convenience.

**Resolution:** created a second entry point, `main-deploy.bicep`, targeting `resourceGroup` scope instead, for deploying into a resource group that already exists. Kept the original `main.bicep` for its original purpose, spinning up fully isolated test environments. Updated the workflow to use `az deployment group` instead of `az deployment sub`.

**Skill demonstrated:** resolving a permissions mismatch by narrowing the template's scope to match the actual need, rather than widening the identity's access to match the template, a meaningfully different, more defensible choice.

## Issue 7: the what-if that caught a real, live-breaking change before it happened

The first `what-if` against real infrastructure surfaced something serious, worth describing in full since it's the clearest demonstration in this entire project of why pre-deployment review matters, not as an abstract best practice, but as something that would have caused a genuine outage if skipped.

**What the diff showed:** the real `vnet-homelab` had two subnets, the original `snet-lab`, and a second one, `amr-snet`, created automatically when the Redis private endpoint was set up in Session 4. The Bicep template's VNet resource only ever declared one subnet. Since a VNet's `subnets` property is authoritative, not a merge, applying this deployment would have deleted `snet-lab`'s real configuration and reconfigured `amr-snet` to replace it, address prefix, delegation, and NSG all changed at once. Redis's private endpoint network interface almost certainly depended on `amr-snet`'s existing configuration, this would very likely have broken Redis connectivity, and possibly the container app's networking too, in a single deployment.

**Resolution:** queried the real subnet's configuration directly rather than guessing, added it explicitly to `foundation.bicep` alongside the original, and reran `what-if` to confirm the destructive diff was gone.

**The broader lesson:** every finding in this session, this one included, traces back to the same root cause, this Bicep template was written from how the infrastructure was originally understood, not queried from what it had since become through manual changes. Adopting existing, hand-managed infrastructure into IaC requires reconciling the template against current reality first, not just describing the original intent.

## Issue 8: a second what-if surfaced a role assignment collision

```
{"code":"RoleAssignmentExists","message":"The role assignment already exists.
The ID of the existing role assignment is 2f826ae117284c63bbb7a8a150a5a52d."}
```

**Diagnosis:** Bicep's deterministic name for the AcrPull role assignment (`guid(acr.id, idAcrPull.id, acrPullRoleId)`) guarantees consistency across *redeployments of the same template*, it does not guarantee it matches whatever name a *different* tool generated for the equivalent real-world assignment, in this case, the `az role assignment create` command run by hand back in Session 1.

**Resolution:** queried the real assignment's actual name directly and used that literal GUID in the Bicep resource instead of letting it compute a new one, genuinely adopting the hand-made assignment under Bicep's management rather than colliding with it.

## Issue 9: an empty GitHub secret produced the same failure signature as an empty shell variable

```
ContainerAppSecretInvalid: value ... [empty]
```

Same root cause as the PowerShell session-variable issue from Session 5, just at the GitHub Actions layer: `${{ secrets.APPINSIGHTS_CONNECTION_STRING }}` resolves silently to an empty string if the secret name doesn't exist exactly as referenced, no workflow-level error, the failure only surfaces downstream at Azure's validation step. The secret had been planned but never actually added to the repo. Added it, along with `REDIS_HOST`, and the deployment proceeded cleanly.

## What actually shipped

Three verified `what-if` cycles, a subnet fix, a role assignment adoption fix, and a human approval gate later, the pipeline completed a real deployment against production infrastructure with zero errors. Confirmed the app came back healthy on both `/health` and `/notes` immediately after.

## What's next

With Sessions 0 through 6 complete, foundation, Container Apps, Postgres with passwordless auth, connection pooling, observability, Redis caching, full IaC, and now a working, OIDC-authenticated, human-gated CI/CD pipeline, this project has covered the full arc from a resource group to a self-deploying, self-documenting system.