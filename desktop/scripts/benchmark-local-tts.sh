#!/bin/bash
set -euo pipefail

BASE_URL="${OMI_LOCAL_SPEECH_URL:-http://127.0.0.1:10202}"
TMP_DIR="$(mktemp -d /tmp/omi-local-tts-bench.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_payload() {
  local path="$1"
  local text="$2"
  local voice="$3"
  local lang="$4"
  python3 - "$path" "$text" "$voice" "$lang" <<'PY'
import json
import sys

path, text, voice, lang = sys.argv[1:]
payload = {"text": text}
if voice:
  payload["voice"] = voice
if lang:
  payload["lang"] = lang
with open(path, "w", encoding="utf-8") as file:
  json.dump(payload, file)
PY
}

run_case() {
  local name="$1"
  local text="$2"
  local voice="$3"
  local lang="$4"
  local payload="$TMP_DIR/$name.json"
  local audio="$TMP_DIR/$name.audio"

  write_payload "$payload" "$text" "$voice" "$lang"
  echo "== tts case=$name voice=${voice:-service-default} lang=${lang:-service-default} =="
  /usr/bin/time -p curl -fsS -o "$audio" \
    -H "content-type: application/json" \
    --data-binary "@$payload" \
    "$BASE_URL/v1/tts/synthesize"
  file "$audio"
  ls -lh "$audio"
  echo
}

echo "== health =="
curl -fsS "$BASE_URL/health" | python3 -m json.tool
echo

run_case en "Hello, this is the local Omi text to speech benchmark." "af_heart" "en-us"
run_case pt "Ola, este e o teste local de voz do Omi em portugues do Brasil." "pf_dora" "pt-br"
