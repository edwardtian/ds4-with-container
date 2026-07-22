#!/bin/bash
set -e

# DS4 Single-Container Multi-GPU Server
#
# Runs one ds4-server container with --multi-gpu, which automatically
# splits model layers across all available GPUs using pipeline parallelism.
# No separate worker processes or distributed setup needed.
#
# Hardware: 2x NVIDIA RTX PRO 6000 Blackwell (96 GB each)
# Model:    DeepSeek-V4-Flash q2-q4-imatrix

CONTAINER_IMAGE="${CONTAINER_IMAGE:-localhost/ds4-cuda-tp:latest}"
MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
DS4_MODEL="${DS4_MODEL:-/app/gguf/ds4flash.gguf}"
DS4_DSPARK="${DS4_DSPARK:-/app/gguf/ds4dspark.gguf}"
DSPARK="${DSPARK:-1}"
CACHE_DIR="${CACHE_DIR:-/mnt/ds4_ramcache}"
KV_DISK_SPACE_MB="${KV_DISK_SPACE_MB:-131072}"
#CTX="${CTX:-1048576}"
CTX="${CTX:-524288}"
PREFILL_CHUNK="${PREFILL_CHUNK:-8192}"
PORT="${PORT:-8000}"

# Stop any existing container first
podman stop ds4-server 2>/dev/null || true

# Check and create RAM disk if needed
if mount | grep -q " /mnt/ds4_ramcache "; then
    MOUNT_SIZE=$(df --block-size=1G /mnt/ds4_ramcache | awk 'NR==2 {print $2}')
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

SERVER_CACHE_ARGS=()
CACHE_MOUNT_ARGS=()
if [ -n "${CACHE_DIR}" ]; then
    mkdir -p "${CACHE_DIR}"
    CACHE_MOUNT_ARGS=(-v "${CACHE_DIR}:/app/cache:z")
    SERVER_CACHE_ARGS=(--kv-disk-dir /app/cache --kv-disk-space-mb "${KV_DISK_SPACE_MB}")
fi

echo "=== DS4 Multi-GPU Server (Single Container) ==="
echo "  Image: ${CONTAINER_IMAGE}"
echo "  Model dir: ${MODEL_DIR}"
echo "  Context: ${CTX} tokens"
echo "  Prefill chunk: ${PREFILL_CHUNK}"
if [ -n "${CACHE_DIR}" ]; then
    echo "  KV cache: ${CACHE_DIR} (${KV_DISK_SPACE_MB} MiB budget)"
fi
echo ""

if [ ! -d "${MODEL_DIR}" ]; then
    echo "Error: Model directory not found: ${MODEL_DIR}"
    echo "Set MODEL_DIR to the directory containing ds4flash.gguf."
    exit 1
fi

echo "Launching ds4-server with --multi-gpu..."
DSPARK_ARGS=()
if [ "${DSPARK}" = "1" ] && [ -f "${MODEL_DIR}/ds4dspark.gguf" ]; then
    DSPARK_ARGS=(--mtp "${DS4_DSPARK}" --dspark)
    echo "  DSpark: enabled (${DS4_DSPARK})"
else
    echo "  DSpark: disabled (set DSPARK=1 and ensure ds4dspark.gguf exists)"
fi

podman run --rm \
    --name ds4-server \
    --network host \
    --ulimit memlock=-1:-1 \
    --device nvidia.com/gpu=all \
    -e "DS4_MODEL=${DS4_MODEL}" \
    -e "DS4_CUDA_TP_ATTN=0" \
    -v "${MODEL_DIR}:/app/gguf:z" \
    "${CACHE_MOUNT_ARGS[@]}" \
    "${CONTAINER_IMAGE}" \
    ./ds4-server \
        --host 0.0.0.0 \
        --port "${PORT}" \
        --cuda --cuda-tensor-parallel \
        --gpu-vram auto \
        --gpu-devices 0,1 \
        "${SERVER_CACHE_ARGS[@]}" \
        "${DSPARK_ARGS[@]}" \
        -m "${DS4_MODEL}" \
        --ctx "${CTX}" \
        --prefill-chunk "${PREFILL_CHUNK}" \
        --power 100

echo ""
echo "DS4 server is running."
echo "  API server: http://localhost:${PORT}"
echo "  Context:    ${CTX} tokens"
echo ""
echo "Monitor logs:"
echo "  podman logs -f ds4-server"
echo ""
echo "Stop:"
echo "  podman stop ds4-server"
echo ""
echo "Tips:"
echo "  - Adjust context: CTX=524288 ./start-server-single.sh"
echo "  - To use Think Max, request it from the API client:"
echo "    curl http://localhost:${PORT}/v1/chat/completions \\"
echo "      -H \"Content-Type: application/json\" \\"
echo "      -d '{\"model\":\"deepseek-v4-flash\",\"messages\":[{\"role\":\"user\",\"content\":\"...\"}],\"reasoning_effort\":\"max\"}'"
