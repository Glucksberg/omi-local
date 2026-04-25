#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

API_DIR="$PWD/local-api"
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

if [ -f "$HOME/.omi.env" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      OMI_LOCAL_API_HOST|OMI_LOCAL_API_PORT|OMI_LOCAL_API_DB_PATH)
        value="${value%$'\r'}"
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        export "$key=$value"
        ;;
    esac
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$HOME/.omi.env" || true)
fi

exec python3 "$API_DIR/server.py"
