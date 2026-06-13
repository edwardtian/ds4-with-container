#!/bin/bash
set -e

# DS4 Distributed Maximum Context Mode
# Pushes the context window as far as practical on 2x96GB GPUs.
# DeepSeek-V4-Flash supports up to 1M tokens. With compressed KV cache
# (CSA/HCA), the memory scales sub-linearly, making very large contexts
# feasible on this hardware.
#
# Default: 786432 tokens (768K) — a safe maximum for 2x RTX PRO 6000.
# Set CTX=1048576 for the absolute model limit (1M), but watch for OOM.
#
# Hardware: 2x NVIDIA RTX PRO 6000 Blackwell (96 GB each)
# Model:     DeepSeek-V4-Flash q2-q4-imatrix

CONTAINER_IMAGE="ds4-cuda:latest"
MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
COORD_PORT="${COORD_PORT:-12345}"
LAYERS_COORD="${LAYERS_COORD:-0:22}"
LAYERS_WORKER="${LAYERS_WORKER:-23:output}"
CTX="${CTX:-786432}"
PREFILL_CHUNK="${PREFILL_CHUNK:-4096}"
USE_SHM="${USE_SHM:-0}"
SHM_FLAG=""
if [ "${USE_SHM}" = "1" ]; then
    SHM_FLAG="--use-shm-transport"
fi

echo "=== DS4 Maximum Context Mode ==="
echo "  Context: ${CTX} tokens"
echo "  Prefill chunk: ${PREFILL_CHUNK}"
echo "  Coordinator layers: ${LAYERS_COORD}"
echo "  Worker layers:    ${LAYERS_WORKER}"
echo ""

GPU_COUNT=$(nvidia-smi -L | wc -l)
if [ "${GPU_COUNT}" -lt 2 ]; then
    echo "Error: This script requires 2 GPUs, but only ${GPU_COUNT} found."
    exit 1
fi

# Stop any existing containers first
podman stop ds4-coord ds4-worker 2>/dev/null || true

echo "Launching coordinator on GPU 1 (more free memory, no display overhead)..."
podman run -d --rm \
    --name ds4-coord \
    --network host \
    --device nvidia.com/gpu=1 \
    -e DS4_MODEL=/app/gguf/ds4flash.gguf \
    -v "${MODEL_DIR}:/app/gguf:Z" \
    "${CONTAINER_IMAGE}" \
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
    "${CONTAINER_IMAGE}" \
    ./ds4 \
        -m /app/gguf/ds4flash.gguf \
        --role worker \
        --layers "${LAYERS_WORKER}" \
        --coordinator 127.0.0.1 "${COORD_PORT}" \
        --ctx "${CTX}" \
        --power 100 \
        ${SHM_FLAG}

echo ""
echo "Maximum-context server is running."
echo "  API server: http://localhost:8000"
echo "  Context:    ${CTX} tokens"
echo ""
echo "Request Think Max from a client:"
echo "  curl http://localhost:8000/v1/chat/completions \\"
echo "    -H \"Content-Type: application/json\" \\"
echo "    -d '{\"model\":\"deepseek-v4-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"...\"}],\"reasoning_effort\":\"max\"}'"
echo ""
echo "Monitor logs:"
echo "  podman logs -f ds4-coord"
echo "  podman logs -f ds4-worker"
echo ""
echo "Stop both:"
echo "  podman stop ds4-coord ds4-worker"
echo ""
echo "Tips:"
echo "  - If you hit OOM, lower CTX: CTX=524288 ./run_max_ctx.sh"
echo "  - Model absolute limit: CTX=1048576 (1M tokens)"
