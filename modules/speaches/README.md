# speaches — Speech-to-Text (Whisper)

GPU-accelerated speech-to-text service based on OpenAI Whisper. Provides an OpenAI-compatible transcription API.

## Enable

```bash
./module.sh enable speaches
```

## Access

| Mode | URL |
|------|-----|
| Base | `http://<IP>:8100` |
| SSL | `https://speaches.<BASE_DOMAIN>` |

API docs: `http://<IP>:8100/docs`

## GPU Acceleration

| GPU Mode | Image | Performance |
|----------|-------|-------------|
| NVIDIA | `speaches:latest-cuda` | Fast (GPU-accelerated) |
| CPU | `speaches:latest` | Slower |

With NVIDIA, the GPU overlay is automatically applied.

Not compatible with AMD ROCm — use [whisper-rocm](../whisper-rocm/README.md) instead.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SPEACHES_PORT` | `8100` | Service port |
| `SPEACHES_MODEL_SIZE` | `large-v3` | Whisper model size |

## API Usage

```bash
curl -X POST http://<IP>:8100/v1/audio/transcriptions \
  -F "file=@audio.wav" \
  -F "model=whisper-1"
```

## Disable

```bash
./module.sh disable speaches
```
