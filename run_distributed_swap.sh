#!/bin/bash
set -e

# DS4 Distributed — Coordinator on GPU 1, Worker on GPU 0
#
# GPU 0 drives the display and has ~900 MB of desktop overhead.
# GPU 1 is completely free. We run the memory-hungry coordinator
# (API server + full context buffers + output head) on GPU 1,
# and the worker on GPU 0.
#
# This avoids the OOM crashes seen when the coordinator runs on
# the display GPU with very large context windows.

MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
COORD_PORT="${COORD_PORT:-12345}"
LAYERS_COORD="${LAYERS_COORD:-0:30}"
LAYERS_WORKER="${LAYERS_WORKER:-31:output}"
CTX="${CTX:-393216}"
PREFILL_CHUNK="${PREFILL_CHUNK:-8192}"
USE_SHM="${USE_SHM:-0}"
SHM_FLAG=""
if [ "${USE_SHM}" = "1" ]; then
    SHM_FLAG="--use-shm-transport"
fi

echo "=== DS4 Distributed (Coordinator on GPU 1) ==="
echo "  Context: ${CTX} tokens"
echo "  Prefill chunk: ${PREFILL_CHUNK}"
echo "  Coordinator: GPU 1, layers ${LAYERS_COORD}"
echo "  Worker:      GPU 0, layers ${LAYERS_WORKER}"
echo ""

GPU_COUNT=$(nvidia-smi -L | wc -l)
if [ "${GPU_COUNT}" -lt 2 ]; then
    echo "Error: This script requires 2 GPUs, but only ${GPU_COUNT} found."
    exit 1
fi

# Stop any existing containers first
podman stop ds4-coord ds4-worker 2>/dev/null || true

echo "Launching coordinator on GPU 1 (more free memory)..."
podman run -d --rm \
    --name ds4-coord \
    --network host \
    --device nvidia.com/gpu=1 \
    -e DS4_MODEL=/app/gguf/ds4flash.gguf \
    -v "${MODEL_DIR}:/app/gguf:Z" \
    ds4-cuda:latest \
    ./ds4-server \
        --host 0.0.0.0 \
        --port 8000 \
        -m /app/gguf/ds4flash.gguf \
        --role coordinator \
        --layers "${LAYERS_COORD}" \
        --listen 127.0.0.1 "${COORD_PORT}" \
        --ctx "${CTX}" \
        --prefill-chunk "${PREFILL_CHUNK}" \
        --power 100 \
        ${SHM_FLAG}

echo "Launching worker on GPU 0..."
podman run -d --rm \
    --name ds4-worker \
    --network host \
    --device nvidia.com/gpu=0 \
    -e DS4_MODEL=/app/gguf/ds4flash.gguf \
    -v "${MODEL_DIR}:/app/gguf:Z" \
    ds4-cuda:latest \
    ./ds4 \
        -m /app/gguf/ds4flash.gguf \
        --role worker \
        --layers "${LAYERS_WORKER}" \
        --coordinator 127.0.0.1 "${COORD_PORT}" \
        --ctx "${CTX}" \
        --power 100 \
        ${SHM_FLAG}

echo ""
echo "Distributed containers launched (coordinator on GPU 1)."
echo "  API server: http://localhost:8000"
echo "  Context:    ${CTX} tokens"
echo ""
echo "Monitor logs:"
echo "  podman logs -f ds4-coord"
echo "  podman logs -f ds4-worker"
echo ""
echo "Stop both:"
echo "  podman stop ds4-coord ds4-worker"
