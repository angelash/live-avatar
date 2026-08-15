from __future__ import annotations

import argparse
import asyncio
import base64
import json
from typing import Any

import httpx
import websockets


class SmokeFailure(RuntimeError):
    pass


async def _receive_json(ws: Any, timeout: float) -> dict[str, Any]:
    raw = await asyncio.wait_for(ws.recv(), timeout)
    if not isinstance(raw, str):
        raw = raw.decode("utf-8")
    event = json.loads(raw)
    if event.get("type") == "error":
        error = event.get("error") or {}
        raise SmokeFailure(error.get("message") or str(error) or "S2S error")
    return event


async def _wait_for(ws: Any, event_type: str, timeout: float) -> dict[str, Any]:
    deadline = asyncio.get_running_loop().time() + timeout
    while True:
        remaining = deadline - asyncio.get_running_loop().time()
        if remaining <= 0:
            raise SmokeFailure(f"Timed out waiting for {event_type}")
        event = await _receive_json(ws, remaining)
        if event.get("type") == event_type:
            return event


async def latest_livetalking_session(base_url: str) -> str:
    async with httpx.AsyncClient(timeout=5) as client:
        response = await client.get(f"{base_url.rstrip('/')}/api/admin/sessions")
        response.raise_for_status()
        sessions = ((response.json().get("data") or {}).get("sessions") or [])
    if not sessions:
        raise SmokeFailure("LiveTalking has no browser session to verify")
    return str(sessions[-1].get("sessionid") or "")


async def verify_livetalking_speaking(base_url: str, session_id: str) -> None:
    deadline = asyncio.get_running_loop().time() + 5
    async with httpx.AsyncClient(timeout=3) as client:
        while asyncio.get_running_loop().time() < deadline:
            response = await client.post(
                f"{base_url.rstrip('/')}/is_speaking", json={"sessionid": session_id}
            )
            body = response.json()
            if response.is_success and body.get("code") == 0 and body.get("data") is True:
                return
            await asyncio.sleep(0.2)
    raise SmokeFailure("S2S audio was not observed in the bound LiveTalking session")


async def run_conversation(
    url: str, voice: str, timeout: float, livetalking_url: str
) -> dict[str, Any]:
    audio_bytes = 0
    transcript = ""
    livetalking_session = (
        await latest_livetalking_session(livetalking_url) if livetalking_url else ""
    )
    async with websockets.connect(url, open_timeout=10, close_timeout=3) as ws:
        await _wait_for(ws, "session.created", 10)
        if livetalking_session:
            await ws.send(
                json.dumps(
                    {
                        "type": "livetalking.session.update",
                        "sessionid": livetalking_session,
                    }
                )
            )
        await ws.send(
            json.dumps(
                {
                    "type": "session.update",
                    "session": {
                        "type": "realtime",
                        "instructions": "只用中文简短回复：部署测试通过。",
                        "audio": {"output": {"voice": voice}},
                    },
                },
                ensure_ascii=False,
            )
        )
        await asyncio.sleep(0.2)
        await ws.send(
            json.dumps(
                {
                    "type": "conversation.item.create",
                    "item": {
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": "请执行部署测试。"}],
                    },
                },
                ensure_ascii=False,
            )
        )
        await ws.send(json.dumps({"type": "response.create"}))

        deadline = asyncio.get_running_loop().time() + timeout
        while True:
            remaining = deadline - asyncio.get_running_loop().time()
            if remaining <= 0:
                raise SmokeFailure("Timed out waiting for response.done")
            event = await _receive_json(ws, remaining)
            event_type = event.get("type")
            if event_type in ("response.audio.delta", "response.output_audio.delta"):
                delta = event.get("delta") or ""
                audio_bytes += len(base64.b64decode(delta))
            elif event_type in (
                "response.audio_transcript.done",
                "response.output_audio_transcript.done",
            ):
                transcript = event.get("transcript") or transcript
            elif event_type == "response.done":
                break

    if audio_bytes <= 0:
        raise SmokeFailure("The response completed without audio bytes")
    if livetalking_session:
        await verify_livetalking_speaking(livetalking_url, livetalking_session)
    return {
        "audio_bytes": audio_bytes,
        "transcript": transcript,
        "voice": voice,
        "livetalking_forwarded": bool(livetalking_session),
    }


async def prove_slot_released(url: str) -> None:
    # A second successful session is the regression check for leaked smoke-test
    # connections and the single-slot "all pipeline slots in use" failure.
    await asyncio.sleep(0.8)
    async with websockets.connect(url, open_timeout=10, close_timeout=3) as ws:
        await _wait_for(ws, "session.created", 10)
    await asyncio.sleep(0.4)


async def async_main(args: argparse.Namespace) -> None:
    result = await run_conversation(
        args.url, args.voice, args.timeout, args.livetalking_url
    )
    await prove_slot_released(args.url)
    print(json.dumps({"ok": True, "slot_released": True, **result}, ensure_ascii=False))


def main() -> None:
    parser = argparse.ArgumentParser(description="End-to-end S2S deployment smoke test")
    parser.add_argument("--url", default="ws://127.0.0.1:8765/v1/realtime")
    parser.add_argument("--voice", default="Chinese (Mandarin)_Warm_Girl")
    parser.add_argument("--timeout", type=float, default=60.0)
    parser.add_argument("--livetalking-url", default="")
    args = parser.parse_args()
    asyncio.run(async_main(args))


if __name__ == "__main__":
    main()
