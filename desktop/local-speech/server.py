from __future__ import annotations

import asyncio
import ipaddress
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import wave
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response


APP_NAME = "omi-local-speech"
DEFAULT_SAMPLE_RATE = 16_000
DEFAULT_CHANNELS = 1
MAX_AUDIO_BYTES = int(os.environ.get("OMI_LOCAL_SPEECH_MAX_AUDIO_BYTES", str(20 * 1024 * 1024)))
MAX_TTS_CHARS = int(os.environ.get("OMI_LOCAL_SPEECH_MAX_TTS_CHARS", "4000"))
REQUIRE_LOOPBACK = os.environ.get("OMI_LOCAL_SPEECH_REQUIRE_LOOPBACK", "1") != "0"

app = FastAPI(title=APP_NAME)


def is_loopback_host(host: str | None) -> bool:
  if not host:
    return False
  if host == "localhost" or host.endswith(".localhost"):
    return True
  try:
    return ipaddress.ip_address(host).is_loopback
  except ValueError:
    return False


@app.middleware("http")
async def require_loopback_http(request: Request, call_next):
  if REQUIRE_LOOPBACK and not is_loopback_host(request.client.host if request.client else None):
    return JSONResponse({"detail": "omi-local-speech only accepts loopback clients"}, status_code=403)
  return await call_next(request)


async def accept_loopback_websocket(websocket: WebSocket) -> bool:
  if REQUIRE_LOOPBACK and not is_loopback_host(websocket.client.host if websocket.client else None):
    await websocket.close(code=1008, reason="omi-local-speech only accepts loopback clients")
    return False
  await websocket.accept()
  return True


def default_model_path() -> Path:
  return (
    Path.home()
    / "Library"
    / "Application Support"
    / "Omi Local"
    / "models"
    / "whisper"
    / "ggml-small.bin"
  )


def resolve_whisper_binary() -> str | None:
  configured = os.environ.get("WHISPER_CPP_BIN")
  if configured:
    return configured
  for candidate in ("whisper-cli", "whisper-cpp", "whisper", "main"):
    resolved = shutil.which(candidate)
    if resolved:
      return resolved
  return None


def resolve_whisper_model() -> Path:
  return Path(os.environ.get("WHISPER_MODEL_PATH", str(default_model_path()))).expanduser()


def normalize_language(language: str) -> str:
  language = (language or "auto").strip().lower()
  if language in {"multi", "auto", "detect"}:
    return "auto"
  return language


def write_audio_file(audio: bytes, sample_rate: int, channels: int, directory: Path) -> Path:
  if audio.startswith(b"RIFF"):
    path = directory / "input.wav"
    path.write_bytes(audio)
    return path

  path = directory / "input.wav"
  with wave.open(str(path), "wb") as wav_file:
    wav_file.setnchannels(channels)
    wav_file.setsampwidth(2)
    wav_file.setframerate(sample_rate)
    wav_file.writeframes(audio)
  return path


def validate_audio_format(sample_rate: int, channels: int) -> None:
  if sample_rate < 8_000 or sample_rate > 96_000:
    raise HTTPException(status_code=400, detail="sample_rate must be between 8000 and 96000")
  if channels < 1 or channels > 2:
    raise HTTPException(status_code=400, detail="channels must be 1 or 2")


def clean_whisper_text(text: str) -> str:
  lines: list[str] = []
  for line in text.splitlines():
    stripped = line.strip()
    if not stripped:
      continue
    lines.append(stripped)
  return " ".join(lines).strip()


