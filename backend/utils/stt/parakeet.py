import asyncio
import base64
import json
import logging
import os
import queue
import threading
import uuid
from typing import Callable, Optional

import websockets

from utils.byok import get_byok_key

logger = logging.getLogger(__name__)

_STOP = object()
_FINALIZE = object()


def _parakeet_ws_url() -> Optional[str]:
    explicit = os.getenv('PARAKEET_ASR_WS_URL') or os.getenv('NVIDIA_ASR_NIM_WS_URL')
    if explicit:
        return explicit

    base = os.getenv('PARAKEET_ASR_URL') or os.getenv('NVIDIA_ASR_NIM_URL')
    if not base:
        return None

    base = base.rstrip('/')
    base = base.replace('https://', 'wss://', 1).replace('http://', 'ws://', 1)
    return f'{base}/v1/realtime?intent=transcription'


def _parakeet_protocol() -> str:
    return os.getenv('PARAKEET_ASR_PROTOCOL', 'nvidia-nim')


def _parakeet_api_key() -> Optional[str]:
    return get_byok_key('parakeet') or os.getenv('PARAKEET_API_KEY') or os.getenv('NVIDIA_API_KEY')


def _normalize_language(language: str) -> str:
    if not language or language == 'multi':
        return 'en-US'
    if language == 'en':
        return 'en-US'
    return language


def _event_id() -> str:
    return f'event_{uuid.uuid4()}'


def _segments_from_completed_event(event: dict) -> list[dict]:
    words = event.get('words_info', {}).get('words') or []
    if not words:
        transcript = (event.get('transcript') or '').strip()
        if not transcript:
            return []
        return [
            {
                'speaker': 'SPEAKER_0',
                'start': 0.0,
                'end': 0.0,
                'text': transcript,
                'is_user': False,
                'person_id': None,
            }
        ]

    segments = []
    for word in words:
        speaker = f"SPEAKER_{word.get('speaker_tag', 0)}"
        text = word.get('word') or ''
        start = float(word.get('start_time') or 0.0)
        end = float(word.get('end_time') or start)
        if not text:
            continue
        if segments and segments[-1]['speaker'] == speaker:
            segments[-1]['text'] += f' {text}'
            segments[-1]['end'] = end
        else:
            segments.append(
                {
                    'speaker': speaker,
                    'start': start,
                    'end': end,
                    'text': text,
                    'is_user': False,
                    'person_id': None,
                }
            )
    return segments


