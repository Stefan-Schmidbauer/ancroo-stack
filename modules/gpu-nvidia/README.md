# gpu-nvidia — NVIDIA CUDA GPU Acceleration

Enables NVIDIA GPU acceleration for Ollama using the CUDA runtime. This is an infrastructure module set during installation.

## Setup

GPU mode is selected during `install.sh`. To switch GPU mode, reinstall:

```bash
bash install.sh
# Select: NVIDIA
```

## Requirements

- NVIDIA GPU with CUDA support
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html) installed on the host

## What It Does

Adds NVIDIA device reservation to the Ollama container:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

## Conflicts

Cannot be used together with `gpu-rocm`. Only one GPU module can be active.

## STT Module

For NVIDIA-accelerated speech-to-text, use the `speaches` module:

```bash
./module.sh enable speaches
```
