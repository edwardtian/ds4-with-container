#!/bin/bash
set -e

# DwarfStar DS4 Container Entrypoint
# Sets up the model symlink if a specific model file is provided via env.

resolve_model() {
    local path="$1"
    # If it's a symlink, resolve it
    while [ -L "$path" ]; do
        local dir
        dir=$(dirname "$path")
        path=$(readlink "$path")
        case "$path" in
            /*) ;; # absolute, keep as-is
            *) path="$dir/$path" ;;
        esac
    done
    echo "$path"
}

find_first_gguf() {
    find /app/gguf -maxdepth 1 -type f -name '*.gguf' | head -n 1
}

MODEL=""

# If DS4_MODEL is set, try to use it.
if [ -n "${DS4_MODEL}" ]; then
    if [ -f "${DS4_MODEL}" ]; then
        MODEL=$(resolve_model "${DS4_MODEL}")
    else
        echo "Warning: DS4_MODEL file not found: ${DS4_MODEL}"
        echo "  Attempting auto-detection in /app/gguf/ ..."
        MODEL=$(find_first_gguf)
    fi
fi

# If still no model, try common defaults.
if [ -z "${MODEL}" ]; then
    if [ -f "/app/gguf/ds4flash.gguf" ]; then
        MODEL=$(resolve_model "/app/gguf/ds4flash.gguf")
    elif [ -f "/app/ds4flash.gguf" ]; then
        MODEL=$(resolve_model "/app/ds4flash.gguf")
    else
        MODEL=$(find_first_gguf)
    fi
fi

# Create/update the default symlink so ds4 binaries can find the model.
if [ -n "${MODEL}" ] && [ -f "${MODEL}" ]; then
    ln -sf "${MODEL}" /app/ds4flash.gguf
    echo "Model ready: /app/ds4flash.gguf -> ${MODEL}"
else
    echo "Error: No .gguf model found in /app/gguf/. Mount your model directory with:"
    echo "  podman run ... -v /path/to/models:/app/gguf:Z ..."
    exit 1
fi

# Execute the command passed to the container
exec "$@"
