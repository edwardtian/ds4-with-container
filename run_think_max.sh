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

CONTAINER_IMAGE="${CONTAINER_IMAGE:-ds4-cuda:latest}"
MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
DS4_MODEL="${DS4_MODEL:-/app/gguf/ds4flash.gguf}"
COORD_PORT="${COORD_PORT:-12345}"
COORD_GPU="${COORD_GPU:-1}"
WORKER_GPU="${WORKER_GPU:-0}"
LAYERS_COORD="${LAYERS_COORD:-0:22}"
LAYERS_WORKER="${LAYERS_WORKER:-23:42}"
CTX="${CTX:-393216}"
PREFILL_CHUNK="${PREFILL_CHUNK:-4096}"

if [ "${USE_SHM:-0}" = "1" ]; then
    echo "Error: USE_SHM=1 is not supported by this C build; --use-shm-transport is not implemented."
    echo "Use the default TCP transport."
    exit 2
fi

echo "=== DS4 Think Max Mode ==="
echo "  Image: ${CONTAINER_IMAGE}"
echo "  Coordinator GPU: ${COORD_GPU}"
echo "  Worker GPU:      ${WORKER_GPU}"
echo "  Context: ${CTX} tokens (min 393216 for Think Max)"
echo "  Prefill chunk: ${PREFILL_CHUNK}"
echo "  Coordinator layers: ${LAYERS_COORD}"
echo "  Worker layers:    ${LAYERS_WORKER}"
echo ""
echo "  NOTE: Think Max is requested by API clients via reasoning_effort=max"
echo "        (not a server startup flag). See the curl example below."
echo ""

if [ ! -d "${MODEL_DIR}" ]; then
    echo "Error: Model directory not found: ${MODEL_DIR}"
    echo "Set MODEL_DIR to the directory containing ds4flash.gguf."
    exit 1
fi

GPU_COUNT=$(nvidia-smi -L | wc -l)
if [ "${GPU_COUNT}" -lt 2 ]; then
    echo "Error: This script requires 2 GPUs, but only ${GPU_COUNT} found."
    exit 1
fi

# Stop any existing containers first
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
        --listen 127.0.0.1 "${COORD_PORT}" \
        --ctx "${CTX}" \
        --prefill-chunk "${PREFILL_CHUNK}" \
        --power 100

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
        --coordinator 127.0.0.1 "${COORD_PORT}" \
        --ctx "${CTX}" \
        --power 100

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
