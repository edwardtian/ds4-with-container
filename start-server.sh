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

CONTAINER_IMAGE="${CONTAINER_IMAGE:-ds4-cuda:latest}"
MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
DS4_MODEL="${DS4_MODEL:-/app/gguf/ds4flash.gguf}"
CACHE_DIR="${CACHE_DIR:-/mnt/ds4_ramcache}"
KV_DISK_SPACE_MB="${KV_DISK_SPACE_MB:-131072}"
COORD_PORT="${COORD_PORT:-12345}"
COORD_GPU="${COORD_GPU:-1}"
WORKER_GPU="${WORKER_GPU:-0}"
LAYERS_COORD="${LAYERS_COORD:-0:22}"
LAYERS_WORKER="${LAYERS_WORKER:-23:42}"
CTX="${CTX:-1048576}"
PREFILL_CHUNK="${PREFILL_CHUNK:-4096}"

# Stop any existing containers first
podman stop ds4-coord ds4-worker 2>/dev/null || true

# Check and create RAM disk if needed
if mount | grep -q " /mnt/ds4_ramcache "; then
    MOUNT_SIZE=$(df --block-size=1G /mnt/ds4_ramcache | awk 'NR==2 {print $1}' | sed 's/G//')
    if [ "${MOUNT_SIZE}" != "128" ]; then
        echo "RAM disk size is ${MOUNT_SIZE}G, expected 128G; recreating..."
        sudo umount /mnt/ds4_ramcache
        sudo mount -t tmpfs -o size=128G tmpfs /mnt/ds4_ramcache
    fi
else
    sudo mount -t tmpfs -o size=128G tmpfs /mnt/ds4_ramcache
fi

# Check and fix permissions if needed
if [ "$(stat -c %U:%G /mnt/ds4_ramcache 2>/dev/null)" != "tianye:tianye" ]; then
    sudo chown -R tianye:tianye /mnt/ds4_ramcache
fi

if [ "${USE_SHM:-0}" = "1" ]; then
    echo "Error: USE_SHM=1 is not supported by this C build; --use-shm-transport is not implemented."
    echo "Use the default TCP transport."
    exit 2
fi

SERVER_CACHE_ARGS=()
CACHE_MOUNT_ARGS=()
if [ -n "${CACHE_DIR}" ]; then
    mkdir -p "${CACHE_DIR}"
    CACHE_MOUNT_ARGS=(-v "${CACHE_DIR}:/app/cache:z")
    SERVER_CACHE_ARGS=(--kv-disk-dir /app/cache --kv-disk-space-mb "${KV_DISK_SPACE_MB}")
fi

echo "=== DS4 Maximum Context Mode ==="
echo "  Image: ${CONTAINER_IMAGE}"
echo "  Model dir: ${MODEL_DIR}"
echo "  Coordinator GPU: ${COORD_GPU}"
echo "  Worker GPU:      ${WORKER_GPU}"
echo "  Context: ${CTX} tokens"
echo "  Prefill chunk: ${PREFILL_CHUNK}"
echo "  Coordinator layers: ${LAYERS_COORD}"
echo "  Worker layers:    ${LAYERS_WORKER}"
if [ -n "${CACHE_DIR}" ]; then
    echo "  KV cache: ${CACHE_DIR} (${KV_DISK_SPACE_MB} MiB budget)"
fi
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

echo "Launching coordinator on GPU ${COORD_GPU} (API + first layers + output head)..."
podman run -d --rm \
    --name ds4-coord \
    --network host \
    --ulimit memlock=-1:-1 \
    --device "nvidia.com/gpu=${COORD_GPU}" \
    -e "DS4_MODEL=${DS4_MODEL}" \
    -v "${MODEL_DIR}:/app/gguf:z" \
    "${CACHE_MOUNT_ARGS[@]}" \
    "${CONTAINER_IMAGE}" \
    ./ds4-server \
        --host 0.0.0.0 \
        --port 8000 \
        "${SERVER_CACHE_ARGS[@]}" \
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
echo "  - If you hit OOM, lower CTX: CTX=524288 ./start-server.sh"
echo "  - To try the model limit: CTX=1048576 ./start-server.sh"
