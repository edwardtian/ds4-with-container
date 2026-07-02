#!/bin/bash
set -e

# Run DS4 distributed inference across two local GPUs using Podman containers.
# Each container is pinned to one host GPU. Inside that container CUDA sees the
# assigned GPU as device 0, so do not pass host CUDA_VISIBLE_DEVICES indices.
# They communicate over the host network (localhost).

CONTAINER_IMAGE="${CONTAINER_IMAGE:-ds4-cuda:latest}"
MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
DS4_MODEL="${DS4_MODEL:-/app/gguf/ds4flash.gguf}"
COORD_PORT="${COORD_PORT:-12345}"
COORD_GPU="${COORD_GPU:-1}"
WORKER_GPU="${WORKER_GPU:-0}"
LAYERS_COORD="${LAYERS_COORD:-0:22}"
LAYERS_WORKER="${LAYERS_WORKER:-23:42}"

if [ "${USE_SHM:-0}" = "1" ]; then
    echo "Error: USE_SHM=1 is not supported by this C build; --use-shm-transport is not implemented."
    echo "Use the default TCP transport."
    exit 2
fi

echo "=== DS4 Distributed Two-GPU Launch ==="
echo "  Model dir: ${MODEL_DIR}"
echo "  Image: ${CONTAINER_IMAGE}"
echo "  Coordinator GPU: ${COORD_GPU}"
echo "  Worker GPU:      ${WORKER_GPU}"
echo "  Coordinator layers: ${LAYERS_COORD}"
echo "  Worker layers:    ${LAYERS_WORKER}"
echo ""

if [ ! -d "${MODEL_DIR}" ]; then
    echo "Error: Model directory not found: ${MODEL_DIR}"
    echo "Set MODEL_DIR to the directory containing ds4flash.gguf."
    exit 1
fi

# Verify we have two GPUs
GPU_COUNT=$(nvidia-smi -L | wc -l)
if [ "${GPU_COUNT}" -lt 2 ]; then
    echo "Error: This script requires 2 GPUs, but only ${GPU_COUNT} found."
    exit 1
fi

# Stop any existing DS4 distributed containers first.
podman stop ds4-coord ds4-worker 2>/dev/null || true

echo "Launching coordinator on GPU ${COORD_GPU} (API + first layers + output head)..."
podman run -d --rm \
    --name ds4-coord \
    --network host \
    --ulimit memlock=-1:-1 \
    --device "nvidia.com/gpu=${COORD_GPU}" \
    -e "DS4_MODEL=${DS4_MODEL}" \
    -v "${MODEL_DIR}:/app/gguf:z" \
    "${CONTAINER_IMAGE}" \
    ./ds4-server \
        --host 0.0.0.0 \
        --port 8000 \
        -m "${DS4_MODEL}" \
        --role coordinator \
        --layers "${LAYERS_COORD}" \
        --listen 127.0.0.1 "${COORD_PORT}"

echo "Launching worker on GPU ${WORKER_GPU} (remaining transformer layers)..."
podman run -d --rm \
    --name ds4-worker \
    --network host \
    --ulimit memlock=-1:-1 \
    --device "nvidia.com/gpu=${WORKER_GPU}" \
    -e "DS4_MODEL=${DS4_MODEL}" \
    -v "${MODEL_DIR}:/app/gguf:z" \
    "${CONTAINER_IMAGE}" \
    ./ds4 \
        -m "${DS4_MODEL}" \
        --role worker \
        --layers "${LAYERS_WORKER}" \
        --coordinator 127.0.0.1 "${COORD_PORT}"

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
