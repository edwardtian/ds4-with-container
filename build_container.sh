#!/bin/bash
set -e

# Build the DwarfStar DS4 Podman image
# Reuses the local CUDA installer and expects models to be mounted at runtime.

echo "Building ds4-cuda container..."
podman build -f Containerfile -t ds4-cuda:latest "$@"

echo "Build complete. Image: ds4-cuda:latest"
echo ""
echo "To run the server with your local model:"
echo "  ./run_container.sh"
