#!/bin/bash
set -euo pipefail

BASE_URL="${OMI_LOCAL_SPEECH_URL:-http://127.0.0.1:10202}"
TEXT="${1:-hello this is an omi local speech benchmark}"
TMP_DIR="$(mktemp -d /tmp/omi-local-speech-bench.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

payload="$TMP_DIR/tts.json"
tts_audio="$TMP_DIR/tts.aiff"
stt_audio="$TMP_DIR/stt.wav"
transcript="$TMP_DIR/transcript.json"

python3 - "$TEXT" > "$payload" <<'PY'
import json
import sys

print(json.dumps({"text": sys.argv[1]}))
PY

echo "== health =="
curl -fsS "$BASE_URL/health" | python3 -m json.tool

echo
echo "== warmup =="
/usr/bin/time -p curl -fsS -X POST "$BASE_URL/warmup?language=en" | python3 -m json.tool

echo
echo "== tts =="
/usr/bin/time -p curl -fsS -o "$tts_audio" \
  -H "content-type: application/json" \
  --data-binary "@$payload" \
  "$BASE_URL/v1/tts/synthesize"

/usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$tts_audio" "$stt_audio"
ls -lh "$tts_audio" "$stt_audio"

echo
echo "== stt =="
/usr/bin/time -p curl -fsS -o "$transcript" -X POST \
  --data-binary "@$stt_audio" \
  "$BASE_URL/v2/voice-message/transcribe?language=en&sample_rate=16000&channels=1"
cat "$transcript"
echo

echo
echo "== health after benchmark =="
curl -fsS "$BASE_URL/health" | python3 -m json.tool
