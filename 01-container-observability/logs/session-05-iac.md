---
layout: post
title: "Session 5: Converting the homelab to Bicep, and what real test isolation actually reveals"
date: 2026-08-25
---

Session 5 goal: turn everything built by hand across Sessions 0 through 4 into repeatable infrastructure-as-code. Chose Bicep over extending the existing Terraform skill set deliberately, it's Azure-native, named alongside Terraform in the CAI posting, and building real depth in a second IaC tool demonstrates breadth rather than repetition. This session had fewer novel Azure services than earlier ones, but it surfaced something more valuable: the same class of mistake, forgetting to explicitly forward a value between scopes, showing up three separate times before it actually stuck, followed by a genuinely sophisticated discovery about what "test in isolation" really means for networked infrastructure.

## Setup: scope and structure

- **Four modules, not one flat template**: `foundation.bicep` (resource group contents: VNet, subnet, NSG, ACR), `identities.bicep` (the three managed identities and the AcrPull role assignment), `containerapps-env.bicep` (Log Analytics and the Container Apps environment), `containerapp.bicep` (the actual `lab-api` app, both containers). Mirrors how the real environment was built incrementally, session by session, rather than one undifferentiated file.
- **Postgres, Redis, and Application Insights deliberately left out of this conversion**: converting all three as well would have roughly doubled this session's scope. They're referenced as external dependencies via parameters (`dbHost`, `redisHost`, `appInsightsConnectionString`) instead, an honest, explicit boundary rather than a template that pretends to own more than it does.
- **`targetScope = 'subscription'` on the top-level template**: lets the template create the resource group itself, rather than assuming one already exists, closer to the real Session 0 work than a resource-group-scoped template would be.
- **All testing against a throwaway resource group, `rg-homelab-bicep-test`**, never the live environment, with ACR names overridden via parameter to avoid colliding with the real, globally-unique `acrhomelabakd`.

## Issue 1: the same missing pass-through, three separate times

Bicep does not propagate values implicitly between scopes, not module-to-module, and not module-to-top-level. Every value has to be explicitly declared and forwarded at every hop, and this bit the same way three times before the pattern actually sank in.

**Instance one:** `main.bicep` declared an `acrName` parameter but never included it in the `params` block of the `module foundation` call. The module silently fell back to its own default (`acrhomelabakd`), causing a naming collision with the real, already-existing registry:

```
AlreadyInUse: The registry DNS name acrhomelabakd.azurecr.io is already in use.
```

**Instance two:** after fixing the first issue, `az deployment sub show --query "properties.outputs"` returned nothing at all, despite every module correctly defining its own outputs. `main.bicep` had no `output` block whatsoever, module outputs don't bubble up to the deployment's own outputs automatically, they need their own explicit forwarding statement at the top level too.

**Instance three:** wiring up the fourth module (`containerapp.bicep`), its `dbHost`, `redisHost`, and `appInsightsConnectionString` parameters were mistakenly sourced from `foundation.outputs.*`, values that module never defined. A different flavor of the same underlying habit, referencing a plausible-looking but nonexistent source instead of the actual top-level parameters already in scope.

**Resolution, each time:** explicitly declare and forward the value at the specific layer it was missing, no shortcut, no implicit inheritance exists in Bicep to lean on.

**Skill demonstrated:** recognizing a recurring root cause across superficially different symptoms (a naming collision, an empty query result, a build-time reference error) rather than treating each as an unrelated one-off fix. By the third instance, diagnosis time had dropped from a full back-and-forth to catching it directly in a code review before deploying.

## Issue 2: shell tooling friction, and a decision to standardize

Multiple commands this session failed with PowerShell parser errors (`Missing expression after unary operator '--'`), caused by bash-style trailing backslash line continuations, which PowerShell doesn't recognize, it needs a backtick instead. This happened enough times across this session specifically that it was worth resolving as policy rather than fixing case by case:

