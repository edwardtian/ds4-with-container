#!/bin/bash
set -e

# DS4 Tensor-Parallel Server — Expert-Parallel MoE
#
# Runs ds4-server with --tensor-parallel, which shards the 256 MoE experts
# across both GPUs. All layers are loaded on both GPUs (replicated attention,
# HC, shared expert), but each GPU only stores its expert subset (~50% memory
# savings on the dominant expert weights).
#
# Hardware: 2x NVIDIA RTX PRO 6000 Blackwell (96 GB each)
# Model:    DeepSeek-V4-Flash q2-q4-imatrix

CONTAINER_IMAGE="${CONTAINER_IMAGE:-ds4-cuda-tp:latest}"
MODEL_DIR="${MODEL_DIR:-$(pwd)/gguf}"
DS4_MODEL="${DS4_MODEL:-/app/gguf/ds4flash.gguf}"
# CTX="${CTX:-1048576}"
CTX="${CTX:-524288}"
PREFILL_CHUNK="${PREFILL_CHUNK:-4096}"
PORT="${PORT:-8000}"

podman stop ds4-server 2>/dev/null || true

echo "=== DS4 Tensor-Parallel Server ==="
echo "  Image: ${CONTAINER_IMAGE}"
echo "  Model dir: ${MODEL_DIR}"
echo "  GPUs: all (experts sharded across GPUs)"
echo "  Context: ${CTX} tokens"
echo ""

if [ ! -d "${MODEL_DIR}" ]; then
    echo "Error: Model directory not found: ${MODEL_DIR}"
    exit 1
fi

podman run --rm \
    --name ds4-server \
    --network host \
    --ulimit memlock=-1:-1 \
    --device nvidia.com/gpu=all \
    -e "DS4_MODEL=${DS4_MODEL}" \
    -v "${MODEL_DIR}:/app/gguf:z" \
    "${CONTAINER_IMAGE}" \
    ./ds4-server \
        --cuda --cuda-tensor-parallel \
        --gpu-vram auto \
        --gpu-devices 0,1 \
        --host 0.0.0.0 \
        --port "${PORT}" \
        -m "${DS4_MODEL}" \
        --ctx "${CTX}" \
        --prefill-chunk "${PREFILL_CHUNK}" \

echo ""
echo "Tensor-parallel server is running."
echo "  API server: http://localhost:${PORT}"
echo ""
echo "Monitor logs:"
echo "  podman logs -f ds4-server"
echo ""
echo "Stop:"
echo "  podman stop ds4-server"
