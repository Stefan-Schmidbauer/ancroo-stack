"""Minimal Whisper ROCm Server — OpenAI-compatible Speech-to-Text API."""

import io
import logging
import os
from contextlib import asynccontextmanager

import numpy as np
import soundfile as sf
import torch
import uvicorn
from fastapi import FastAPI, File, Form, UploadFile
from transformers import pipeline as hf_pipeline

logger = logging.getLogger("whisper-rocm")

MODEL = os.getenv("WHISPER_MODEL", "openai/whisper-large-v3-turbo")
HOST = os.getenv("HOST", "0.0.0.0")
PORT = int(os.getenv("PORT", "8000"))

pipe = None


@asynccontextmanager
async def lifespan(app: FastAPI):
    global pipe
    device = "cuda" if torch.cuda.is_available() else "cpu"
    dtype = torch.float16 if device == "cuda" else torch.float32
    print(f"Loading model {MODEL} on {device} ...")
    if device == "cuda":
        print(f"  GPU: {torch.cuda.get_device_name(0)}")
    pipe = hf_pipeline(
        "automatic-speech-recognition",
        model=MODEL,
        dtype=dtype,
        device=device,
    )
    print("Model ready.")
    yield
    del pipe


app = FastAPI(title="Whisper ROCm", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/v1/models")
def models():
    return {
        "object": "list",
        "data": [{"id": MODEL, "object": "model", "owned_by": "openai"}],
    }


@app.post("/v1/audio/transcriptions")
async def transcribe(
    file: UploadFile = File(...),
    language: str = Form(None),
    model: str = Form(None),
):
    if model and model != MODEL:
        logger.warning(
            "Requested model %r differs from loaded model %r — using loaded model",
            model, MODEL,
        )

    audio_bytes = await file.read()
    audio_np, sample_rate = sf.read(io.BytesIO(audio_bytes))
    if audio_np.ndim > 1:
        audio_np = audio_np.mean(axis=1)
    audio_np = audio_np.astype(np.float32)

    generate_kwargs = {}
    if language and language.lower() != "none":
        generate_kwargs["language"] = language

    result = pipe(
        {"raw": audio_np, "sampling_rate": sample_rate},
        chunk_length_s=30,
        batch_size=16,
        generate_kwargs=generate_kwargs,
    )
    return {"text": result["text"].strip(), "model": MODEL}


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT)
