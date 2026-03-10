# gpu-rocm — AMD GPU Acceleration for Ollama

Enables AMD GPU acceleration for Ollama using either ROCm/HIP or Vulkan compute backend.

## Prerequisites

Requires AMD GPU with ROCm or Vulkan support. Conflicts with `gpu-nvidia`.

## Enable

```bash
./module.sh enable gpu-rocm
```

## GPU Backends

### ROCm/HIP (default)

Works with well-supported AMD GPUs:

| Architecture | GPUs | Status |
|-------------|------|--------|
| gfx1030 | RDNA 2 (RX 6000 series) | Supported |
| gfx1100 | RDNA 3 (RX 7900 series) | Supported |
| gfx1101 | RDNA 3 (RX 7800/7700) | Supported |
| gfx1102 | RDNA 3 (RX 7600) | Supported |

Uses the `ollama/ollama:rocm` Docker image. Some GPUs may require `HSA_OVERRIDE_GFX_VERSION` to map to a supported architecture.

### Vulkan (recommended for gfx1151 / gfx1105)

The official `ollama:rocm` image lacks working HIP kernels for some GPUs. The Vulkan backend bypasses HIP entirely and works reliably on these GPUs.

| Architecture | GPUs | Status |
|-------------|------|--------|
| gfx1151 | RDNA 3.5 (Radeon 8060S, Ryzen AI MAX+ 395) | Vulkan recommended |
| gfx1105 | RDNA 3 iGPU (Ryzen 7840U/7940HS, 780M/760M) | Vulkan recommended |

Vulkan is actually **faster** than HIP on gfx1151 for prompt processing (~881 vs ~348 tok/s on 7B Q4_0 models). Token generation performance is comparable (~60 tok/s).

## Configuration

### ROCm/HIP mode

Add to `.env`:

```bash
# Optional: architecture override for unsupported GPUs
HSA_OVERRIDE_GFX_VERSION=11.0.0
```

### Vulkan mode (gfx1151 / gfx1105)

Add to `.env`:

```bash
# Switch to standard image (Vulkan does not need ROCm libraries)
OLLAMA_IMAGE_TAG=latest
# Enable Vulkan compute backend
OLLAMA_VULKAN=1
# Disable HIP to prevent runner crashes
HIP_VISIBLE_DEVICES=-1
```

### All variables

| Variable | Default | Description |
|----------|---------|-------------|
| `OLLAMA_IMAGE_TAG` | `rocm` | Docker image tag (`rocm` for HIP, `latest` for Vulkan) |
| `HSA_OVERRIDE_GFX_VERSION` | *(empty)* | ROCm architecture override (e.g. `11.0.0`) |
| `OLLAMA_VULKAN` | *(empty)* | Set to `1` to enable Vulkan backend |
| `HIP_VISIBLE_DEVICES` | *(empty)* | Set to `-1` to disable HIP (required for Vulkan on gfx1151) |
| `OLLAMA_FLASH_ATTENTION` | *(empty)* | Set to `false` to disable flash attention if needed |

## Identifying your GPU

```bash
# On the host (requires rocminfo)
rocminfo | grep gfx

# Or via lspci
lspci | grep -i vga
```

## Known issues

- **gfx1151 / gfx1105 + HIP**: Runner crashes or GPU not detected regardless of `HSA_OVERRIDE_GFX_VERSION` value. Use Vulkan mode instead (auto-detected by installer).
- **gfx1151 + ROCm 7.x**: Flash attention may cause bootstrap discovery failures. Set `OLLAMA_FLASH_ATTENTION=false` if using a custom ROCm image.

## Disable

```bash
./module.sh disable gpu-rocm
```
