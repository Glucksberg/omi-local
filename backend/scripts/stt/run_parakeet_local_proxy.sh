#!/bin/zsh
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SCRIPT_DIR="${0:A:h}"
BACKEND_DIR="${SCRIPT_DIR:h:h}"

for _ in {1..120}; do
  if /usr/sbin/lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ -x "$BACKEND_DIR/.venv/bin/python" ]] && "$BACKEND_DIR/.venv/bin/python" -c 'import websockets' >/dev/null 2>&1; then
  exec "$BACKEND_DIR/.venv/bin/python" \
    "$SCRIPT_DIR/parakeet_local_listen_server.py" \
    --host 127.0.0.1 \
    --port 8001 \
    --parakeet-url ws://127.0.0.1:8765
fi

exec "$(command -v uv)" run \
  --isolated \
  --with websockets==12.0 \
  python "$SCRIPT_DIR/parakeet_local_listen_server.py" \
    --host 127.0.0.1 \
    --port 8001 \
    --parakeet-url ws://127.0.0.1:8765
