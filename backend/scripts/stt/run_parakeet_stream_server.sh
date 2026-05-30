#!/bin/zsh
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export CMAKE_POLICY_VERSION_MINIMUM="${CMAKE_POLICY_VERSION_MINIMUM:-3.5}"

exec "$(command -v uvx)" \
  --python 3.13 \
  --from 'parakeet-stream[server]' \
  parakeet-server run \
  --host 127.0.0.1 \
  --port 8765 \
  --device mps \
  --config low_latency
