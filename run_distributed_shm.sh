#!/bin/bash
set -e

# Run DS4 distributed inference across two local GPUs using Podman containers.
# Each container is pinned to one GPU via CUDA_VISIBLE_DEVICES.
# They communicate over the host network (localhost).

MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
COORD_PORT="${COORD_PORT:-12345}"
LAYERS_COORD="${LAYERS_COORD:-0:22}"
LAYERS_WORKER="${LAYERS_WORKER:-23:output}"
USE_SHM="${USE_SHM:-1}"
SHM_FLAG=""
if [ "${USE_SHM}" = "1" ]; then
    SHM_FLAG="--use-shm-transport"
fi

echo "=== DS4 Distributed Two-GPU Launch ==="
echo "  Model dir: ${MODEL_DIR}"
echo "  Coordinator layers: ${LAYERS_COORD}"
echo "  Worker layers:    ${LAYERS_WORKER}"
echo ""

# Verify we have two GPUs
GPU_COUNT=$(nvidia-smi -L | wc -l)
if [ "${GPU_COUNT}" -lt 2 ]; then
    echo "Error: This script requires 2 GPUs, but only ${GPU_COUNT} found."
    exit 1
fi

echo "Launching coordinator on GPU 1 (more free memory, no display overhead)..."
podman run -d --rm \
    --name ds4-coord \
    --network host \
    --device nvidia.com/gpu=1 \
    -e DS4_MODEL=/app/gguf/ds4flash.gguf \
    -v "${MODEL_DIR}:/app/gguf:Z" \
    ds4-cuda:shm \
    ./ds4-server \
        --host 0.0.0.0 \
        --port 8000 \
        -m /app/gguf/ds4flash.gguf \
        --role coordinator \
        --layers "${LAYERS_COORD}" \
        --listen 127.0.0.1 "${COORD_PORT}" \
        ${SHM_FLAG}

echo "Launching worker on GPU 0..."
podman run -d --rm \
    --name ds4-worker \
    --network host \
    --device nvidia.com/gpu=0 \
    -e DS4_MODEL=/app/gguf/ds4flash.gguf \
    -v "${MODEL_DIR}:/app/gguf:Z" \
    ds4-cuda:shm \
    ./ds4 \
        -m /app/gguf/ds4flash.gguf \
        --role worker \
        --layers "${LAYERS_WORKER}" \
        --coordinator 127.0.0.1 "${COORD_PORT}" \
        ${SHM_FLAG}

echo ""
echo "Both containers launched."
echo "  API server: http://localhost:8000"
echo ""
echo "Monitor logs:"
echo "  podman logs -f ds4-coord"
echo "  podman logs -f ds4-worker"
echo ""
echo "Stop both:"
echo "  podman stop ds4-coord ds4-worker"
