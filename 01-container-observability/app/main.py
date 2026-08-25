import os
import time
import psycopg2
from fastapi import FastAPI
from azure.identity import ManagedIdentityCredential
from azure.monitor.opentelemetry import configure_azure_monitor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry import metrics
from redis import Redis
from redis_entraid.cred_provider import create_from_managed_identity, ManagedIdentityType, ManagedIdentityIdType

configure_azure_monitor(
    connection_string=os.environ["APPLICATIONINSIGHTS_CONNECTION_STRING"]
)

app = FastAPI()
FastAPIInstrumentor.instrument_app(app)

credential = ManagedIdentityCredential(client_id=os.environ["PG_IDENTITY_CLIENT_ID"])

meter = metrics.get_meter("lab-api")
token_duration_histogram = meter.create_histogram(
    "entra_token_acquisition_duration_ms",
    unit="ms",
    description="Time to acquire an Entra ID token for Postgres authentication",
)

notes_duration_histogram = meter.create_histogram(
    "notes_fetch_duration_ms",
    unit="ms",
    description="Time to serve GET /notes, tagged by cache hit or miss",
)

redis_credential_provider = create_from_managed_identity(
    identity_type=ManagedIdentityType.USER_ASSIGNED,
    resource="https://redis.azure.com/",
    id_type=ManagedIdentityIdType.CLIENT_ID,
    id_value=os.environ["REDIS_IDENTITY_CLIENT_ID"],
)

redis_client = Redis(
    host=os.environ["REDIS_HOST"],
    port=10000,
    ssl=True,
    credential_provider=redis_credential_provider,
)

def get_connection():
    start = time.monotonic()
    success = True
    try:
        token = credential.get_token("https://ossrdbms-aad.database.windows.net/.default")
    except Exception:
        success = False
        raise
    finally:
        duration_ms = (time.monotonic() - start) * 1000
        token_duration_histogram.record(duration_ms, {"success": str(success)})

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

CACHE_TTL_SECONDS = 30

@app.get("/notes")
def list_notes():
    start = time.monotonic()
    cached = redis_client.get("notes:latest")
    if cached:
        duration_ms = (time.monotonic() - start) * 1000
        notes_duration_histogram.record(duration_ms, {"cache_hit": "true"})
        return json.loads(cached)

    conn = get_connection()
    cur = conn.cursor()
    cur.execute("SELECT id, content, created_at FROM notes ORDER BY id DESC LIMIT 20;")
    rows = cur.fetchall()
    cur.close()
    conn.close()

    result = [{"id": r[0], "content": r[1], "created_at": r[2].isoformat()} for r in rows]
    redis_client.setex("notes:latest", CACHE_TTL_SECONDS, json.dumps(result))

    duration_ms = (time.monotonic() - start) * 1000
    notes_duration_histogram.record(duration_ms, {"cache_hit": "false"})
    return result

@app.post("/notes")
def create_note(content: str):
    conn = get_connection()
    cur = conn.cursor()
    cur.execute("INSERT INTO notes (content) VALUES (%s) RETURNING id;", (content,))
    note_id = cur.fetchone()[0]
    conn.commit()
    cur.close()
    conn.close()

    redis_client.delete("notes:latest")
    return {"id": note_id, "content": content}