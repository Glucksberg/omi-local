#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

PORT="${PORT:-10201}"
AUTH_PORT="${AUTH_PORT:-10200}"

export OMI_LOCAL_MODE="${OMI_LOCAL_MODE:-1}"
export OMI_APP_NAME="${OMI_APP_NAME:-Omi Local}"
export OMI_SKIP_BACKEND="${OMI_SKIP_BACKEND:-1}"
export OMI_SKIP_AUTH="${OMI_SKIP_AUTH:-1}"
export OMI_SKIP_TUNNEL="${OMI_SKIP_TUNNEL:-1}"
if [ -z "${OMI_SIGN_IDENTITY:-}" ]; then
  if security find-identity -v -p codesigning 2>/dev/null | grep -q '"Omi Local Development"'; then
    export OMI_SIGN_IDENTITY="Omi Local Development"
  else
    export OMI_SIGN_IDENTITY="-"
  fi
fi
export PORT
export AUTH_PORT
export OMI_API_URL="${OMI_API_URL:-http://127.0.0.1:${PORT}}"
export OMI_AUTH_URL="${OMI_AUTH_URL:-http://127.0.0.1:${AUTH_PORT}/}"
export OMI_PYTHON_API_URL="${OMI_PYTHON_API_URL:-$OMI_API_URL}"
export OMI_REMOTE_LLM_PROVIDER="${OMI_REMOTE_LLM_PROVIDER:-openai-codex}"
export OMI_REMOTE_LLM_MODEL="${OMI_REMOTE_LLM_MODEL:-gpt-5.5}"
export OMI_LOCAL_TRANSCRIPTION_URL="${OMI_LOCAL_TRANSCRIPTION_URL:-http://127.0.0.1:10202}"
export OMI_LOCAL_TRANSCRIPTION_ENABLED="${OMI_LOCAL_TRANSCRIPTION_ENABLED:-1}"
export OMI_LOCAL_TTS_URL="${OMI_LOCAL_TTS_URL:-http://127.0.0.1:10202}"
export OMI_LOCAL_TTS_ENABLED="${OMI_LOCAL_TTS_ENABLED:-1}"

SPEECH_PID=""
if [ "${OMI_LOCAL_SPEECH_AUTOSTART:-1}" = "1" ]; then
  mkdir -p /tmp
  ./scripts/run-local-speech.sh >> /tmp/omi-local-speech.log 2>&1 &
  SPEECH_PID=$!
fi

cleanup() {
  if [ -n "$SPEECH_PID" ] && kill -0 "$SPEECH_PID" 2>/dev/null; then
    kill "$SPEECH_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

./run.sh "$@"
