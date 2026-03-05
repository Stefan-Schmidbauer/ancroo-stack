"""
Audio Transcription Module

Splits audio files at speech pauses, transcribes each chunk via a
Whisper-compatible API server, and reassembles the text.

Refactored from whisper_transcribe.py for use as both a library and CLI tool.
"""

import os
import sys
import tempfile
from pathlib import Path

import requests
import urllib3
import yaml
from pydub import AudioSegment
from pydub.silence import split_on_silence


DEFAULT_CONFIG = {
    "server": {
        "url": "http://speaches:8000/v1/audio/transcriptions",
        "token": "",
        "disable_ssl_verify": False,
    },
    "whisper": {
        "language": "de",
        "model": "",
        "response_format": "text",
    },
    "splitting": {
        "min_silence_duration_ms": 700,
        "silence_threshold_dbfs": -40,
        "min_chunk_duration_s": 20,
        "max_chunk_duration_s": 120,
        "overlap_ms": 200,
    },
}


def load_config(config_path: str) -> dict:
    """Load YAML config file and return as dict with defaults."""
    defaults = {
        section: dict(values) for section, values in DEFAULT_CONFIG.items()
    }

    if not os.path.exists(config_path):
        print(f"Warnung: Config-Datei '{config_path}' nicht gefunden, verwende Defaults.")
        return defaults

    with open(config_path, "r", encoding="utf-8") as f:
        user_config = yaml.safe_load(f) or {}

    for section in defaults:
        if section in user_config and isinstance(user_config[section], dict):
            defaults[section].update(
                {k: v for k, v in user_config[section].items() if v is not None}
            )

    return defaults


def split_audio(audio: AudioSegment, config: dict) -> list[AudioSegment]:
    """Split audio on silence, merge small chunks, enforce max duration."""
    split_cfg = config["splitting"]

    chunks = split_on_silence(
        audio,
        min_silence_len=split_cfg["min_silence_duration_ms"],
        silence_thresh=split_cfg["silence_threshold_dbfs"],
        keep_silence=300,
    )

    if not chunks:
        chunks = [audio]

    # Merge small chunks until they reach min_chunk_duration
    min_ms = split_cfg["min_chunk_duration_s"] * 1000
    max_ms = split_cfg["max_chunk_duration_s"] * 1000
    merged = []
    current = chunks[0]
    for chunk in chunks[1:]:
        combined = current + chunk
        if len(current) < min_ms and len(combined) <= max_ms:
            current = combined
        else:
            merged.append(current)
            current = chunk
    merged.append(current)

    # Force-split any chunks that exceed max duration
    final_chunks = []
    for chunk in merged:
        if len(chunk) > max_ms:
            for i in range(0, len(chunk), max_ms):
                final_chunks.append(chunk[i : i + max_ms])
        else:
            final_chunks.append(chunk)

    # Apply overlap
    overlap_ms = split_cfg["overlap_ms"]
    if overlap_ms > 0 and len(final_chunks) > 1:
        overlapped = [final_chunks[0]]
        for i in range(1, len(final_chunks)):
            prev_tail = final_chunks[i - 1][-overlap_ms:]
            overlapped.append(prev_tail + final_chunks[i])
        final_chunks = overlapped

    return final_chunks


def transcribe_chunk(
    chunk: AudioSegment, chunk_index: int, total: int, config: dict, tmpdir: str
) -> str:
    """Export chunk to file and send to Whisper API. Returns transcribed text."""
    server_cfg = config["server"]
    whisper_cfg = config["whisper"]

    chunk_path = os.path.join(tmpdir, f"chunk_{chunk_index:04d}.wav")
    chunk.export(chunk_path, format="wav")

    headers = {}
    if server_cfg["token"]:
        headers["Authorization"] = f"Bearer {server_cfg['token']}"

    data = {}
    if whisper_cfg["language"]:
        data["language"] = whisper_cfg["language"]
    if whisper_cfg["model"]:
        data["model"] = whisper_cfg["model"]
    if whisper_cfg["response_format"]:
        data["response_format"] = whisper_cfg["response_format"]

    verify_ssl = not server_cfg["disable_ssl_verify"]

    with open(chunk_path, "rb") as audio_file:
        files = {"file": (f"chunk_{chunk_index:04d}.wav", audio_file, "audio/wav")}

        try:
            response = requests.post(
                server_cfg["url"],
                headers=headers,
                data=data,
                files=files,
                verify=verify_ssl,
                timeout=300,
            )
            response.raise_for_status()
        except requests.RequestException as e:
            print(f"  Fehler bei Chunk {chunk_index + 1}/{total}: {e}", file=sys.stderr)
            return ""

    if whisper_cfg["response_format"] == "text":
        return response.text.strip()
    else:
        try:
            result = response.json()
            return result.get("text", "").strip()
        except (ValueError, KeyError):
            return response.text.strip()


def transcribe_file(
    input_path: str,
    config_path: str | None = None,
    config_overrides: dict | None = None,
) -> dict:
    """
    Transcribe an audio file end-to-end.

    Args:
        input_path: Path to the audio file.
        config_path: Path to YAML config. Uses defaults if None.
        config_overrides: Dict to override config values, e.g.
                          {"whisper": {"language": "en"}}

    Returns:
        Dict with keys: text, duration_s, chunks_count
    """
    # Load config
    if config_path:
        config = load_config(config_path)
    else:
        config = {section: dict(values) for section, values in DEFAULT_CONFIG.items()}

    # Apply overrides
    if config_overrides:
        for section, values in config_overrides.items():
            if section in config and isinstance(values, dict):
                config[section].update(
                    {k: v for k, v in values.items() if v is not None}
                )

    # Suppress SSL warnings if verify is disabled
    if config["server"]["disable_ssl_verify"]:
        urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

    # Load audio
    audio = AudioSegment.from_file(input_path)
    duration_s = len(audio) / 1000

    # Split audio
    chunks = split_audio(audio, config)
    print(f"Audio geladen: {duration_s:.1f}s, {len(chunks)} Stück(e) erstellt.")

    # Transcribe each chunk
    texts = []
    with tempfile.TemporaryDirectory() as tmpdir:
        for i, chunk in enumerate(chunks):
            chunk_dur = len(chunk) / 1000
            print(f"  Transkribiere Stück {i + 1}/{len(chunks)} ({chunk_dur:.1f}s)...")
            text = transcribe_chunk(chunk, i, len(chunks), config, tmpdir)
            if text:
                texts.append(text)

    final_text = " ".join(texts)

    return {
        "text": final_text,
        "duration_s": round(duration_s, 1),
        "chunks_count": len(chunks),
    }


# CLI entry point for standalone usage
if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(
        description="Transkribiert Audiodateien über einen Whisper-Server."
    )
    parser.add_argument("input", help="Pfad zur Audio-Eingabedatei")
    parser.add_argument("-o", "--output", help="Pfad zur Ausgabedatei")
    parser.add_argument(
        "-c", "--config",
        default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "config.yaml"),
        help="Pfad zur Config-Datei",
    )

    args = parser.parse_args()

    if not os.path.isfile(args.input):
        print(f"Fehler: Eingabedatei '{args.input}' nicht gefunden.", file=sys.stderr)
        sys.exit(1)

    result = transcribe_file(args.input, config_path=args.config)

    output_path = args.output or os.path.join(os.getcwd(), f"{Path(args.input).stem}.txt")
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(result["text"])
        f.write("\n")

    word_count = len(result["text"].split())
    print(f"\nFertig! {word_count} Wörter geschrieben nach: {output_path}")