class ParakeetRealtimeSocket:
    """Synchronous socket facade over NVIDIA ASR NIM's async realtime API."""

    def __init__(
        self,
        stream_transcript: Callable[[list[dict]], None],
        language: str,
        sample_rate: int,
        channels: int,
        model: str,
        is_active: Optional[Callable[[], bool]] = None,
    ):
        self._stream_transcript = stream_transcript
        self._language = _normalize_language(language)
        self._sample_rate = sample_rate
        self._channels = channels
        self._model = model
        self._is_active = is_active
        self._queue: queue.Queue[object] = queue.Queue()
        self._ready = threading.Event()
        self._closed = threading.Event()
        self._dead = False
        self._death_reason: Optional[str] = None
        self._thread = threading.Thread(target=self._run, daemon=True, name='parakeet-realtime')
        self._thread.start()

    @property
    def is_connection_dead(self) -> bool:
        return self._dead

    @property
    def death_reason(self) -> Optional[str]:
        return self._death_reason

    async def wait_ready(self, timeout: float = 10.0) -> bool:
        return await asyncio.to_thread(self._ready.wait, timeout)

    def send(self, data: bytes) -> None:
        if self._closed.is_set() or self._dead:
            return
        self._queue.put(bytes(data))

    def finalize(self) -> None:
        if self._closed.is_set() or self._dead:
            return
        self._queue.put(_FINALIZE)

    def finish(self) -> None:
        if self._closed.is_set():
            return
        self._closed.set()
        self._queue.put(_STOP)
        self._thread.join(timeout=2.0)

    def _mark_dead(self, reason: str) -> None:
        self._death_reason = reason
        self._dead = True
        self._ready.set()
        logger.warning('Parakeet realtime connection dead: %s', reason)

    def _run(self) -> None:
        try:
            asyncio.run(self._run_async())
        except Exception as e:
            self._mark_dead(f'{type(e).__name__}: {e}')

    async def _run_async(self) -> None:
        url = _parakeet_ws_url()
        if not url:
            self._mark_dead('PARAKEET_ASR_WS_URL or NVIDIA_ASR_NIM_URL is not configured')
            return

        if _parakeet_protocol() == 'parakeet-stream':
            await self._run_parakeet_stream_async(url)
            return

        headers = {}
        api_key = _parakeet_api_key()
        if api_key:
            headers['Authorization'] = f'Bearer {api_key}'

        async with websockets.connect(url, extra_headers=headers or None, max_size=16 * 1024 * 1024) as ws:
            await ws.send(json.dumps(self._session_update()))
            self._ready.set()
            sender = asyncio.create_task(self._sender(ws))
            receiver = asyncio.create_task(self._receiver(ws))
            done, pending = await asyncio.wait({sender, receiver}, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            for task in done:
                task.result()

    async def _run_parakeet_stream_async(self, url: str) -> None:
        async with websockets.connect(url, max_size=20 * 1024 * 1024) as ws:
            raw_ready = await ws.recv()
            try:
                ready = json.loads(raw_ready)
            except json.JSONDecodeError:
                self._mark_dead('parakeet-stream sent invalid handshake')
                return
            if ready.get('type') != 'ready':
                self._mark_dead(f"parakeet-stream not ready: {ready}")
                return

            self._ready.set()
            sender = asyncio.create_task(self._parakeet_stream_sender(ws))
            receiver = asyncio.create_task(self._parakeet_stream_receiver(ws))
            done, pending = await asyncio.wait({sender, receiver}, return_when=asyncio.FIRST_COMPLETED)
            for task in pending:
                task.cancel()
            for task in done:
                task.result()

    def _session_update(self) -> dict:
        return {
            'event_id': _event_id(),
            'type': 'transcription_session.update',
            'session': {
                'modalities': ['text'],
                'input_audio_format': 'pcm16',
                'input_audio_transcription': {
                    'language': self._language,
                    'model': self._model,
                    'prompt': '',
                },
                'input_audio_params': {
                    'sample_rate_hz': self._sample_rate,
                    'num_channels': self._channels,
                },
                'recognition_config': {
                    'max_alternatives': 1,
                    'enable_automatic_punctuation': True,
                    'enable_word_time_offsets': True,
                    'enable_profanity_filter': False,
                    'enable_verbatim_transcripts': False,
                },
                'speaker_diarization': {
                    'enable_speaker_diarization': True,
                    'max_speaker_count': 8,
                },
            },
        }

    async def _sender(self, ws) -> None:
        while not self._closed.is_set():
            if self._is_active is not None and not self._is_active():
                await ws.send(json.dumps({'event_id': _event_id(), 'type': 'input_audio_buffer.done'}))
                return
            item = await asyncio.to_thread(self._queue.get)
            if item is _STOP:
                await ws.send(json.dumps({'event_id': _event_id(), 'type': 'input_audio_buffer.done'}))
                return
            if item is _FINALIZE:
                await ws.send(json.dumps({'event_id': _event_id(), 'type': 'input_audio_buffer.commit'}))
                continue

            await ws.send(
                json.dumps(
                    {
                        'event_id': _event_id(),
                        'type': 'input_audio_buffer.append',
                        'audio': base64.b64encode(item).decode('ascii'),
                    }
                )
            )

    async def _receiver(self, ws) -> None:
        async for raw_message in ws:
            try:
                event = json.loads(raw_message)
            except json.JSONDecodeError:
                logger.warning('Parakeet realtime returned non-JSON message')
                continue

            event_type = event.get('type')
            if event_type == 'conversation.item.input_audio_transcription.completed':
                segments = _segments_from_completed_event(event)
                if segments:
                    self._stream_transcript(segments)
            elif event_type == 'conversation.item.input_audio_transcription.failed':
                self._mark_dead(str(event.get('error') or 'transcription failed'))
                return
            elif event_type == 'error':
                self._mark_dead(str(event))
                return

    async def _parakeet_stream_sender(self, ws) -> None:
        while not self._closed.is_set():
            if self._is_active is not None and not self._is_active():
                await ws.send(json.dumps({'type': 'flush'}))
                return
            item = await asyncio.to_thread(self._queue.get)
            if item is _STOP:
                await ws.send(json.dumps({'type': 'flush'}))
                return
            if item is _FINALIZE:
                await ws.send(json.dumps({'type': 'flush'}))
                continue
            await ws.send(item)

    async def _parakeet_stream_receiver(self, ws) -> None:
        async for raw_message in ws:
            try:
                event = json.loads(raw_message)
            except json.JSONDecodeError:
                logger.warning('parakeet-stream returned non-JSON message')
                continue

            event_type = event.get('type')
            if event_type == 'segment':
                text = (event.get('text') or '').strip()
                if text:
                    duration = float(event.get('duration') or 0.0)
                    self._stream_transcript(
                        [
                            {
                                'speaker': 'SPEAKER_0',
                                'start': 0.0,
                                'end': duration,
                                'text': text,
                                'is_user': False,
                                'person_id': None,
                            }
                        ]
                    )
            elif event_type == 'error':
                self._mark_dead(str(event.get('message') or event))
                return


async def process_audio_parakeet(
    stream_transcript,
    language: str,
    sample_rate: int,
    channels: int,
    model: str,
    is_active: Optional[Callable[[], bool]] = None,
):
    logger.info('process_audio_parakeet %s %s %s %s', language, sample_rate, channels, model)
    socket = ParakeetRealtimeSocket(stream_transcript, language, sample_rate, channels, model, is_active=is_active)
    if not await socket.wait_ready():
        socket.finish()
        return None
    if socket.is_connection_dead:
        return None
    return socket
