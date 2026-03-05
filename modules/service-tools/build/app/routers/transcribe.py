"""
Transcription Router

POST /transcribe - Accepts an audio file, splits it at pauses,
transcribes via Whisper API, and returns the assembled text.
"""

import os
import tempfile

from fastapi import APIRouter, File, Query, UploadFile, HTTPException

from app.scripts.audio_transcribe import transcribe_file

router = APIRouter()

CONFIG_PATH = os.environ.get(
    "TRANSCRIBE_CONFIG_PATH",
    os.path.join(os.path.dirname(__file__), "..", "..", "config.yaml"),
)


@router.post("/transcribe")
async def transcribe(
    file: UploadFile = File(..., description="Audiodatei (WAV, MP3, FLAC, OGG, ...)"),
    language: str = Query(default=None, description="Sprache erzwingen (z.B. 'de', 'en')"),
    response_format: str = Query(default=None, description="Whisper Response-Format (text, json)"),
):
    """
    Transkribiert eine Audiodatei über den Whisper-Server.

    Die Datei wird an Sprechpausen gesplittet, stückweise transkribiert
    und der Text zusammengesetzt zurückgegeben.
    """
    if not file.filename:
        raise HTTPException(status_code=400, detail="Keine Datei übermittelt.")

    # Build config overrides from query parameters
    overrides = {}
    whisper_overrides = {}
    if language is not None:
        whisper_overrides["language"] = language
    if response_format is not None:
        whisper_overrides["response_format"] = response_format
    if whisper_overrides:
        overrides["whisper"] = whisper_overrides

    # Save uploaded file to temp location
    suffix = os.path.splitext(file.filename)[1] or ".wav"
    with tempfile.NamedTemporaryFile(delete=False, suffix=suffix) as tmp:
        tmp.write(await file.read())
        tmp_path = tmp.name

    try:
        result = transcribe_file(
            input_path=tmp_path,
            config_path=CONFIG_PATH,
            config_overrides=overrides if overrides else None,
        )
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Transkription fehlgeschlagen: {e}")
    finally:
        os.unlink(tmp_path)

    return result
