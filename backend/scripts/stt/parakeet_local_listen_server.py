import argparse
import asyncio
import json
import logging
import time
import uuid

import websockets

logger = logging.getLogger(__name__)


def _segment(text: str, duration: float) -> dict:
    now = time.time()
    return {
        'id': str(uuid.uuid4()),
        'text': text,
        'speaker': 'SPEAKER_0',
        'speaker_id': 0,
        'is_user': False,
        'person_id': None,
        'start': max(0.0, now - duration),
        'end': now,
        'translations': None,
    }


async def _proxy_client(client_ws, parakeet_url: str):
    async with websockets.connect(parakeet_url, max_size=20 * 1024 * 1024) as parakeet_ws:
        ready = json.loads(await parakeet_ws.recv())
        if ready.get('type') != 'ready':
            await client_ws.close(code=1011, reason='Parakeet server not ready')
            return

        await client_ws.send(json.dumps({'type': 'status', 'status': 'ready'}))

        async def client_to_parakeet():
            async for message in client_ws:
                if isinstance(message, bytes):
                    await parakeet_ws.send(message)
                elif isinstance(message, str) and message.strip() == 'finalize':
                    await parakeet_ws.send(json.dumps({'type': 'flush'}))

        async def parakeet_to_client():
            async for raw in parakeet_ws:
                event = json.loads(raw)
                event_type = event.get('type')
                if event_type == 'segment':
                    text = (event.get('text') or '').strip()
                    if text:
                        await client_ws.send(json.dumps([_segment(text, float(event.get('duration') or 0.0))]))
                elif event_type == 'error':
                    await client_ws.send(json.dumps({'type': 'error', 'message': event.get('message')}))

        tasks = [asyncio.create_task(client_to_parakeet()), asyncio.create_task(parakeet_to_client())]
        done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        for task in pending:
            task.cancel()
        for task in done:
            task.result()


async def _handler(client_ws, path: str, parakeet_url: str):
    if not path.startswith('/v4/listen') and not path.startswith('/v2/voice-message/transcribe-stream'):
        await client_ws.close(code=1008, reason='Unsupported path')
        return
    try:
        await _proxy_client(client_ws, parakeet_url)
    except websockets.ConnectionClosed:
        return
    except Exception as e:
        logger.exception('Local Parakeet listen proxy failed: %s', e)
        try:
            await client_ws.close(code=1011, reason='Local Parakeet proxy failed')
        except Exception:
            pass


async def main():
    parser = argparse.ArgumentParser(description='Local /v4/listen proxy for parakeet-stream.')
    parser.add_argument('--host', default='127.0.0.1')
    parser.add_argument('--port', type=int, default=8001)
    parser.add_argument('--parakeet-url', default='ws://127.0.0.1:8765')
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
    logger.info('Listening on ws://%s:%s, proxying to %s', args.host, args.port, args.parakeet_url)
    async with websockets.serve(
        lambda ws, path: _handler(ws, path, args.parakeet_url),
        args.host,
        args.port,
        max_size=20 * 1024 * 1024,
    ):
        await asyncio.Future()


if __name__ == '__main__':
    asyncio.run(main())
