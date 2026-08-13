# Step 1: Create PostgreSQL Flexible Database in Azure
In the Azure portal, I created a PostgreSQL Flexible Server database called db-psqlflex-homelab with the following compute + storage settings:
- Basics
    - Burstable compute tier since this is for a test environment and I am trying to keep costs at a minimum     
        - general purpose was set to ~500-600/mo where-as burstable is down to 25-100/mo. 
    - PSQL Version 18
    - Dev/Test Workload type
    - Standard_B1ms (1vCore, 2 GiB memory, 640 max iops)
        - Since this is a private test environment, we can keep this as low as possible and can scale up when/if necessary.
    - Premium SSD (32 GiB size, 120 max iops P4 performance tier)
        - Only option available on the burstable compute tier.
        - Keeping size and performance to a minimum to be scaled up if necessary.
    - Zonal Resiliency disabled.
        - Since this is not a production workload, this is not necessary and will greatly reduce costs. For production workloads however I would recommend and enable this setting.
    - Backup retention 7 days
        - Minumum retention period. Not a real DB so no need to backup further than that.
    - Geo-redundancy off
        - Not needed for testing.
    - Authentication set to Entra ID authentication only
        - This is the most secure option. Since I am not transitioning or using any PostgreSQL DBs outside of azure, the native user/pass auth method does not feel necessary, however in such cases, a username and random password could be generated and stored in an Azure Key Vault for easy access to anyone with access to said key vault.
        - To grant admin access, I made a group called "Admins Group" and added myself to it, then set this group as the Entra ID admin so that only people who need admin access would be able to login to the PostgreSQL Flex DB.
- Networking
    - As discussed in issue 1 below, this is going to be on a Private Network (VNet integration) and will be in a NEW VNet that will be peered with our original.
    - Vnet "vnet-psqlflex-homelab" created for this purpose in the East US 2 region.
        - Address range set to 10.1.0.0/16 to avoid overlab with the original vnet
        - "snet-psqlflex-lab" range set to 10.1.0.0/24.
    - db-psqlflex-homelab.private.postgres.database.azure.com Prviate DNS zone created as required for the private access.
- Security settings left at default.

## Issue 1: Unable to Provision in East US
What a fun issue to start with. Due to subscription constraints (likely due to mine being a newer sub), I do have permissions from Microsoft to provision a PostgreSQL Flex DB in the East US region. This really only gives me 3 options:

### Option 1: File a Support Ticket
I could reach out to Microsoft to get this provisioning. But this would leave things out of my hands, and if that is not necessary, I would not want to do this. This would be my last resort option, especially considering Microsoft is likely dealing with a lot more high profile and paying customers and will definitely prioritize them over a single engineer doing an unpaid and low-paying project.

### Option 2: Move Everything to a Region I CAN Provision In
This is the most obvious answer I think. Due to constraints, I am sure many people would do this. In some environments, this may even be necessary. But I do not think this is necessary for ours. This could take me a while to recreate everything from session 1 and in the spirit of this lab I do not think is the best solution. In larger environments, due to cost, this may be the best solution, but since our environment here is so much smaller, I do not think cost needs to be taken into account at this time.

### Option 3: Peer a VNET in a Provisionable region to my existing East US VNET
I think this is the best answer for this situation. I can create a new VNET with its own delegated subnet in a new region I can provision in, peer it to the VNET we created in the last session, and the cost difference will be very low considering the size and scope of this lab.

I proceed with Option 3, and chose the East US 2 region since I could provision there and it was the next closest region to my original one.

# Step 2: Setup VNET Peerings and Confirm Connectivtiy
Setup the peering successfully. Kept all settings as default since this is a simple VNET to VNET peering and no gateways are needed nor is any traffic being forwarded.

After the peering succeeded, I added vnet-homelab to the Private DNS zone that was created during the DB creation to allow for hostname resolution.

In order to test the connection, I opened a shell on the lab-api container app using the below command and use the python command listed afterwards to test the connection. Since it is just a base image and does not have utilities like ping, curl, etc, I used Python directly to test this and found a small script that worked.

```bash
az containerapp exec --name lab-api --resource-group rg-homelab-msp --command sh
```

