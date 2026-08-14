---
layout: post
title: "Session 3: Observability, a custom metric, a free Grafana dashboard, and alerts tested against real failure"
date: 2026-08-13
---

Session 3 goal: real telemetry on `lab-api`, a dashboard worth looking at, and at least one alert with a threshold I could actually defend, not a default left untouched. This session had fewer infrastructure-breaking errors than Sessions 1 and 2, but more genuinely subtle ones: documentation that didn't match reality, a metric type that quietly hides small-sample noise, and an alert that fired correctly while every obvious signal said it hadn't.

## Setup: Application Insights and diagnostic wiring

- **Application Insights resource `appins-labapi-homelab`, connected to the existing `law-homelab` workspace from Session 2**: workspace-based Application Insights, not a standalone classic resource, keeps all telemetry (requests, metrics, logs) queryable from one place rather than split across two data stores.
- **A diagnostic setting `LabapiMetricsToMonitor` sending AllMetrics from `lab-api` to `law-homelab`**: platform-level Container Apps metrics (CPU, memory, replica counts) captured independently of anything the app code does, so infrastructure health is visible even if the app-level instrumentation were to fail entirely.

## Issue 1: Azure Managed Grafana's free tier is gone

**Diagnosis:** planned to stand up a standalone Azure Managed Grafana instance, matching the exact tool named in the CAI posting. Found that Microsoft retired the free/low-cost "Essential" tier, new Essential workspaces can't even be created anymore, the only remaining standalone option is the Standard tier, real ongoing dedicated-hosting and per-user cost, disproportionate for a single-developer lab.

**Resolution:** used Microsoft's own recommended replacement, **Azure Monitor Dashboards with Grafana**, a free, built-in Grafana experience inside the Azure portal, connected natively to the same Log Analytics and Application Insights data, no separate resource, no separate cost. Same dashboard engine, same query language, accessible directly from the Application Insights resource under **Monitoring → Dashboards with Grafana**.

**Skill demonstrated:** catching a cost-relevant platform change before committing to a resource, and recognizing when Microsoft's own recommended migration path is a better fit than the thing originally planned, not just a fallback.

## Issue 2: request telemetry wasn't showing up at all

**Symptom:** built the first dashboard panel (Availability), no data. Ran a bare `requests | take 10` directly against Application Insights, also empty, despite the custom `entra_token_acquisition_duration_ms` histogram already confirmed working from Step 1.

**Diagnosis:** the `azure-monitor-opentelemetry` package documentation states FastAPI instrumentation is "bundled and enabled by default." In practice, it wasn't activating automatically. Since metrics were flowing but request spans weren't, this pointed specifically at the FastAPI instrumentation hook, not the underlying telemetry pipeline (connection string, network egress, ingestion all already proven working by the custom metric).

**Resolution:** explicitly instrumented the app instance rather than relying on automatic activation:

```python
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)
```

Rebuilt, redeployed, confirmed `requests` started returning data. Along the way, a copy-paste of the fix accidentally dropped the existing `credential = ManagedIdentityCredential(...)` line from the file, causing a `NameError` crash on the next deploy, caught immediately from the traceback, the missing line was restored and redeployed cleanly.

**Skill demonstrated:** not trusting documentation at face value when live behavior contradicts it, isolating the failure to a specific instrumentation hook rather than re-checking the whole pipeline from scratch, and catching a self-inflicted regression quickly by reading the traceback rather than assuming a new, unrelated bug.

## Issue 3: CLI extension blocked by a preview warning

**Symptom:** `az monitor app-insights component show` returned only a warning about a preview extension being disabled by default, no error, but no output either.

**Diagnosis:** the `application-insights` CLI extension is still in preview, so Azure CLI's automatic "install what's missing" behavior declines to install it without explicit permission, silently leaving the command's output variable empty rather than failing loudly.

**Resolution:**

```bash
az extension add --name application-insights
```

Installing explicitly rather than relying on auto-install resolved it immediately.

**Skill demonstrated:** recognizing that a warning with no error can still mean a command silently failed, worth verifying variables actually populated (`echo "$appInsightsId"`) rather than assuming a lack of an error message means success.

## Issue 4: designing alerts that don't cry wolf on low traffic

