from __future__ import annotations

import asyncio
import io
import ipaddress
import json
import os
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import wave
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, Response

try:
  import numpy as np
except ImportError:  # Optional Kokoro dependency.
  np = None

try:
  from kokoro_onnx import Kokoro
except ImportError:  # Optional Kokoro dependency.
  Kokoro = None


APP_NAME = "omi-local-speech"
DEFAULT_SAMPLE_RATE = 16_000
DEFAULT_CHANNELS = 1
DEFAULT_TRANSCRIPTION_LANGUAGE = os.environ.get("OMI_LOCAL_DEFAULT_TRANSCRIPTION_LANGUAGE", "auto").strip() or "auto"
MAX_AUDIO_BYTES = int(os.environ.get("OMI_LOCAL_SPEECH_MAX_AUDIO_BYTES", str(20 * 1024 * 1024)))
MAX_TTS_CHARS = int(os.environ.get("OMI_LOCAL_SPEECH_MAX_TTS_CHARS", "4000"))
REQUIRE_LOOPBACK = os.environ.get("OMI_LOCAL_SPEECH_REQUIRE_LOOPBACK", "1") != "0"
STARTED_AT = time.time()


def env_flag(name: str) -> bool:
  return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


def env_int(name: str, default: int, minimum: int = 1) -> int:
  raw = os.environ.get(name)
  if not raw:
    return default
  try:
    return max(minimum, int(raw))
  except ValueError:
    return default


def env_float(name: str, default: float, minimum: float = 0.0) -> float:
  raw = os.environ.get(name)
  if not raw:
    return default
  try:
    return max(minimum, float(raw))
  except ValueError:
    return default


STT_MAX_CONCURRENCY = env_int("OMI_LOCAL_STT_MAX_CONCURRENCY", 1)
TTS_MAX_CONCURRENCY = env_int("OMI_LOCAL_TTS_MAX_CONCURRENCY", 2)
QUEUE_TIMEOUT_SECONDS = env_float("OMI_LOCAL_SPEECH_QUEUE_TIMEOUT_SECONDS", 10.0)
WARMUP_ON_START = env_flag("OMI_LOCAL_SPEECH_WARMUP_ON_START")
TTS_PROVIDER = os.environ.get("OMI_LOCAL_TTS_PROVIDER", "say").strip().lower() or "say"
XAI_TTS_VOICES = {"ara", "eve", "leo", "rex", "sal"}
XAI_TTS_LANG_ALIASES = {
  "pt-br": "pt-BR",
  "pt_br": "pt-BR",
  "pt": "pt-BR",
  "pt-pt": "pt-PT",
  "pt_pt": "pt-PT",
  "en-us": "en",
  "en_us": "en",
  "en-gb": "en",
  "en_gb": "en",
  "es-mx": "es-MX",
  "es_mx": "es-MX",
  "es-es": "es-ES",
  "es_es": "es-ES",
}
XAI_TTS_CODECS = {"mp3", "wav", "pcm", "mulaw", "ulaw", "alaw"}
XAI_TTS_SAMPLE_RATES = {8000, 16000, 22050, 24000, 44100, 48000}
XAI_TTS_BIT_RATES = {32000, 64000, 96000, 128000, 192000}

STT_SEMAPHORE = threading.BoundedSemaphore(STT_MAX_CONCURRENCY)
TTS_SEMAPHORE = threading.BoundedSemaphore(TTS_MAX_CONCURRENCY)
METRICS_LOCK = threading.Lock()
KOKORO_LOCK = threading.Lock()
KOKORO_ENGINE: Any | None = None
KOKORO_ENGINE_KEY: tuple[str, str] | None = None
METRICS: dict[str, dict[str, Any]] = {
  "stt": {
    "requests": 0,
    "successes": 0,
    "failures": 0,
    "in_flight": 0,
    "last_seconds": None,
    "last_at": None,
    "last_error": None,
  },
  "tts": {
    "requests": 0,
    "successes": 0,
    "failures": 0,
    "in_flight": 0,
    "last_seconds": None,
    "last_at": None,
    "last_error": None,
  },
  "warmup": {
    "attempted": False,
    "ok": None,
    "seconds": None,
    "last_at": None,
    "last_error": None,
  },
}

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


