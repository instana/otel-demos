#!/bin/bash

set -eo pipefail
set -x

# Run from anywhere with relative paths
SRC_DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")")
cd "${SRC_DIR}"

# Run the demo
docker-compose down && docker-compose up --build
