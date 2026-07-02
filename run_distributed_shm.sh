#!/bin/bash
set -e

echo "run_distributed_shm.sh is disabled in this branch."
echo "The C runtime does not implement --use-shm-transport yet, so the working"
echo "two-GPU path is the TCP-based distributed launcher:"
echo "  ./run_distributed.sh"
exit 2
