"""
Service Tools - FastAPI Application

Reusable HTTP API service tools for ancroo-stack.
"""

from fastapi import FastAPI

from app.routers import transcribe

app = FastAPI(
    title="Service Tools",
    description="Reusable HTTP API service tools (transcription, ...)",
    version="1.0.0",
)

app.include_router(transcribe.router)


@app.get("/health")
def health():
    return {"status": "ok"}