- Line continuation: backtick (`` ` ``) at the end of the line, no trailing whitespace after it
- Variable assignment: `$var = command`, not `var=$(command)`
- Checking a variable: bare `$var`, not `echo $var`
- Environment variables for one command: `$env:VAR = "value"`, no bash-style inline `VAR=value command` support

**Skill demonstrated:** recognizing when a recurring friction point is worth solving at the policy level (standardize on one shell, document the syntax differences once) rather than continuing to pay the cost of re-deriving the fix every time it resurfaced.

## Issue 3: "point this at an existing resource instead" isn't just a parameter change

While troubleshooting a missing image in the test ACR, tried redirecting the deployment at the real, already-existing `acrhomelabakd` registry by simply passing its name as the `acrName` parameter, expecting the template to treat it as a reference. Instead:

```
AlreadyInUse: The registry DNS name acrhomelabakd.azurecr.io is already in use.
```

**Diagnosis:** a plain `resource` block in Bicep is unconditionally a create-or-update declaration against that exact name. There's no built-in "create if new, reference if it already exists" behavior based on which value happens to be passed in. Referencing something that already exists requires the explicit `existing` keyword, the same pattern already used elsewhere in this project, in `identities.bicep`, to reference the ACR when granting it a role assignment, without recreating it.

**Resolution:** kept the isolated test ACR and pushed copies of the existing images into it instead, rather than adding template complexity to support a mixed create-or-reference mode that this verification step didn't actually need.

**Skill demonstrated:** understanding a core Bicep semantic (declarative resource blocks are not conditional by default) rather than treating an unexpected error as a random failure to work around.

## Issue 4: two small races in iterative test-and-teardown cycles

**Race one:** redeploying immediately after `az group delete --yes --no-wait` failed with `ResourceGroupBeingDeleted`, the delete command returns as soon as the deletion *starts*, not once it's finished. Resolved by checking `az group exists` before redeploying, or dropping `--no-wait` and letting the delete block until actually complete.

**Race two:** a deployment failed with `ContainerAppSecretInvalid: value ... should be provided`, traced back to a PowerShell session variable (`$appInsightsConn`) being empty, either never re-set in a new terminal window, or captured before confirming the underlying `az monitor app-insights component show` call actually returned data.

**Skill demonstrated:** treating "the command didn't error" as insufficient evidence that a value was actually captured correctly, and building the habit of checking a variable's contents directly before trusting it inside a longer command.

## The real finding: what true test isolation actually proves and doesn't

With the container app definition finally deploying cleanly into the test resource group, both containers pulling correctly, secrets resolving, identities attaching, the app itself still failed to start:

```
psycopg2.OperationalError: could not translate host name
"db-psqlflex-homelab.postgres.database.azure.com" to address: Name or service not known
```

**Diagnosis, and the part worth sitting with:** this wasn't a bug. `foundation.bicep` had created a brand-new VNet in the test resource group, sharing a name with the real `vnet-homelab` but entirely unrelated to it as an actual resource. The VNet peering connection that lets `vnet-homelab` reach Postgres, set up deliberately back in Session 2, is a relationship between two *specific* resources, not something that extends automatically to any VNet that happens to share a name. A genuinely isolated test environment has, by definition, no path to a private, peered resource living outside it, the DNS failure was the network correctly reporting exactly that.

**What this did and didn't validate:** everything up to that exact boundary worked, image pull, identity attachment, secret resolution, container startup up to the first external network call. The one thing a fully isolated test can't validate is connectivity that depends on infrastructure relationships (peering, private DNS zone links) that only exist in the real environment. Proving that specific piece would require either peering the test VNet too, real, nontrivial additional work for a one-off check, or deploying against the live environment directly, a more consequential decision than a routine test pass warrants.

**Skill demonstrated:** distinguishing between "the template has a bug" and "the template is correct, and this is an inherent boundary of the isolation strategy chosen for testing it," a distinction that matters a great deal in real infrastructure work, where chasing a phantom bug in the wrong layer wastes real time.

## What's next

The original Session 5 scope also included CI/CD, a GitHub Actions pipeline to build, push, and deploy automatically on commit. Given how much ground the Bicep conversion alone covered, that's a clean, deliberate stopping point here rather than a rushed add-on, worth treating as its own dedicated session.