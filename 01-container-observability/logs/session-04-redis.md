---
layout: post
title: "Session 4: Caching with Azure Managed Redis, and a bug that hid in plain sight"
date: 2026-08-25
---

Session 4 goal: add caching in front of the Postgres reads, measure the actual improvement, and think through what could go wrong under real load. Redis itself turned out to be the easy part. The real story in this session is everything downstream of it: a client library whose real API didn't match its own documentation, a latency test that lied by omission, and a bug that let the app run perfectly while quietly never executing the code I'd just written.

## Setup: choosing Azure Managed Redis, reasoning for each decision

- **Azure Managed Redis over classic Azure Cache for Redis**: Microsoft's own documentation now recommends migrating away from the classic service, it's on a retirement path. Building new portfolio work on a service already headed toward deprecation isn't a good look, Managed Redis is the forward-looking choice even though it's less documented.
- **Private Link for network connectivity, not Premium-tier VNet injection**: private connectivity to Redis no longer requires the expensive Premium tier, Private Link works across tiers now, consistent with the cost-conscious approach used for Postgres.
- **Microsoft Entra ID authentication, on by default**: unlike Postgres, which required explicitly enabling Entra-only auth, Managed Redis ships with managed identity auth already active when a new cache is created. No separate toggle to find.
- **A dedicated identity, `id-redis-auth`**, scoped to just this purpose, same least-privilege pattern as `id-postgres-auth` and `id-acr-pull` from earlier sessions.

One lesson carried forward deliberately from Session 2: Entra auth being *available* by default doesn't mean a specific identity is *authorized*. Just like Postgres required explicitly registering `id-postgres-auth` as a database role, Redis requires explicitly adding `id-redis-auth` as an authorized user under the cache's **Authentication → Microsoft Entra Authentication** settings, a separate step from Entra auth simply being turned on.

## Issue 1: the official client library's real API didn't match its own docs

Research pointed at `redis-entraid`, the official package for Entra-authenticated connections to Azure Managed Redis, built on top of `redis-py` with automatic token renewal. The documented usage example only covered system-assigned identities:

```python
credential_provider = create_from_managed_identity(
    identity_type=ManagedIdentityType.SYSTEM_ASSIGNED,
    resource="https://redis.azure.com/"
)
```

For a user-assigned identity, following the pattern used with `ManagedIdentityCredential(client_id=...)` from the Postgres code seemed reasonable:

```python
redis_credential_provider = create_from_managed_identity(
    identity_type=ManagedIdentityType.USER_ASSIGNED,
    resource="https://redis.azure.com/",
    client_id=os.environ["REDIS_IDENTITY_CLIENT_ID"],
)
```

**Symptom:** `TypeError: create_from_managed_identity() got an unexpected keyword argument 'client_id'`.

**Diagnosis:** the documented examples simply didn't cover the user-assigned case, and guessing a parameter name a second time risked another wasted deploy cycle. Rather than guess again, installed the package locally and inspected the real function signature directly:

```bash
python -m pip install redis-entraid
python -c "from redis_entraid.cred_provider import create_from_managed_identity; help(create_from_managed_identity)"
```

This revealed the actual parameters: `id_type` and `id_value`, not `client_id`. A follow-up inspection of the `ManagedIdentityIdType` enum confirmed the correct value:

```bash
python -c "from redis_entraid.cred_provider import ManagedIdentityIdType; help(ManagedIdentityIdType)"
```

```
CLIENT_ID = <ManagedIdentityIdType.CLIENT_ID: 'client_id'>
OBJECT_ID = <ManagedIdentityIdType.OBJECT_ID: 'object_id'>
RESOURCE_ID = <ManagedIdentityIdType.RESOURCE_ID: 'resource_id'>
```

**Resolution:**

```python
redis_credential_provider = create_from_managed_identity(
    identity_type=ManagedIdentityType.USER_ASSIGNED,
    resource="https://redis.azure.com/",
    id_type=ManagedIdentityIdType.CLIENT_ID,
    id_value=os.environ["REDIS_IDENTITY_CLIENT_ID"],
)
```

A follow-up deploy then hit a second, smaller version of the same underlying problem: `NameError: name 'ManagedIdentityIdType' is not defined`, the new parameter had been added without adding its corresponding import. A one-line fix once caught.

**Skill demonstrated:** not trusting library documentation when it doesn't cover the actual use case, and verifying an API's real shape directly against the installed package (`help()`) rather than guessing a second or third time and burning another deploy cycle on each guess.

## Issue 2: the first latency comparison was measuring the wrong thing

With Redis wired up, the natural first test was a simple before/after `curl` timing comparison:

```bash
curl -w "\nTime: %{time_total}s\n" -o /dev/null -s "https://<fqdn>/notes"
curl -w "\nTime: %{time_total}s\n" -o /dev/null -s "https://<fqdn>/notes"
```

Results came back nearly identical, 177ms, then 184ms, then 210ms, no visible improvement despite both requests returning identical data.

