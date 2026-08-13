---
layout: post
title: "Session 2: Postgres, cross-region peering, passwordless auth, and a PgBouncer sidecar from scratch"
date: 2026-08-13
---

Session 2 goal: attach a managed Postgres database to the Container App from Session 1, with private networking, passwordless authentication, connection pooling, and a verified backup/restore. Every one of those four things ran into something real. This is the longest and most technically dense session so far, worth reading if you want to see what actually breaks when you build infrastructure the way it's meant to be built rather than the fastest way to get something running.

## Setup: server configuration and reasoning

Created `db-psqlflex-homelab` as an Azure Database for PostgreSQL Flexible Server with the following, each choice deliberate rather than default:

- **Burstable compute tier (Standard_B1ms, 1 vCore, 2 GiB RAM)**: General Purpose priced out around $500-600/month for this workload profile. Minimum burstable specs brought that down to **$16.09/month**. A homelab with sporadic, low-volume traffic doesn't need sustained compute, burstable is built for exactly this shape of usage.
- **Zonal resiliency disabled**: no production traffic here, so paying for standby redundancy isn't justified. Documented as a decision, not an oversight, production workloads should have this enabled.
- **7-day backup retention, locally redundant (not geo-redundant)**: minimum retention, no cross-region backup replication. Nothing here is business-critical, geo-redundancy exists to survive a full regional outage, which isn't a risk profile this lab needs to protect against.
- **Microsoft Entra ID authentication only, native Postgres password auth disabled entirely**: the more secure option, and since nothing outside Azure needs to reach this database, there's no reason to maintain a parallel password-based auth path. Admin access is managed through an Entra group ("Admins Group") rather than individual accounts, so admin rights can be added or revoked by group membership, not by reconfiguring the database.

## Issue 1: subscription couldn't provision in East US

**Symptom:** selecting East US during server creation returned a subscription-not-allowed error for that region.

**Diagnosis:** newer Azure subscriptions can be capacity-restricted from provisioning certain resource types in certain regions, unrelated to quota or configuration, Azure manages this centrally based on regional capacity.

**Options considered:**

1. File a support ticket requesting region access, free, but not guaranteed and potentially slow.
2. Move the entire existing lab (VNet, Container Apps environment, everything from Session 1) to a region that does allow provisioning, guaranteed to work, but throws away working infrastructure for a lab-scale problem that doesn't justify the cost of redoing it.
3. Provision Postgres in a region that *does* allow it (East US 2), and connect it back to the existing East US infrastructure via VNet peering.

**Resolution:** Option 3. Created `vnet-psqlflex-homelab` (`10.1.0.0/16`, non-overlapping with the original `10.0.0.0/16`) in East US 2, with a delegated `snet-psqlflex-lab` subnet, then peered it to `vnet-homelab` in East US.

**Skill demonstrated:** evaluating infrastructure trade-offs by actual cost and effort rather than defaulting to the "just move everything" answer, and recognizing when a small architectural addition (peering) is cheaper than redoing working infrastructure.

## Issue 2: confirming peering actually worked

**Resolution, not just an issue:** rather than trust the peering status alone, verified real connectivity from inside the actual network path the app would use. Since the base container image has no `ping`, `curl`, or `nslookup`, tested via Python's standard library directly from an `az containerapp exec` shell into `lab-api`:

```python
import socket
host = 'db-psqlflex-homelab.postgres.database.azure.com'
port = 5432
ip = socket.gethostbyname(host)
print(f'Resolved {host} -> {ip}')
sock = socket.create_connection((host, port), timeout=5)
print('TCP connection succeeded')
sock.close()
```

Output:

```
Resolved db-psqlflex-homelab.postgres.database.azure.com -> 10.1.0.4
TCP connection succeeded
```

This confirms two separate things in one test: DNS resolution (meaning the Private DNS zone was correctly linked to both VNets, not just the one Postgres lives in) and the actual TCP path (meaning peering and NSG rules were correctly routing traffic). A "Connected" peering status alone wouldn't have proven either.

