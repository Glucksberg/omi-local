#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
BACKEND_DIR="${SCRIPT_DIR:h:h}"
VENV="$BACKEND_DIR/.venv-parakeet-monitor"

if [ ! -x "$VENV/bin/python" ]; then
  python3 -m venv "$VENV"
fi

"$VENV/bin/python" - <<'PY'
import importlib.util
import subprocess
import sys

missing = [name for name in ("textual", "psutil") if importlib.util.find_spec(name) is None]
if missing:
    subprocess.check_call([sys.executable, "-m", "pip", "install", "textual", "psutil"])
PY

cd "$BACKEND_DIR"
exec "$VENV/bin/python" "$SCRIPT_DIR/parakeet_resource_monitor.py" "$@"
