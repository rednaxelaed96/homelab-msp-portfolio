from fastapi import FastAPI
import time

app = FastAPI()

@app.get("/health")
def health():
    return {"status": "ok"}

@app.get("/version")
def version():
    return {"version": "2.0.0", "timestamp": time.time()}