```python
# Once in the shell:
python3 -c "
import socket
host = 'db-psqlflex-homelab.postgres.database.azure.com'
port = 5432 #default postgresql port
ip = socket.gethostbyname(host)
print(f'Resolved {host} -> {ip}')
sock = socket.create_connection((host, port), timeout=5)
print('TCP connection succeeded')
sock.close()
"
```

Running the python command returned:
```
Resolved db-psqlflex-homelab.postgres.database.azure.com -> 10.1.0.4
TCP connection succeeded
```
This output proves that the peering was successful. Ready to move on to Step 3.

# Step 3: Connect the App to the PostgreSQL Flexibe Server Database
First things first, we need to add a driver to our lab-api app for postgres. My research shows the standard one is psycopg2-binary, especially for our use case of having minimum tools on our container image, so we will use that one. Added this to our requirements.txt file.

For authentication purposes, azure-identity has also been added as a requirement as it will be needed to acquire the tokens from the Entra ID login.

Next up, we'll edit our python app to add more endpoints for reading and writing that we can use for Postgres. I have created a managed identity id-postgres-auth for authentication since the DB only allows for Entra ID authentication, and this will allow for it to be passwordless and far more secure. Here is the new version of the app in its entirety:

```python
import os
import psycopg2
from fastapi import FastAPI
from azure.identity import ManagedIdentityCredential

app = FastAPI()

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

@app.on_event("startup")
def init_db():
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("""
        CREATE TABLE IF NOT EXISTS notes (
            id SERIAL PRIMARY KEY,
            content TEXT NOT NULL,
            created_at TIMESTAMPTZ DEFAULT now()
        );
    """)
    conn.commit()
    cur.close()
    conn.close()

@app.get("/health")
def health():
    return {"status": "ok"}

@app.post("/notes")
def create_note(content: str):
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("INSERT INTO notes (content) VALUES (%s) RETURNING id;", (content,))
    note_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()
    return {"id": note_id, "content": content}

@app.get("/notes")
def list_notes():
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("SELECT id, content, created_at FROM notes ORDER BY id DESC LIMIT 20;")
    rows = cur.fetchall()
    cur.close()
    conn.close()
    return [{"id": r[0], "content": r[1], "created_at": r[2].isoformat()} for r in rows]
```

Once the app was written and saved to my local git repo, I assigned the identity to the container app, pushed the new build with tag v3, and updated the app, with environment variables set to specifically be used by the python app in the get_connection portion of the script.

## Issue 1: Not Found Error
To test the new app and generate a table entry, my curl commands gave me a {"detail":"Not Found"} output. Looking this up shows it is a FastAPI response when there is no route matching the request. Checking my revisions, I found that even though I had attempted to build on v3, it got stuck on activating, indicating there may be an app startup failure. Checking through the logs, I see a password authentication failed for id-postgres-auth. This is because I missed a step above; I need to actually register the principal on the SQL server itself.

I attempted to connect to my DB using psql in an Azure Cloud shell, but now I get the following error:
```bash
psql: error: could not translate host name "db-psqlflex-homelab.postgres.database.azure.com" to address: Name or service not known
```
This is due to the cloud shell running in its own MSFT managed environment and is not on either of my VNETs. I can use my containerapp shell to do this, so I will do that and specifically target the last working revision. This ran into numerous issues while I needed to finish up setting up the PostgreSQL admin access, which to do I ended up needing to:

1. Generate a token from my user account and assign it to a PGPASSWORD variable to login using psql on my container app shell, authenticating with the "Admin Groups" group we used during creation. This was accomplished by running: 
```sh
PGPASSWORD="<fresh-token>" psql "host=<dbname>.database.azure.com port=5432 dbname=postgres user='Admins Group' sslmode=require"
```
2. Add the account as a prinicipal using its OID
```sql
SELECT * FROM pgaadauth_create_principal_with_oid(
  'id-postgres-auth',
  '<pgPrincipalId-value-here>',
  'service',
  false,
  false
);
```
3. Give it Create and Usage privileges
```sql
GRANT USAGE, CREATE ON SCHEMA public TO "id-postgres-auth";
```
4. Restart the failed revision

