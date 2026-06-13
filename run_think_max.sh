#!/bin/bash
set -e

# DS4 Distributed Think Max Mode
#
# Think Max is the highest reasoning-effort mode. It requires a context window
# of at least 384K tokens (393216). On this hardware (2x RTX PRO 6000 96GB)
# the model is split across both GPUs via distributed inference.
#
# IMPORTANT: ds4-server does NOT accept --think-max as a CLI flag.
# Thinking mode is requested by API clients via reasoning_effort=max.
# This script launches the distributed server with a 384K context window.
# The server already defaults to high-effort thinking; clients send
# {"reasoning_effort": "max"} for Think Max.
#
# Hardware: 2x NVIDIA RTX PRO 6000 Blackwell (96 GB each)
# Model:     DeepSeek-V4-Flash q2-q4-imatrix

MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
COORD_PORT="${COORD_PORT:-12345}"
LAYERS_COORD="${LAYERS_COORD:-0:22}"
LAYERS_WORKER="${LAYERS_WORKER:-23:output}"
CTX="${CTX:-393216}"
PREFILL_CHUNK="${PREFILL_CHUNK:-8192}"
USE_SHM="${USE_SHM:-0}"
SHM_FLAG=""
if [ "${USE_SHM}" = "1" ]; then
    SHM_FLAG="--use-shm-transport"
fi

echo "=== DS4 Think Max Mode ==="
echo "  Context: ${CTX} tokens (min 393216 for Think Max)"
echo "  Prefill chunk: ${PREFILL_CHUNK}"
echo "  Coordinator layers: ${LAYERS_COORD}"
echo "  Worker layers:    ${LAYERS_WORKER}"
echo ""
echo "  NOTE: Think Max is requested by API clients via reasoning_effort=max"
echo "        (not a server startup flag). See the curl example below."
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
echo "Think Max server is running."
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