**Diagnosis:** early dashboard data showed the real shape of the problem: with only a handful of test requests in most time windows, a single failed request could spike the error-rate panel to 30-40%, and a single slow request could dominate a p95 calculation. A naive percentage-based threshold would fire constantly on statistically meaningless noise, exactly the "alerts that mean something" problem the CAI posting calls out directly.

**Resolution:** gated both alert queries on a minimum request volume before evaluating the actual threshold, so a small sample can't mathematically trigger either alert regardless of how extreme the percentage looks in isolation:

```kusto
requests
| where timestamp > ago(5m)
| summarize total = count(), errors = countif(success == false)
| where total >= 10
| extend error_rate_pct = round(100.0 * errors / total, 2)
| where error_rate_pct > 25
```

```kusto
requests
| where timestamp > ago(5m)
| summarize total = count(), p95 = percentile(duration, 95)
| where total >= 10
| where p95 > 500
```

Both built as Log Analytics scheduled query alerts (`az monitor scheduled-query create`), evaluating every 5 minutes over a trailing 5-minute window, routed through a new action group (`ag-homelab-alerts`) with email notification. The 500ms latency threshold was set against an observed normal baseline of roughly 90-125ms (p50/p95), giving 4-5x headroom above typical behavior. The dashboard itself was updated afterward with visual threshold lines matching both alert values, and a fourth panel showing raw request volume per bucket, so anyone reading the dashboard can see at a glance whether a spike happened on real traffic or on three requests total.

**Skill demonstrated:** designing alert logic around a known statistical failure mode (small-sample noise) rather than discovering it in production, and treating "the alert should stay quiet under normal conditions" as an equally important design requirement as "the alert should fire when something's wrong."

## Issue 5: proving the error-rate alert, including a false start that turned out to be correct behavior

**First test:** generated 13 requests (8 successful, 5 deliberate 404s). Checked the raw numbers over the full window instead of assuming: **76 total, 14 errors, 18.42%**. No alert fired.

**Diagnosis:** not a bug. The 5-minute evaluation window had absorbed unrelated concurrent traffic from an earlier latency test, diluting the deliberate failure burst below the 25% threshold. Filtering to just the intended test window confirmed it directly: **39 total, 3 errors, 7.96%**, genuinely below threshold, the alert was correct not to fire.

**Second test, run in isolation with a wider margin:** waited for a clean window, then sent 3 successful requests and 15 deliberate failures. Result: **17 total, 11 errors, 64.71%**. Alert fired, email received.

**Skill demonstrated:** validating both the true-positive and the true-negative case, rather than treating a first failed test as evidence of a broken alert. Recognizing test contamination from overlapping concurrent tests as a real methodology issue, and correcting it by isolating the test window rather than lowering the threshold to make the first result pass.

## Issue 6: the latency alert fired, but every obvious signal said it hadn't

**Symptom:** ran a 30-request concurrent burst against `/notes` to stress PgBouncer's connection pool. Manual query confirmed the condition was met (24 requests, p95 of 536ms, comfortably past the 500ms/10-request threshold), but no email arrived, even after waiting past the 5-minute evaluation cycle.

**Diagnosis, ruled out systematically rather than guessed:**
- Confirmed the rule was `enabled: true`, with the exact intended query and threshold in its `criteria`.
- Confirmed the action group was correctly attached under `actions`, matching the right resource ID.
- Checked the Azure portal's Alerts blade directly, the authoritative source for "did this actually fire," independent of email, and found the alert **had** fired.

That isolated the gap to specifically email delivery, not the alert logic. Given the rule, query, and action group were all independently confirmed correct, the most likely explanation was normal notification latency, possibly compounded by this being the action group's first-ever delivery. The email arrived shortly after.

**Skill demonstrated:** separating "did the detection logic work" from "did the notification deliver," two genuinely different failure domains that look identical from the outside (silence). Checking the portal's alert history as ground truth rather than treating email arrival as the only source of truth, and correctly identifying test data quality (531ms > 500) as sufficient evidence to keep investigating the notification path rather than the detection logic.

## What's next

With telemetry, a dashboard, and two validated alerts in place, the next lab extends this pattern to the pieces of the stack that don't have it yet, PgBouncer and Postgres itself currently have no equivalent visibility beyond what's been checked manually all session.