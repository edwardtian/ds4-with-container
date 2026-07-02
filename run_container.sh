#!/bin/bash
set -e

# Run the DwarfStar DS4 Podman container
# Mounts the local gguf/ directory so models are reused.

MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
DS4_MODEL="${DS4_MODEL:-/app/gguf/ds4flash.gguf}"
GPU_ID="${GPU_ID:-all}"
CONTAINER_IMAGE="${CONTAINER_IMAGE:-ds4-cuda:latest}"

echo "Running ds4-cuda container..."
echo "  Model directory: ${MODEL_DIR}"
echo "  DS4_MODEL: ${DS4_MODEL}"
echo "  GPU: ${GPU_ID}"
echo "  Image: ${CONTAINER_IMAGE}"

# Check if model directory exists
if [ ! -d "${MODEL_DIR}" ]; then
    echo "Error: Model directory not found: ${MODEL_DIR}"
    echo "Set MODEL_DIR to the directory containing your .gguf files."
    exit 1
fi

# When a specific GPU is passed via --device, it appears as device 0 inside the
# container, so CUDA_VISIBLE_DEVICES must be 0. When all GPUs are mounted, leave
# CUDA_VISIBLE_DEVICES unset; "all" is an NVIDIA_VISIBLE_DEVICES value, not a
# CUDA_VISIBLE_DEVICES value.
CUDA_ENV=()
if [ "${GPU_ID}" != "all" ]; then
    CUDA_ENV=(-e "CUDA_VISIBLE_DEVICES=0")
fi

# Run with GPU access, mounting the model directory and exposing ports
podman run -it --rm \
    --ulimit memlock=-1:-1 \
    --device "nvidia.com/gpu=${GPU_ID}" \
    "${CUDA_ENV[@]}" \
    -v "${MODEL_DIR}:/app/gguf:z" \
    -e "DS4_MODEL=${DS4_MODEL}" \
    -p 8000:8000 \
    -p 9333:9333 \
    "${CONTAINER_IMAGE}" \
    "$@"