## Issue 3: connecting the app with Entra ID authentication

Added `psycopg2-binary` for the Postgres driver and `azure-identity` for token acquisition. The app requests a token via `ManagedIdentityCredential`, using it as the password field on connect, no stored credential anywhere:

```python
credential = ManagedIdentityCredential(client_id=os.environ["PG_IDENTITY_CLIENT_ID"])

def get_connection():
    token = credential.get_token("https://ossrdbms-aad.database.windows.net/.default")
    return psycopg2.connect(
        host=os.environ["DB_HOST"],
        dbname=os.environ["DB_NAME"],
        user=os.environ["DB_USER"],
        password=token.token,
        sslmode="require",
    )
```

**Symptom:** `{"detail":"Not Found"}` on both test endpoints after deploying.

**Diagnosis:** `Not Found` is FastAPI's own 404, meaning the deployed revision didn't actually have the new routes running. Checking revisions showed the new one stuck in `Activating`, never receiving traffic, container logs showed the real error underneath: `password authentication failed for user "id-postgres-auth"`. The managed identity had never been registered as a Postgres role at all.

**Complication:** Azure Cloud Shell couldn't reach the database to fix this (`could not translate host name... Name or service not known`), Cloud Shell runs outside both VNets entirely, so it has no path to a privately-networked server. Used the same `az containerapp exec` shell into `lab-api` instead, installing `postgresql-client` temporarily to get `psql`.

**Resolution, in order:**

1. Authenticated as an individual Entra user first, discovered the Postgres Entra Administrator was actually an Entra **group** ("Admins Group"), not an individual account, connecting as a group member requires the group's display name as the username, with your own individual token as the password:

```bash
PGPASSWORD="<fresh-token>" psql "host=db-psqlflex-homelab.postgres.database.azure.com port=5432 dbname=postgres user='Admins Group' sslmode=require"
```

2. Registered the managed identity explicitly by Object ID rather than by name, name-based registration (`pgaadauth_create_principal`) can silently resolve to a mismatched internal reference for service principals, using the OID directly removes that ambiguity:

```sql
SELECT * FROM pgaadauth_create_principal_with_oid(
  'id-postgres-auth',
  '<pgPrincipalId-value-here>',
  'service',
  false,
  false
);
```

3. Granted schema privileges, since Postgres 15+ no longer grants `CREATE` on the `public` schema to new roles by default:

```sql
GRANT USAGE, CREATE ON SCHEMA public TO "id-postgres-auth";
```

4. Restarted the stuck revision, shifted traffic to 100%, and confirmed:

```bash
curl -X POST "https://<fqdn>/notes?content=entra%20auth%20works"
curl "https://<fqdn>/notes"
```

```json
{"id":1,"content":"entra auth works","created_at":"2026-08-13T05:10:53.683515+00:00"}
```

**Skill demonstrated:** methodically isolating a vague authentication failure across three genuinely different root causes (missing principal registration, a name-resolution ambiguity specific to service principals, and an unrelated Postgres version-level permission default) rather than assuming the first fix would resolve everything.

## Issue 4: connection pooling with a self-built PgBouncer sidecar

Azure's built-in PgBouncer only supports General Purpose and Memory Optimized tiers, not Burstable, the tier chosen for cost. Rather than upgrade tiers just to get pooling, deployed PgBouncer as a sidecar container in the same Container Apps revision, sharing the pod's network namespace with `lab-api` over `localhost`.

**Sub-issue: ran as root.** PgBouncer refuses to start as root by default. Fixed by creating a dedicated non-root system user in the Dockerfile and switching to it before the process starts.

**Sub-issue: incomplete credential file.** The token-refresh script only ever wrote one line to `userlist.txt`, the refreshed Entra token, overwriting the file each cycle. `admin_users = admin` in the PgBouncer config had no matching entry, so the script's own `RELOAD` command failed every cycle with `no such user: admin`. Fixed by writing all required entries together on every refresh cycle instead of just one.