def transcribe_audio(
  audio: bytes,
  language: str,
  sample_rate: int,
  channels: int,
) -> str:
  if not audio:
    return ""
  if len(audio) > MAX_AUDIO_BYTES:
    raise HTTPException(status_code=413, detail="audio payload too large")
  validate_audio_format(sample_rate, channels)

  whisper_bin = resolve_whisper_binary()
  if not whisper_bin:
    raise HTTPException(
      status_code=503,
      detail="whisper.cpp binary not found. Run desktop/scripts/setup-local-speech.sh.",
    )

  model_path = resolve_whisper_model()
  if not model_path.exists():
    raise HTTPException(
      status_code=503,
      detail=f"Whisper model not found at {model_path}. Run desktop/scripts/setup-local-speech.sh.",
    )

  with tempfile.TemporaryDirectory(prefix="omi-speech-") as tmp:
    tmp_dir = Path(tmp)
    wav_path = write_audio_file(audio, sample_rate, channels, tmp_dir)
    output_base = tmp_dir / "transcript"
    args = [
      whisper_bin,
      "-m",
      str(model_path),
      "-f",
      str(wav_path),
      "-otxt",
      "-of",
      str(output_base),
      "-l",
      normalize_language(language),
      "-t",
      os.environ.get("WHISPER_THREADS", "4"),
      "-nt",
    ]
    extra_args = os.environ.get("WHISPER_EXTRA_ARGS")
    if extra_args:
      args.extend(shlex.split(extra_args))

    timeout = int(os.environ.get("WHISPER_TIMEOUT_SECONDS", "120"))
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
    if result.returncode != 0:
      stderr = result.stderr.strip()[-1200:]
      raise HTTPException(status_code=500, detail=f"whisper.cpp failed: {stderr}")

    transcript_path = output_base.with_suffix(".txt")
    if transcript_path.exists():
      return clean_whisper_text(transcript_path.read_text(encoding="utf-8", errors="replace"))
    return clean_whisper_text(result.stdout)


def audio_duration_seconds(audio: bytes, sample_rate: int, channels: int) -> float:
  if sample_rate <= 0 or channels <= 0:
    return 0
  if audio.startswith(b"RIFF"):
    return 0
  return len(audio) / float(sample_rate * channels * 2)


def transcript_segment(
  text: str,
  audio: bytes,
  sample_rate: int,
  channels: int,
) -> list[dict[str, Any]]:
  if not text:
    return []
  return [
    {
      "id": None,
      "text": text,
      "speaker": "SPEAKER_00",
      "speaker_id": 0,
      "is_user": True,
      "person_id": None,
      "start": 0,
      "end": audio_duration_seconds(audio, sample_rate, channels),
      "translations": None,
    }
  ]


def run_say_tts(text: str) -> bytes:
  say_bin = shutil.which("say") or "/usr/bin/say"
  if not Path(say_bin).exists():
    raise HTTPException(status_code=503, detail="macOS say binary not found")

  with tempfile.TemporaryDirectory(prefix="omi-tts-") as tmp:
    output_path = Path(tmp) / "speech.aiff"
    args = [
      say_bin,
      "-o",
      str(output_path),
    ]
    voice = os.environ.get("OMI_LOCAL_TTS_VOICE")
    if voice:
      args.extend(["-v", voice])
    rate = os.environ.get("OMI_LOCAL_TTS_RATE")
    if rate:
      args.extend(["-r", rate])
    args.append(text)
    result = subprocess.run(args, capture_output=True, text=True, timeout=60, check=False)
    if result.returncode != 0:
      stderr = result.stderr.strip()[-1200:]
      raise HTTPException(status_code=500, detail=f"say failed: {stderr}")
    return output_path.read_bytes()


async def flush_websocket_audio(
  websocket: WebSocket,
  buffer: bytearray,
  language: str,
  sample_rate: int,
  channels: int,
) -> None:
  audio = bytes(buffer)
  buffer.clear()
  if not audio:
    return
  try:
    text = await asyncio.to_thread(transcribe_audio, audio, language, sample_rate, channels)
    segments = transcript_segment(text, audio, sample_rate, channels)
    await websocket.send_text(json.dumps(segments))
  except HTTPException as exc:
    await websocket.send_text(json.dumps({"type": "error", "message": str(exc.detail)}))
  except Exception as exc:
    await websocket.send_text(json.dumps({"type": "error", "message": str(exc)}))