def default_kokoro_model_path() -> Path:
  return (
    Path.home()
    / "Library"
    / "Application Support"
    / "Omi Local"
    / "models"
    / "kokoro"
    / "kokoro-v1.0.int8.onnx"
  )


def default_kokoro_voices_path() -> Path:
  return (
    Path.home()
    / "Library"
    / "Application Support"
    / "Omi Local"
    / "models"
    / "kokoro"
    / "voices-v1.0.bin"
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


def resolve_kokoro_model() -> Path:
  return Path(os.environ.get("OMI_LOCAL_KOKORO_MODEL_PATH", str(default_kokoro_model_path()))).expanduser()


def resolve_kokoro_voices() -> Path:
  return Path(os.environ.get("OMI_LOCAL_KOKORO_VOICES_PATH", str(default_kokoro_voices_path()))).expanduser()


def model_metadata(path: Path) -> dict[str, Any]:
  exists = path.exists()
  stat = path.stat() if exists else None
  return {
    "path": str(path),
    "exists": exists,
    "size_bytes": stat.st_size if stat else None,
    "modified_at": stat.st_mtime if stat else None,
  }


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
  empty_markers = {"[BLANK_AUDIO]", "[SILENCE]", "[NO_SPEECH]", "(BLANK_AUDIO)", "(SILENCE)"}
  for line in text.splitlines():
    stripped = line.strip()
    if not stripped:
      continue
    if stripped.upper() in empty_markers:
      continue
    lines.append(stripped)
  return " ".join(lines).strip()


def payload_str(payload: dict[str, Any], key: str, env_name: str, default: str) -> str:
  value = payload.get(key)
  if value is None:
    value = os.environ.get(env_name)
  text = str(value if value is not None else default).strip()
  return text or default


def payload_int(payload: dict[str, Any], key: str, env_name: str, default: int) -> int:
  value = payload.get(key)
  if value is None:
    value = os.environ.get(env_name)
  if value is None:
    return default
  try:
    return int(value)
  except (TypeError, ValueError):
    return default


def payload_float(payload: dict[str, Any], key: str, env_name: str, default: float) -> float:
  value = payload.get(key)
  if value is None:
    value = os.environ.get(env_name)
  if value is None:
    return default
  try:
    return float(value)
  except (TypeError, ValueError):
    return default


def payload_bool(payload: dict[str, Any], key: str, env_name: str, default: bool) -> bool:
  value = payload.get(key)
  if value is None:
    value = os.environ.get(env_name)
  if value is None:
    return default
  if isinstance(value, bool):
    return value
  return str(value).strip().lower() in {"1", "true", "yes", "on"}


def mark_started(kind: str) -> None:
  with METRICS_LOCK:
    METRICS[kind]["requests"] += 1
    METRICS[kind]["in_flight"] += 1


def mark_finished(kind: str, started_at: float, error: Exception | None = None) -> None:
  elapsed = round(time.perf_counter() - started_at, 4)
  with METRICS_LOCK:
    METRICS[kind]["in_flight"] = max(0, METRICS[kind]["in_flight"] - 1)
    METRICS[kind]["last_seconds"] = elapsed
    METRICS[kind]["last_at"] = time.time()
    if error is None:
      METRICS[kind]["successes"] += 1
      METRICS[kind]["last_error"] = None
    else:
      METRICS[kind]["failures"] += 1
      METRICS[kind]["last_error"] = str(error)


def mark_warmup(ok: bool, started_at: float, error: Exception | None = None) -> None:
  elapsed = round(time.perf_counter() - started_at, 4)
  with METRICS_LOCK:
    METRICS["warmup"]["attempted"] = True
    METRICS["warmup"]["ok"] = ok
    METRICS["warmup"]["seconds"] = elapsed
    METRICS["warmup"]["last_at"] = time.time()
    METRICS["warmup"]["last_error"] = str(error) if error else None


def metrics_snapshot(kind: str) -> dict[str, Any]:
  with METRICS_LOCK:
    return dict(METRICS[kind])


def acquire_slot(kind: str, semaphore: threading.BoundedSemaphore) -> None:
  if not semaphore.acquire(timeout=QUEUE_TIMEOUT_SECONDS):
    raise HTTPException(status_code=429, detail=f"{kind} queue is full")


def transcribe_audio_unlocked(
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


def transcribe_audio(
  audio: bytes,
  language: str,
  sample_rate: int,
  channels: int,
) -> str:
  acquire_slot("stt", STT_SEMAPHORE)
  started_at = time.perf_counter()
  mark_started("stt")
  try:
    text = transcribe_audio_unlocked(audio, language, sample_rate, channels)
    mark_finished("stt", started_at)
    return text
  except Exception as exc:
    mark_finished("stt", started_at, exc)
    raise
  finally:
    STT_SEMAPHORE.release()


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
  acquire_slot("tts", TTS_SEMAPHORE)
  started_at = time.perf_counter()
  mark_started("tts")
  say_bin = shutil.which("say") or "/usr/bin/say"
  try:
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
      audio = output_path.read_bytes()
      mark_finished("tts", started_at)
      return audio
  except Exception as exc:
    mark_finished("tts", started_at, exc)
    raise
  finally:
    TTS_SEMAPHORE.release()


def get_kokoro_engine() -> Any:
  global KOKORO_ENGINE, KOKORO_ENGINE_KEY

  if Kokoro is None or np is None:
    raise HTTPException(
      status_code=503,
      detail="Kokoro dependencies are not installed. Run desktop/scripts/setup-local-kokoro.sh.",
    )

  model_path = resolve_kokoro_model()
  voices_path = resolve_kokoro_voices()
  if not model_path.exists():
    raise HTTPException(status_code=503, detail=f"Kokoro model not found at {model_path}")
  if not voices_path.exists():
    raise HTTPException(status_code=503, detail=f"Kokoro voices not found at {voices_path}")

  key = (str(model_path), str(voices_path))
  with KOKORO_LOCK:
    if KOKORO_ENGINE is None or KOKORO_ENGINE_KEY != key:
      KOKORO_ENGINE = Kokoro(str(model_path), str(voices_path))
      KOKORO_ENGINE_KEY = key
    return KOKORO_ENGINE


def wav_bytes_from_float_samples(samples: Any, sample_rate: int) -> bytes:
  if np is None:
    raise HTTPException(status_code=503, detail="numpy is required for Kokoro TTS")

  audio = np.asarray(samples, dtype=np.float32).reshape(-1)
  audio = np.clip(audio, -1.0, 1.0)
  pcm = (audio * 32767.0).astype("<i2")

  buffer = io.BytesIO()
  with wave.open(buffer, "wb") as wav_file:
    wav_file.setnchannels(1)
    wav_file.setsampwidth(2)
    wav_file.setframerate(sample_rate)
    wav_file.writeframes(pcm.tobytes())
  return buffer.getvalue()


def run_kokoro_tts(text: str, payload: dict[str, Any]) -> bytes:
  acquire_slot("tts", TTS_SEMAPHORE)
  started_at = time.perf_counter()
  mark_started("tts")
  try:
    voice = payload_str(payload, "voice", "OMI_LOCAL_KOKORO_VOICE", "af_heart")
    lang = payload_str(payload, "lang", "OMI_LOCAL_KOKORO_LANG", "en-us")
    speed = max(0.5, min(2.0, payload_float(payload, "speed", "OMI_LOCAL_KOKORO_SPEED", 1.0)))
    engine = get_kokoro_engine()
    samples, sample_rate = engine.create(text, voice=voice, speed=speed, lang=lang)
    audio = wav_bytes_from_float_samples(samples, sample_rate)
    mark_finished("tts", started_at)
    return audio
  except AssertionError as exc:
    error = HTTPException(status_code=400, detail=str(exc))
    mark_finished("tts", started_at, error)
    raise error
  except Exception as exc:
    mark_finished("tts", started_at, exc)
    raise
  finally:
    TTS_SEMAPHORE.release()


def xai_api_key() -> str:
  api_key = (os.environ.get("XAI_API_KEY") or os.environ.get("OMI_XAI_API_KEY") or "").strip()
  if not api_key:
    raise HTTPException(status_code=503, detail="XAI_API_KEY is required for xAI TTS")
  return api_key


def xai_tts_url() -> str:
  return os.environ.get("OMI_LOCAL_XAI_TTS_URL", "https://api.x.ai/v1/tts").strip() or "https://api.x.ai/v1/tts"


def xai_voice_id(payload: dict[str, Any]) -> str:
  voice = (
    payload.get("xai_voice_id") or os.environ.get("OMI_LOCAL_XAI_TTS_VOICE") or ""
  ).strip().lower()
  if voice in XAI_TTS_VOICES:
    return voice

  generic_voice = str(payload.get("voice") or payload.get("voice_id") or "").strip().lower()
  if generic_voice in XAI_TTS_VOICES:
    return generic_voice

  return "ara"


def xai_language(payload: dict[str, Any]) -> str:
  language = (
    payload.get("xai_language")
    or os.environ.get("OMI_LOCAL_XAI_TTS_LANGUAGE")
    or payload.get("language")
    or payload.get("lang")
    or "auto"
  )
  normalized = str(language).strip()
  if not normalized:
    return "auto"
  return XAI_TTS_LANG_ALIASES.get(normalized.lower(), normalized)


def xai_output_format(payload: dict[str, Any]) -> dict[str, Any]:
  raw_format = payload.get("xai_output_format") or os.environ.get("OMI_LOCAL_XAI_TTS_OUTPUT_FORMAT")
  if raw_format is None and isinstance(payload.get("output_format"), dict):
    raw_format = payload["output_format"]
  if isinstance(raw_format, dict):
    source = raw_format
  elif isinstance(raw_format, str) and raw_format.strip().startswith("{"):
    try:
      source = json.loads(raw_format)
    except json.JSONDecodeError:
      source = {}
  else:
    source = {}

  codec = (
    str(source.get("codec") or os.environ.get("OMI_LOCAL_XAI_TTS_CODEC") or "mp3")
    .strip()
    .lower()
  )
  codec = "mulaw" if codec == "ulaw" else codec
  if codec not in XAI_TTS_CODECS:
    codec = "mp3"

  sample_rate = payload_int(source, "sample_rate", "OMI_LOCAL_XAI_TTS_SAMPLE_RATE", 24000)
  if sample_rate not in XAI_TTS_SAMPLE_RATES:
    sample_rate = 24000

  output: dict[str, Any] = {"codec": codec, "sample_rate": sample_rate}
  if codec == "mp3":
    bit_rate = payload_int(source, "bit_rate", "OMI_LOCAL_XAI_TTS_BIT_RATE", 128000)
    if bit_rate not in XAI_TTS_BIT_RATES:
      bit_rate = 128000
    output["bit_rate"] = bit_rate
  return output


def xai_media_type(output_format: dict[str, Any], content_type: str | None) -> str:
  if content_type:
    media_type = content_type.split(";", 1)[0].strip()
    if media_type.startswith("audio/"):
      return media_type

  codec = str(output_format.get("codec", "mp3")).lower()
  if codec == "mp3":
    return "audio/mpeg"
  if codec == "wav":
    return "audio/wav"
  if codec == "pcm":
    return "audio/pcm"
  if codec == "alaw":
    return "audio/alaw"
  return "audio/basic"


def xai_tts_payload(text: str, payload: dict[str, Any]) -> dict[str, Any]:
  request_payload: dict[str, Any] = {
    "text": text,
    "voice_id": xai_voice_id(payload),
    "language": xai_language(payload),
    "output_format": xai_output_format(payload),
  }

  if payload_bool(payload, "xai_text_normalization", "OMI_LOCAL_XAI_TTS_TEXT_NORMALIZATION", False):
    request_payload["text_normalization"] = True

  optimize_latency = payload_int(
    payload,
    "xai_optimize_streaming_latency",
    "OMI_LOCAL_XAI_TTS_OPTIMIZE_STREAMING_LATENCY",
    0,
  )
  if optimize_latency in {0, 1}:
    request_payload["optimize_streaming_latency"] = optimize_latency
  return request_payload


def run_xai_tts(text: str, payload: dict[str, Any]) -> tuple[bytes, str]:
  acquire_slot("tts", TTS_SEMAPHORE)
  started_at = time.perf_counter()
  mark_started("tts")
  try:
    request_payload = xai_tts_payload(text, payload)
    body = json.dumps(request_payload).encode("utf-8")
    request = urllib.request.Request(
      xai_tts_url(),
      data=body,
      headers={
        "Authorization": f"Bearer {xai_api_key()}",
        "Content-Type": "application/json",
        "Accept": "audio/*",
        "User-Agent": "omi-local-speech/1.0",
      },
      method="POST",
    )
    timeout = env_float("OMI_LOCAL_XAI_TTS_TIMEOUT_SECONDS", 60.0, 1.0)
    with urllib.request.urlopen(request, timeout=timeout) as response:
      audio = response.read()
      if not audio:
        raise HTTPException(status_code=502, detail="xAI TTS returned an empty audio response")
      media_type = xai_media_type(
        request_payload["output_format"],
        response.headers.get("Content-Type"),
      )
      mark_finished("tts", started_at)
      return audio, media_type
  except urllib.error.HTTPError as exc:
    detail = exc.read().decode("utf-8", errors="replace").strip()[-1200:]
    error = HTTPException(status_code=502, detail=f"xAI TTS failed with HTTP {exc.code}: {detail}")
    mark_finished("tts", started_at, error)
    raise error
  except urllib.error.URLError as exc:
    error = HTTPException(status_code=502, detail=f"xAI TTS request failed: {exc.reason}")
    mark_finished("tts", started_at, error)
    raise error
  except TimeoutError as exc:
    error = HTTPException(status_code=504, detail="xAI TTS request timed out")
    mark_finished("tts", started_at, error)
    raise error
  except Exception as exc:
    mark_finished("tts", started_at, exc)
    raise
  finally:
    TTS_SEMAPHORE.release()


def silent_audio(seconds: float = 0.25) -> bytes:
  frame_count = int(DEFAULT_SAMPLE_RATE * DEFAULT_CHANNELS * seconds)
  return b"\0\0" * frame_count


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


async def run_warmup(language: str = DEFAULT_TRANSCRIPTION_LANGUAGE) -> dict[str, Any]:
  started_at = time.perf_counter()
  try:
    text = await asyncio.to_thread(
      transcribe_audio,
      silent_audio(),
      language,
      DEFAULT_SAMPLE_RATE,
      DEFAULT_CHANNELS,
    )
    mark_warmup(True, started_at)
    return {"ok": True, "seconds": metrics_snapshot("warmup")["seconds"], "transcript": text}
  except Exception as exc:
    mark_warmup(False, started_at, exc)
    raise


@app.on_event("startup")
async def warmup_on_start() -> None:
  if WARMUP_ON_START:
    asyncio.create_task(run_warmup())


@app.get("/health")
def health() -> dict[str, Any]:
  whisper_bin = resolve_whisper_binary()
  whisper_model = resolve_whisper_model()
  say_bin = shutil.which("say") or "/usr/bin/say"
  kokoro_model = resolve_kokoro_model()
  kokoro_voices = resolve_kokoro_voices()
  return {
    "ok": True,
    "service": APP_NAME,
    "uptime_seconds": round(time.time() - STARTED_AT, 3),
    "config": {
      "loopback_required": REQUIRE_LOOPBACK,
      "max_audio_bytes": MAX_AUDIO_BYTES,
      "max_tts_chars": MAX_TTS_CHARS,
      "stt_max_concurrency": STT_MAX_CONCURRENCY,
      "tts_max_concurrency": TTS_MAX_CONCURRENCY,
      "queue_timeout_seconds": QUEUE_TIMEOUT_SECONDS,
      "warmup_on_start": WARMUP_ON_START,
      "default_transcription_language": DEFAULT_TRANSCRIPTION_LANGUAGE,
    },
    "stt": {
      "provider": "whisper.cpp",
      "binary": whisper_bin,
      "binary_exists": bool(whisper_bin and Path(whisper_bin).exists()),
      "model": model_metadata(whisper_model),
      "metrics": metrics_snapshot("stt"),
    },
    "tts": {
      "provider": TTS_PROVIDER,
      "binary": say_bin,
      "binary_exists": Path(say_bin).exists(),
      "kokoro_dependencies_available": bool(Kokoro is not None and np is not None),
      "kokoro_model": model_metadata(kokoro_model),
      "kokoro_voices": model_metadata(kokoro_voices),
      "kokoro_loaded": KOKORO_ENGINE is not None,
      "kokoro_default_voice": os.environ.get("OMI_LOCAL_KOKORO_VOICE", "af_heart"),
      "kokoro_default_lang": os.environ.get("OMI_LOCAL_KOKORO_LANG", "en-us"),
      "xai_configured": bool(
        (os.environ.get("XAI_API_KEY") or os.environ.get("OMI_XAI_API_KEY") or "").strip()
      ),
      "xai_url": xai_tts_url(),
      "xai_default_voice": os.environ.get("OMI_LOCAL_XAI_TTS_VOICE", "ara"),
      "xai_default_language": os.environ.get("OMI_LOCAL_XAI_TTS_LANGUAGE", "auto"),
      "xai_default_codec": os.environ.get("OMI_LOCAL_XAI_TTS_CODEC", "mp3"),
      "metrics": metrics_snapshot("tts"),
    },
    "warmup": metrics_snapshot("warmup"),
  }


@app.post("/warmup")
async def warmup(language: str = Query(DEFAULT_TRANSCRIPTION_LANGUAGE)) -> dict[str, Any]:
  return await run_warmup(language=language)


@app.post("/v2/voice-message/transcribe")
async def transcribe_batch(
  request: Request,
  language: str = Query(DEFAULT_TRANSCRIPTION_LANGUAGE),
  sample_rate: int = Query(DEFAULT_SAMPLE_RATE),
  channels: int = Query(DEFAULT_CHANNELS),
) -> dict[str, str]:
  audio = await request.body()
  text = await asyncio.to_thread(transcribe_audio, audio, language, sample_rate, channels)
  return {"transcript": text, "language": normalize_language(language)}


@app.websocket("/v2/voice-message/transcribe-stream")
async def transcribe_stream(
  websocket: WebSocket,
  language: str = Query(DEFAULT_TRANSCRIPTION_LANGUAGE),
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
  except RuntimeError as exc:
    if "disconnect message" in str(exc):
      return
    raise


@app.websocket("/v4/listen")
async def listen_stream(
  websocket: WebSocket,
  language: str = Query(DEFAULT_TRANSCRIPTION_LANGUAGE),
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
  except RuntimeError as exc:
    if "disconnect message" in str(exc):
      return
    raise


@app.post("/v1/tts/synthesize")
async def synthesize_tts(request: Request) -> Response:
  payload = await request.json()
  text = str(payload.get("text", "")).strip()
  if not text:
    raise HTTPException(status_code=400, detail="text is required")
  if len(text) > MAX_TTS_CHARS:
    raise HTTPException(status_code=413, detail="text is too long")
  if TTS_PROVIDER == "xai":
    audio, media_type = await asyncio.to_thread(run_xai_tts, text, payload)
    return Response(content=audio, media_type=media_type)
  if TTS_PROVIDER == "kokoro":
    audio = await asyncio.to_thread(run_kokoro_tts, text, payload)
    return Response(content=audio, media_type="audio/wav")
  if TTS_PROVIDER not in {"say", "macos-say"}:
    raise HTTPException(status_code=503, detail=f"Unsupported TTS provider: {TTS_PROVIDER}")
  audio = await asyncio.to_thread(run_say_tts, text)
  return Response(content=audio, media_type="audio/aiff")
