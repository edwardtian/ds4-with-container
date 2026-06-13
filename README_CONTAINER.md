# DwarfStar DS4 Podman Container

This directory contains a complete [Podman](https://podman.io/) container setup for running DwarfStar DS4 with CUDA support. It reuses your local NVIDIA CUDA installer and model files, keeping the container image small and avoiding redundant downloads.

---

## Prerequisites

- Linux host with NVIDIA GPUs
- [Podman](https://podman.io/) installed
- [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html) configured for Podman
- Validated with:
  ```bash
  podman run --rm --device nvidia.com/gpu=all ubuntu:24.04 nvidia-smi
  ```

---

## Files

| File | Purpose |
|------|---------|
| `Containerfile` | Multi-step build: Ubuntu 24.04 + local CUDA 13.3 toolkit + compiled DS4 binaries |
| `entrypoint.sh` | Auto-detects `.gguf` models in `/app/gguf/` and creates the `ds4flash.gguf` symlink |
| `build_container.sh` | One-command build script |
| `run_container.sh` | Run a single container (default: all GPUs, or pin with `GPU_ID=N`) |
| `run_distributed.sh` | Launch coordinator + worker across two GPUs (coordinator on GPU 1) |
| `run_think_max.sh` | Launch distributed Think Max mode (384K+ context) |
| `run_max_ctx.sh` | Launch distributed maximum-context mode (768K+ context) |
| `podman-compose.yml` | Alternative Podman Compose stack for single-GPU server mode |
| `.containerignore` | Excludes large files (`*.gguf`, build artifacts) from the build context |

---

## Build

```bash
./build_container.sh
```

This copies your local `cuda_13.3.0_610.43.02_linux.run` into the build and silently installs the CUDA toolkit. The resulting image is tagged `ds4-cuda:latest`.

**Note on GPU architecture:** The build compiles with `-arch=sm_120` to generate native SASS for Blackwell GPUs (RTX PRO 6000). If you run on a different GPU architecture, edit `Containerfile`:

```dockerfile
RUN make clean && make cuda CUDA_ARCH=sm_XX -j$(nproc)
```

Replace `sm_XX` with your GPU's compute capability (e.g. `sm_89` for Ada Lovelace, `sm_90` for Hopper).

---

## Single-GPU Usage

### Run the API server (default)

```bash
./run_container.sh
```

Server listens on `http://localhost:8000`. The `gguf/` directory is mounted read-write as a volume.

### Run the interactive CLI

```bash
./run_container.sh ./ds4 -p "Hello world" -n 20
```

### Pin to a specific GPU

```bash
GPU_ID=0 ./run_container.sh
GPU_ID=1 ./run_container.sh
```

---

## Two-GPU Distributed Usage

DS4's CUDA backend is single-GPU only. To use multiple GPUs, run DS4's **distributed inference**: split transformer layers across two processes that communicate over localhost TCP.

**Important:** All distributed scripts run the **coordinator on GPU 1** and the **worker on GPU 0** by default. GPU 0 drives your display (~900 MB overhead), so the memory-hungry coordinator (API server + context buffers + output head) gets the clean GPU 1. This avoids the OOM crashes that occur when the coordinator runs on the display GPU.

```bash
./run_distributed.sh
```

This launches:

| Role | Container | GPU | Layers | Exposed Port |
|------|-----------|-----|--------|-------------|
| Coordinator | `ds4-coord` | **1** | `0:30` + output head | `8000` |
| Worker | `ds4-worker` | **0** | `31:output` | — |

### Monitor

```bash
podman logs -f ds4-coord
podman logs -f ds4-worker
```

### Stop

```bash
podman stop ds4-coord ds4-worker
```

### Custom layer split

```bash
LAYERS_COORD=0:25 LAYERS_WORKER=26:output ./run_distributed.sh
```

**Trade-offs:**
- **Memory:** ~96 GB × 2 = ~192 GB combined capacity
- **Prefill:** Faster (pipelined across GPUs)
- **Generation:** ~15–20% slower than single-GPU due to per-token network hop

### Shared-Memory Transport (optional)

By default, the coordinator and worker exchange activation tensors over **localhost TCP**. You can switch to **POSIX shared memory** for same-machine multi-GPU setups to eliminate TCP stack overhead:

```bash
USE_SHM=1 ./run_distributed.sh
```

This works with all distributed scripts (`run_think_max.sh`, `run_max_ctx.sh`, `run_distributed_swap.sh`).

**How it works:**
- DS4 still uses TCP for the control path (HELLO, route setup, heartbeat).
- Data connections (activation tensors) use a 256 MB ring buffer in `/dev/shm` with named semaphores for cross-process wake-up.
- The shared-memory transport is **Linux-only** and silently falls back to TCP on other platforms.

**When to use it:**
- Always for same-host multi-GPU ( eliminates ~2× kernel copy + protocol overhead per tensor).
- Not applicable for multi-node setups (TCP is used automatically when the peer is a remote IP).

---

## Maximum Context Window & Think Max

DeepSeek-V4-Flash natively supports a **1M-token context length** thanks to its compressed KV cache design (CSA/HCA). With your 2× RTX PRO 6000 (96 GB each), the model is split as ~58.6 GB on GPU 0 and ~32.8 GB on GPU 1, leaving roughly **100 GB of combined free VRAM** for the KV cache and activations. That makes very large contexts practical.

### Context sizing guide

| Mode | `--ctx` | Description |
|------|--------:|-------------|
| Think Max minimum | 393216 (384K) | Required for Think Max API requests |
| Comfortable large | 524288 (512K) | Good headroom for long documents |
| Maximum practical | 786432 (768K) | Safe daily-driver maximum |
| Absolute model limit | 1048576 (1M) | May require tuning if OOM |

### Think Max mode

Think Max is the highest reasoning-effort mode. It needs at least a 384K context window. **Important:** `ds4-server` does not accept `--think-max` as a startup flag. Thinking mode is controlled by the API client via `reasoning_effort`.

Start the server with a large context window:

```bash
./run_think_max.sh
```

Then request Think Max from a client:

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "deepseek-v4-flash",
    "messages": [{"role": "user", "content": "Explain quantum entanglement."}],
    "reasoning_effort": "max"
  }'
```

The server defaults to high-effort thinking. Valid `reasoning_effort` values are:
- `max` → Think Max (requires `--ctx >= 393216`)
- `high` → Normal thinking mode
- Omit or use `thinking={type:disabled}` → Non-thinking mode

### Tuning for very large contexts

- **Prefill chunk:** The scripts default to `--prefill-chunk 8192`. For 1M contexts you may want to experiment with larger chunks.
- **Power:** Both scripts pass `--power 100` for full GPU duty cycle.
- **OOM:** If you hit OOM at 1M, drop to 768K or 512K. The compressed KV cache scales sub-linearly, but activations and scratch space still grow.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `MODEL_DIR` | `$(pwd)/gguf` | Host path mounted into `/app/gguf` inside the container |
| `DS4_MODEL` | `/app/gguf/ds4flash.gguf` | Path to the `.gguf` file inside the container |
| `GPU_ID` | `all` | GPU index passed to `--device nvidia.com/gpu=`. Use `0`, `1`, or `all` |
| `LAYERS_COORD` | `0:30` | Layer range for the distributed coordinator |
| `LAYERS_WORKER` | `31:output` | Layer range for the distributed worker |
| `COORD_PORT` | `12345` | TCP port for coordinator/worker handshake |
| `CTX` | `393216` (think-max) / `786432` (max-ctx) | Allocated context tokens |
| `PREFILL_CHUNK` | `8192` | Prefill chunk size for long contexts |

---

## Podman Compose

If you prefer Podman Compose for single-GPU server mode:

```bash
podman-compose up
```

---

## Troubleshooting

### Worker disconnected / coordinator crashes during requests

If the worker logs show `coordinator disconnected; reconnecting`, the coordinator likely crashed — most commonly from **OOM** on the display GPU (GPU 0). GPU 0 has ~900 MB of desktop overhead (GNOME/Xwayland), leaving less room for the coordinator's context buffers and generation scratch.

**Fix:** All distributed scripts now run the coordinator on GPU 1 by default. If you customized the scripts to put the coordinator on GPU 0, swap them:

```bash
# Coordinator on GPU 1, worker on GPU 0
./run_distributed.sh
```

If you still hit OOM, reduce the context window:

```bash
CTX=262144 ./run_max_ctx.sh   # 256K context
```

### `the provided PTX was compiled with an unsupported toolchain`

Your host NVIDIA driver is older than the CUDA toolkit inside the container. The driver cannot JIT-compile the PTX emitted by the newer `nvcc`. Rebuild the image with an explicit `-arch=sm_XX` matching your GPU so `nvcc` generates native SASS instead of PTX:

```dockerfile
RUN make clean && make cuda CUDA_ARCH=sm_120 -j$(nproc)
```

### `CUDA set device failed: no CUDA-capable device is detected`

When using `--device nvidia.com/gpu=N`, the container only sees that GPU as **device 0**. Do **not** set `CUDA_VISIBLE_DEVICES=N` inside the container. The scripts handle this automatically.

### `CUDA tensor alloc failed: out of memory`

The model does not fit in a single GPU's VRAM. Use `./run_distributed.sh` to split layers across two GPUs, or run a smaller quant (e.g. Q2 instead of Q4).

### `no .gguf model found in /app/gguf/`

Ensure your host `gguf/` directory contains at least one `.gguf` file and is correctly mounted:

```bash
MODEL_DIR=/path/to/your/gguf ./run_container.sh
```

---

## Architecture Notes

- **Base image:** Ubuntu 24.04
- **CUDA:** 13.3 (installed from local `.run` installer)
- **Driver requirement:** Host driver must be >= 610.43.02 for CUDA 13.3 runtime features. The container ships the toolkit; only the driver comes from the host.
- **Build target:** `make cuda CUDA_ARCH=sm_120` — compiles SASS for Blackwell (sm_120)
- **Ports exposed:** `8000` (API server), `9333` (agent debug/CDP)