Once it was running, I set its traffic to 100% and reran the curl commands.
'''bash
curl -X POST "https://<your-fqdn>/notes?content=entra%20auth%20works"
curl "https://<your-fqdn>/notes"
'''
After running the first curl to add the "entra auth works" table entry, the 2nd curl command provided the output "{"id":1,"content":"entra auth works","created_at":"2026-08-13T05:10:53.683515+00:00"}"

# Step 4: Connection Pooling
While not needed for a small environment such as this home lab, in larger environments, this is something that will be essential for ensuring that apps don't fail due to exhausting its connections due to too many requests coming in. While usually, Azure has a PgBouncer built in to their PostgreSQL Flexible DB service, it is not available on the Burstable tier. This means I will need to stand one up myself. This will need to be an entirely new container app that will be a man-in-the-middle to catch all connections to the PostgreSQL database. I am going to set this up as a sidecar.

I created a new folder in my lab for the pgbouncer with an ini, dockerfile, and a refresh token script. Since we are only using the principals and no user/pass auth, with tokens refreshing themsleves on a schedule, we will need to refresh our token automatically so our bouncer doesn't break once the token changes.

I then updated the main app to point towards the pgbouncer rather than directly to the postgresql DB and built a new revision, lab-api:v4. pgbouncer was then pushed with the v1 tag to a new container, and I applied a yaml config for the updates since it will be needed going forward to update mutliple containers at once.

Once I got the app running with the connection pooling setup, I ran some curl commands to ensure the endpoints worked properly:

curl -X POST "https://<your-fqdn>/notes?content=pooled%20connection%20works"
curl "https://<your-fqdn>/notes"

This came back with a new entry in notes. In order to confirm pooling was happening properly, I did this multiple times and checked the server logs using psql. The data here confirmed that pooling was occurring properly.

## Issue 1: PgBouncer Failed to Start
Upon first applying the new yaml config, the new revision was failing to start. Logs showed that it was being run as root, causing a fatal error. I edited the docker file to ensure a non-root account is running this but was still getting failures, but the failures continued.

Logs now confirmed that PgBouncer was running, but there was some issues with the ini file and the refresh token script. The refreshs cript only ever wrote 1 line into the userlist.txt file that would be used on the pgb container, but it is overwriting it with the wrong username. Added to the script a way to write some local admin credentials as well as the refreshed token so that the internal psql command can use these local credentials (the connection will never leave this pod, so it can be a fixed password and does not matter.)

I also found that the ini was using id-postgres-auth as both the frontend AND backend username, but the frontend username was getting back "clienttoken" as the password rather than the actual client token. Removed the password from the [databases] section of the ini so that PgBouncer looks for it from userlist.txt itself to avoid any issues here. Added the fixed accounts to the refresh script, and updated the python app to use the app/clienttoken creds for connect. 

This still did not resolve my issue. I connected to a shell on my pgb container and checked userlist.txt myself. I comfirmed the 3 accounts were there (the 2 static creds and the token) and then tried to run the refresh script on my own. After comparing this to the logs of the container, the logic seems fine but there is a timing issue. PgBouncer is starting immediately but doesn't generate anything in the userlist.txt because the first curl to get the new token takes around a minute to run. To prevent cold starts crashing the app, I will need to change the refresh script to wait until we get the creds and token and update the userlist.txt file.

Updated the name of the script and updated the dockerfile as well to use it. After rebuilding and applying the YAML, it is now running.

HOWEVER, trying to shift traffic to the new running revision caused it to crash. Checking the logs, it looks like this is because the connection is not encrypted. Since we are on localhost, sslmode=require was no longer in use and PgBouncer needs to be setup to use TLS. Updated the ini to add server-side tls ssl, rebuilt, and applied new YAML. Finally, after all of this, the PgBouncer worked properly.

# Step 5: Backup and Restore
This part was relatively easy. After confirming that PITR was available to use, I added another note as a marker to ensure I could do a restore and ran a PITR via bash. Once the restore was completed, I checked that the note that I added was still in the restore and this confirms the restore succeeded. I then ran a cleanup command to clean up the restored server to avoid incurring additional costs.

```bash
az postgres flexible-server delete \
  --resource-group rg-homelab-msp \
  --name db-psqlflex-homelab-restoretest \
  --yes
```