**Sub-issue: frontend/backend username collision.** The app was connecting to PgBouncer's frontend using the same username (`id-postgres-auth`) that PgBouncer needed for the real backend connection to Postgres, but sending the wrong password for that context (a static string instead of the real token). Fixed by decoupling the two entirely: the `[databases]` block in `pgbouncer.ini` now hardcodes `user=id-postgres-auth` for the backend connection and looks its password up from `userlist.txt` itself, while the app connects to the frontend using a separate, purely local username/password pair that never touches real Postgres or Entra ID.

**Sub-issue: startup race condition.** Even with correct credentials, the app would still see connection failures for the first ~30-60 seconds after a fresh replica started. The managed identity token endpoint takes a noticeable, variable amount of time to become available on a cold container start, and the original script backgrounded the token fetch and started PgBouncer simultaneously, a race. Fixed by making the first token fetch and file write run synchronously, blocking, before PgBouncer starts at all, only subsequent refreshes run in a background loop.

**Sub-issue: unencrypted backend connection.** Once PgBouncer was reliably starting with correct credentials, connections still failed: `no pg_hba.conf entry for host... no encryption`. The app's own `sslmode="require"` only ever applied to its original direct connection to Postgres, once PgBouncer sits in the middle, *it* becomes the thing talking to Postgres, and PgBouncer has a separate setting for that hop. Fixed by adding `server_tls_sslmode = require` to `pgbouncer.ini`, distinct from the (deliberately unencrypted, since it's localhost-only) frontend setting.

**Proof pooling actually works, not just that the app didn't crash:**

```sql
SHOW STATS;
```

```
 database  | total_xact_count | total_query_count | ...
 postgres  |               13 |                38 | ...
```

```sql
SHOW SERVERS;
```

```
 type |       user       | database | state | addr     | port | ... |              tls               
 S    | id-postgres-auth | postgres | used  | 10.1.0.4 | 5432 | ... | TLSv1.3/TLS_AES_256_GCM_SHA384
(1 row)
```

13 transactions and 38 queries, all served through a single backend connection to Postgres. Without pooling, that would have been 13 separate connection lifecycles, each with its own TCP handshake, TLS negotiation, and Entra token validation.

**Skill demonstrated:** six genuinely distinct problems across container security defaults, credential file completeness, authentication scoping, distributed systems startup ordering, and network encryption policy, all diagnosed from log output and verified with real state rather than assumption at each step.

## Issue 5: backup and restore, actually verified

Point-in-time restore is available by default. To prove it works rather than trust the toggle, ran an actual restore drill:

1. Inserted a distinctive, identifiable marker row so the restore could be verified against a known value, not just "some data exists":

```sql
INSERT INTO notes (content) VALUES ('RESTORE-DRILL-MARKER before restore test');
```

2. Captured the exact UTC timestamp immediately after.

3. Restored to a **new** server, Postgres Flexible Server doesn't support in-place restore, every restore creates a fresh server alongside the original, which keeps running undisturbed:

```bash
az postgres flexible-server restore \
  --resource-group rg-homelab-msp \
  --name db-psqlflex-homelab-restoretest \
  --source-server db-psqlflex-homelab \
  --restore-time "<timestamp>"
```

4. Connected directly to the new server on port 5432 (bypassing PgBouncer entirely, since its config only knows about the original server's hostname) and confirmed:

```sql
SELECT * FROM notes WHERE content LIKE 'RESTORE-DRILL%';
```

```
 id |                 content                  |          created_at           
----+------------------------------------------+-------------------------------
 13 | RESTORE-DRILL-MARKER before restore test | 2026-08-13 06:28:24.319038+00
(1 row)
```

5. Deleted the restored test server immediately after confirming, a second Postgres server bills independently, no reason to leave it running once verified.

**Skill demonstrated:** treating "backup enabled" and "restore verified" as two separate claims, and designing a test specific enough (a timestamped marker, not just "does data exist") to actually prove the second one.

## What's next

Session 3 moves into observability: Azure Monitor, Application Insights, and at least one alert threshold deliberately chosen and validated by breaking something on purpose, not left at a default.