@app.get("/health")
def health() -> dict[str, Any]:
  whisper_bin = resolve_whisper_binary()
  whisper_model = resolve_whisper_model()
  return {
    "ok": True,
    "service": APP_NAME,
    "stt": {
      "provider": "whisper.cpp",
      "binary": whisper_bin,
      "binary_exists": bool(whisper_bin and Path(whisper_bin).exists()),
      "model": str(whisper_model),
      "model_exists": whisper_model.exists(),
    },
    "tts": {
      "provider": "macos-say",
      "binary": shutil.which("say") or "/usr/bin/say",
    },
  }


@app.post("/v2/voice-message/transcribe")
async def transcribe_batch(
  request: Request,
  language: str = Query("en"),
  sample_rate: int = Query(DEFAULT_SAMPLE_RATE),
  channels: int = Query(DEFAULT_CHANNELS),
) -> dict[str, str]:
  audio = await request.body()
  text = await asyncio.to_thread(transcribe_audio, audio, language, sample_rate, channels)
  return {"transcript": text, "language": normalize_language(language)}


@app.websocket("/v2/voice-message/transcribe-stream")
async def transcribe_stream(
  websocket: WebSocket,
  language: str = Query("en"),
  sample_rate: int = Query(DEFAULT_SAMPLE_RATE),
  channels: int = Query(DEFAULT_CHANNELS),
) -> None:
  if not await accept_loopback_websocket(websocket):
    return
  try:
    validate_audio_format(sample_rate, channels)
  except HTTPException as exc:
    await websocket.send_text(json.dumps({"type": "error", "message": str(exc.detail)}))
    await websocket.close(code=1008)
    return
  buffer = bytearray()
  try:
    while True:
      message = await websocket.receive()
      if "bytes" in message and message["bytes"] is not None:
        buffer.extend(message["bytes"])
        if len(buffer) > MAX_AUDIO_BYTES:
          await websocket.send_text(json.dumps({"type": "error", "message": "audio payload too large"}))
          buffer.clear()
      elif "text" in message and message["text"] is not None:
        text = message["text"].strip().lower()
        if text in {"finalize", "flush", "stop"}:
          await flush_websocket_audio(websocket, buffer, language, sample_rate, channels)
        elif text == "ping":
          await websocket.send_text("ping")
  except WebSocketDisconnect:
    return


@app.websocket("/v4/listen")
async def listen_stream(
  websocket: WebSocket,
  language: str = Query("en"),
  sample_rate: int = Query(DEFAULT_SAMPLE_RATE),
  channels: int = Query(DEFAULT_CHANNELS),
) -> None:
  if not await accept_loopback_websocket(websocket):
    return
  try:
    validate_audio_format(sample_rate, channels)
  except HTTPException as exc:
    await websocket.send_text(json.dumps({"type": "error", "message": str(exc.detail)}))
    await websocket.close(code=1008)
    return
  await websocket.send_text(json.dumps({"type": "conversation.started", "source": APP_NAME}))
  buffer = bytearray()
  chunk_target = int(os.environ.get("OMI_LOCAL_SPEECH_STREAM_CHUNK_BYTES", str(sample_rate * channels * 2 * 10)))
  try:
    while True:
      message = await websocket.receive()
      if "bytes" in message and message["bytes"] is not None:
        buffer.extend(message["bytes"])
        if len(buffer) >= chunk_target:
          await flush_websocket_audio(websocket, buffer, language, sample_rate, channels)
      elif "text" in message and message["text"] is not None:
        text = message["text"].strip().lower()
        if text in {"finalize", "flush", "stop"}:
          await flush_websocket_audio(websocket, buffer, language, sample_rate, channels)
        elif text == "ping":
          await websocket.send_text("ping")
  except WebSocketDisconnect:
    return


@app.post("/v1/tts/synthesize")
async def synthesize_tts(request: Request) -> Response:
  payload = await request.json()
  text = str(payload.get("text", "")).strip()
  if not text:
    raise HTTPException(status_code=400, detail="text is required")
  if len(text) > MAX_TTS_CHARS:
    raise HTTPException(status_code=413, detail="text is too long")
  audio = await asyncio.to_thread(run_say_tts, text)
  return Response(content=audio, media_type="audio/aiff")
