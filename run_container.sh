#!/bin/bash
set -e

# Run the DwarfStar DS4 Podman container
# Mounts the local gguf/ directory so models are reused.

MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
DS4_MODEL="${DS4_MODEL:-/app/gguf/ds4flash.gguf}"
GPU_ID="${GPU_ID:-all}"

echo "Running ds4-cuda container..."
echo "  Model directory: ${MODEL_DIR}"
echo "  DS4_MODEL: ${DS4_MODEL}"
echo "  GPU: ${GPU_ID}"

# Check if model directory exists
if [ ! -d "${MODEL_DIR}" ]; then
    echo "Warning: Model directory not found: ${MODEL_DIR}"
    echo "Set MODEL_DIR to the directory containing your .gguf files."
fi

# When a specific GPU is passed via --device, it appears as device 0 inside the
# container, so CUDA_VISIBLE_DEVICES must be 0 (or unset).  Only when *all*
# GPUs are mounted do we preserve the host-visible indices.
if [ "${GPU_ID}" = "all" ]; then
    CUDA_DEV="all"
else
    CUDA_DEV="0"
fi

# Run with GPU access, mounting the model directory and exposing ports
podman run -it --rm \
    --device "nvidia.com/gpu=${GPU_ID}" \
    -e "CUDA_VISIBLE_DEVICES=${CUDA_DEV}" \
    -v "${MODEL_DIR}:/app/gguf:Z" \
    -e "DS4_MODEL=${DS4_MODEL}" \
    -p 8000:8000 \
    -p 9333:9333 \
    ds4-cuda:latest \
    "$@"
