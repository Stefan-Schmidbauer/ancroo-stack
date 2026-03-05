# service-tools — Reusable HTTP API Service Tools

FastAPI-based HTTP API that provides reusable service tools for the Ancroo Stack. Currently includes audio transcription via the speaches module. Additional endpoints can be added as needed.

## Prerequisites

Requires the speaches module (auto-enabled as dependency).

## Enable

```bash
./module.sh enable service-tools
# Auto-enables: speaches
```

## Access

| Mode | URL |
|------|-----|
| Base | `http://<IP>:8500` |

Health check: `http://<IP>:8500/health`

## Endpoints

### POST /transcribe

Accepts an audio file, splits it at speech pauses, transcribes each chunk via the Whisper API (speaches), and returns the assembled text.

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| file | Upload | Yes | Audio file (WAV, MP3, FLAC, OGG, ...) |
| language | string | No | Force language (e.g. `de`, `en`) |
| response_format | string | No | Whisper response format (`text`, `json`) |

**Example:**

```bash
curl -X POST http://service-tools:8500/transcribe \
  -F "file=@recording.wav" \
  -F "language=de"
```

**Response:**

```json
{
  "text": "Transcribed text...",
  "duration_s": 45.2,
  "chunks_count": 3
}
```

The service is accessible from any HTTP client within the Docker network — n8n workflows, Ancroo, curl, or any other service on `ai-network`.

## Disable

```bash
./module.sh disable service-tools
# Then optionally: ./module.sh disable speaches
```