**Diagnosis:** each separate `curl` invocation pays for its own fresh TLS handshake and connection setup through Container Apps ingress, fixed overhead unrelated to caching. Against a baseline where a Postgres round-trip typically added well under 150ms, that fixed cost was large enough to completely swamp whatever Redis was actually saving.

**A partial fix, and its limits:** reusing a single connection across two requests (`curl --next`) narrowed the gap to something more plausible, 180ms versus 109ms, but two data points still can't rule out ordinary variance. The real fix was to stop inferring cache behavior from external network timing entirely and measure it directly inside the app, the same way token acquisition latency was measured in Session 3.

**Resolution:** added a custom OpenTelemetry histogram, `notes_fetch_duration_ms`, tagged by whether the request was a cache hit or miss, isolating the actual function execution time from any network or TLS noise around it.

**Skill demonstrated:** recognizing that an external, black-box timing measurement can be dominated by factors that have nothing to do with the thing being measured, and moving to an internal, tagged measurement to get a result that actually isolates the variable being tested.

## Issue 3: the instrumented code was completely unreachable, and nothing about it looked wrong

After adding the histogram and the cache-aside logic to `list_notes()` and cache invalidation to `create_note()`, the app deployed cleanly, requests all returned `200 OK`, and the response data looked correct. But `customMetrics` showed nothing at all for `notes_fetch_duration_ms`, no errors anywhere to explain why.

**Diagnosis, found only by reviewing the full file rather than the diff:** the file had **two definitions** of both `list_notes()` and `create_note()`, the original versions from before Redis was added were still present above the new instrumented versions. Python keeps only the last definition when a function name is reused, but each `@app.get("/notes")` decorator registers a separate route in FastAPI's router the moment it's evaluated, and Starlette matches routes in registration order, using the *first* match. Every request to `/notes` had been served by the old, pre-Redis code the entire time, the new code sat below it, fully correct, completely unreachable. This explained every earlier symptom at once: clean 200 responses (the old code worked fine), no measurable performance difference (Redis was never actually touched), and zero custom metrics (the instrumented function never ran).

A second, latent bug was hiding behind the first: the new code called `json.loads()` and `json.dumps()`, but `import json` had never been added. Because the duplicate route was silently shadowing it, this would have caused an immediate `NameError` the first time a real cache hit occurred, invisible until the dead code became live.

**Resolution:** removed both duplicate function definitions, kept only the instrumented versions, added the missing `import json`.

**Skill demonstrated:** recognizing that "the app works and returns no errors" is not the same as "the code I just wrote is running," and that Python's last-definition-wins behavior combined with FastAPI's first-match routing can produce a bug with zero error output at any layer. Diagnosed by reading the actual file in full rather than trusting that a code review of the new additions alone was sufficient.

## Real numbers, once the instrumentation was actually running

```kusto
customMetrics
| where name == "notes_fetch_duration_ms"
| summarize avg(valueSum), count() by tostring(customDimensions.cache_hit)
```

| cache_hit | avg duration | count |
|---|---|---|
| false | 495.5ms | 2 |
| true | 6.3ms | 2 |

Roughly a 98% reduction on a cache hit. Worth being direct about the limits of this result: only two samples per side, a real benchmark would need far more traffic to be statistically meaningful. Also worth reconciling against the Session 3 baseline, that 495ms cache-miss figure is notably higher than the 90-125ms p95 latency observed there, because this metric measures the full `list_notes()` function body specifically, while the Session 3 numbers measured total HTTP request duration through the whole ingress/FastAPI stack. Different things, not a contradiction, but worth stating plainly rather than leaving an apparent mismatch unexplained.

## Cache stampede consideration

The current setup uses a single shared key (`notes:latest`) with a 30-second TTL, plus explicit invalidation on every write. Both create the same underlying risk: at the moment the key expires, or the instant after a write deletes it, there's a window where the cache is empty but demand for it isn't. If multiple requests hit `/notes` concurrently during that window, all of them see a cache miss simultaneously, and all of them independently query Postgres and attempt to repopulate the same key, a classic cache stampede (or dogpiling). At this lab's traffic volume, that's harmless, worst case a few redundant Postgres queries. At real production traffic, a popular cache key expiring is exactly the moment a service is most likely to see a synchronized burst of database load, self-inflicted, and often mistaken for an unrelated database problem when it shows up as a symptom.

The standard mitigations, not implemented here but worth naming: a short-lived distributed lock (a Redis `SETNX` on a companion `notes:latest:lock` key) so only one request rebuilds the cache while others wait briefly or serve the expiring value; or a stale-while-revalidate pattern, serving the old value past its TTL while a single background refresh updates it, trading brief staleness for eliminating the thundering-herd effect entirely. Given this app's read pattern, infrequent writes against a small, cheap dataset, a stampede here is a non-issue in practice, but it's a failure mode worth recognizing by name rather than discovering during a real incident.

## What's next

With Postgres, pooling, observability, and now caching all in place, the remaining build guide goal is tying the whole thing together as one repeatable deployment, converting the manual setup across all four sessions into IaC and a CI/CD pipeline.