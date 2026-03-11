# gpu-rocm — AMD GPU Acceleration for Ollama

Enables AMD GPU acceleration for Ollama using ROCm/HIP.

## Prerequisites

Requires AMD GPU with ROCm support. Conflicts with `gpu-nvidia`.

## Enable

```bash
./module.sh enable gpu-rocm
```

## GPU Support Matrix

| Architecture | GPUs | ROCm Image | Notes |
|---|---|---|---|
| gfx1030 | RDNA 2 (RX 6000 series) | `rocm` | Native support |
| gfx1100–1102 | RDNA 3 (RX 7000 series) | `rocm` | Native support |
| gfx1151 | RDNA 4 iGPU (Radeon 8060S, Ryzen AI MAX) | `0.17.8-rc1-rocm` | ROCm 7.x required — see below |
| gfx1105 | RDNA 3 iGPU (Radeon 780M, 760M) | `0.17.8-rc1-rocm` | ROCm 7.x required — see below |

## gfx1151 / gfx1105 — ROCm 7.x Setup

The stable `ollama:rocm` tag ships ROCm 6.x, which does not support gfx1151 (RDNA 4) and crashes on load.
The installer auto-detects gfx1151 and pins `OLLAMA_IMAGE_TAG` to a ROCm 7.x build.

**After installation, set `num_gpu: 99` globally** to bypass Ollama's conservative iGPU memory
heuristic (which otherwise offloads only 1/49 layers to the GPU).

**Option A — Open WebUI (recommended):** applies to all models including newly pulled ones.

> Admin Panel → Settings → Models → Default Model Settings → Advanced Parameters → `num_gpu: 99`

**Option B — Ollama Modelfile:** required when using Ollama CLI or API directly without Open WebUI.
Repeat for each model:

```bash
docker exec ollama sh -c "
  ollama show <model> --modelfile > /tmp/mf.txt
  echo 'PARAMETER num_gpu 99' >> /tmp/mf.txt
  ollama create <model> -f /tmp/mf.txt
"
```

Replace `<model>` with the model name as shown in `ollama list` (e.g. `llama3.2:latest`).

**When to update `OLLAMA_IMAGE_TAG` back to `rocm`:** Once the stable `ollama:rocm` tag ships
ROCm 7.x, update `.env`:

```bash
OLLAMA_IMAGE_TAG="rocm"
```

Then run `docker compose up -d --force-recreate ollama`.

## Configuration

All variables are auto-detected by the installer. Manual overrides via `.env`:

| Variable | Default | Description |
|---|---|---|
| `OLLAMA_IMAGE_TAG` | `rocm` | Image tag — `0.17.8-rc1-rocm` for gfx1151 |
| `HIP_VISIBLE_DEVICES` | *(empty)* | `0` to enable GPU, `-1` to disable |
| `HSA_OVERRIDE_GFX_VERSION` | *(empty)* | ROCm arch override (e.g. `11.0.0`) |
| `OLLAMA_FLASH_ATTENTION` | *(empty)* | `true` to enable flash attention |

## Identifying your GPU

```bash
cat /sys/class/kfd/kfd/topology/nodes/1/properties | grep gfx_target_version
```

Format: `MMPPP` → e.g. `110501` = gfx1151 (RDNA 4)

## Disable

```bash
./module.sh disable gpu-rocm
```
