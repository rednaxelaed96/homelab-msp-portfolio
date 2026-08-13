import os
import psycopg2
from fastapi import FastAPI
from azure.identity import ManagedIdentityCredential

app = FastAPI()

credential = ManagedIdentityCredential(client_id=os.environ["PG_IDENTITY_CLIENT_ID"])

def get_connection():
    return psycopg2.connect(
        host="localhost",
        port=6432,
        dbname="postgres",
        user="app",
        password="clienttoken",
        sslmode="disable",
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