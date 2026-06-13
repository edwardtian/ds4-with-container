# DwarfStar DS4 Podman Container
# Builds the project with CUDA support and reuses local CUDA installer + models

FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install build dependencies and runtime libraries
RUN apt-get update && apt-get install -y \
    build-essential \
    gcc \
    g++ \
    make \
    curl \
    wget \
    ca-certificates \
    libgomp1 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

# Copy and install CUDA toolkit from the local installer
# The installer is run silently with toolkit only (no samples/docs)
COPY cuda_13.3.0_610.43.02_linux.run /tmp/cuda_installer.run
RUN chmod +x /tmp/cuda_installer.run && \
    /tmp/cuda_installer.run --silent --toolkit --installpath=/usr/local/cuda && \
    rm /tmp/cuda_installer.run

# Set CUDA environment variables
ENV CUDA_HOME=/usr/local/cuda
ENV PATH=${CUDA_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${CUDA_HOME}/lib64:${LD_LIBRARY_PATH}

# Create app directory
WORKDIR /app

# Copy project source files
COPY *.c *.h *.cu *.m *.sh Makefile /app/
COPY linenoise.c linenoise.h /app/
COPY rax.c rax.h rax_malloc.h /app/
COPY ds4_iq2_tables_cuda.inc ds4_streaming_hotlist.inc /app/
COPY metal/ /app/metal/
COPY rocm/ /app/rocm/
COPY tests/ /app/tests/
COPY gguf-tools/ /app/gguf-tools/
COPY speed-bench/ /app/speed-bench/
COPY dir-steering/ /app/dir-steering/
COPY misc/ /app/misc/

# Create gguf directory for model volume mount
RUN mkdir -p /app/gguf

# Build the project with explicit sm_120 SASS to avoid PTX JIT issues on
# drivers older than the CUDA toolkit used for compilation.
RUN make clean && make cuda CUDA_ARCH=sm_120 -j$(nproc)

# Default model path symlink will be created at runtime via entrypoint,
# since the model is mounted as a volume.

# Expose ds4-server API port and ds4-agent web debug port
EXPOSE 8000 9333

# Default to running the server
# Users should mount their model volume to /app/gguf/ and optionally
# set the MODEL_SYMLINK env variable to point the default symlink.
ENV MODEL_PATH=/app/gguf/ds4flash.gguf

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["./ds4-server", "--host", "0.0.0.0", "--port", "8000", "-m", "/app/gguf/ds4flash.gguf"]
