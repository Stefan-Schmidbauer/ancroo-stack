# whisper-rocm — Speech-to-Text (AMD GPU)

Speech-to-text service optimized for AMD GPUs via ROCm. Provides an OpenAI-compatible transcription API.

## Prerequisites

Requires AMD GPU with ROCm support. Only available when installed with `GPU_MODE="rocm"`.

## Enable

```bash
./module.sh enable whisper-rocm
```

## Access

| Mode | URL |
|------|-----|
| Base | `http://<IP>:8002` |
| SSL | `https://whisper.<BASE_DOMAIN>` |

API docs: `http://<IP>:8002/docs`

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `WHISPER_ROCM_PORT` | `8002` | Service port |
| `WHISPER_ROCM_MODEL` | `large-v3` | Whisper model |

Recommended model: `openai/whisper-large-v3-turbo` — roughly 3x faster than `large-v3` with comparable accuracy.

## Disable

```bash
./module.sh disable whisper-rocm
```
