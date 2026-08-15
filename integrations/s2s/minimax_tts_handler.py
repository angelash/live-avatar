from __future__ import annotations

import json
import logging
import os
from threading import Event
from time import perf_counter
from typing import Any, Iterator

import httpx
import numpy as np
from rich.console import Console

from speech_to_speech.baseHandler import BaseHandler
from speech_to_speech.pipeline.cancel_scope import CancelScope
from speech_to_speech.pipeline.handler_types import TTSIn, TTSOut
from speech_to_speech.pipeline.messages import AUDIO_RESPONSE_DONE, EndOfResponse
from speech_to_speech.pipeline.speculative_turns import SpeculativeTurnTracker

logger = logging.getLogger(__name__)
console = Console()

_PIPELINE_SAMPLE_RATE = 16000
_SUPPORTED_EMOTIONS = {
    "happy",
    "sad",
    "angry",
    "fearful",
    "disgusted",
    "surprised",
    "calm",
    "fluent",
    "whisper",
}
_SELECTABLE_VOICES = {
    "Chinese (Mandarin)_Gentle_Senior",
    "Chinese (Mandarin)_Warm_Girl",
    "Chinese (Mandarin)_Soft_Girl",
    "qiaopi_mengmei",
    "wumei_yujie",
}


class MiniMaxTTSAPIError(RuntimeError):
    """MiniMax returned a successful HTTP response with an API error code."""

    def __init__(self, code: int, message: str, trace_id: str = "") -> None:
        suffix = f" trace_id={trace_id}" if trace_id else ""
        super().__init__(f"MiniMax TTS API error {code}: {message}{suffix}")
        self.code = code
        self.trace_id = trace_id


def _clamped_env_float(name: str, default: float, minimum: float, maximum: float) -> float:
    raw = os.environ.get(name, "").strip()
    value = default if not raw else float(raw)
    return max(minimum, min(maximum, value))


def _clamped_env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, "").strip()
    value = default if not raw else int(raw)
    return max(minimum, min(maximum, value))


class MiniMaxTTSHandler(BaseHandler[TTSIn, TTSOut]):
    """Stream MiniMax T2A v2 PCM into the pipeline's native 16 kHz format."""

    def setup(
        self,
        should_listen: Event,
        cancel_scope: CancelScope | None = None,
        speculative_turns: SpeculativeTurnTracker | None = None,
    ) -> None:
        self.should_listen = should_listen
        self.cancel_scope = cancel_scope
        self.speculative_turns = speculative_turns

        self.api_key = os.environ.get("MINIMAX_API_KEY", "").strip()
        if not self.api_key:
            raise RuntimeError(
                "MINIMAX_API_KEY is required when TTS_ENGINE=minimax. "
                "Put it in scripts/config.local.bat; do not commit it."
            )

        self.base_url = os.environ.get(
            "MINIMAX_TTS_BASE_URL", "https://api.minimaxi.com/v1/t2a_v2"
        ).strip()
        self.model = os.environ.get("MINIMAX_TTS_MODEL", "speech-2.8-turbo").strip()
        self.voice = os.environ.get(
            "MINIMAX_TTS_VOICE", "Chinese (Mandarin)_Warm_Girl"
        ).strip()
        self.speed = _clamped_env_float("MINIMAX_TTS_SPEED", 1.0, 0.5, 2.0)
        self.volume = _clamped_env_float("MINIMAX_TTS_VOLUME", 1.0, 0.1, 10.0)
        self.pitch = _clamped_env_int("MINIMAX_TTS_PITCH", 0, -12, 12)
        # LiveTalking consumes 320-sample (20 ms) frames and historically
        # discarded the remainder of each HTTP packet. Emit that native frame
        # size so every sample reaches both playback and lip-sync unchanged.
        self.blocksize = _clamped_env_int("MINIMAX_TTS_BLOCKSIZE", 320, 320, 3200)
        self.max_retries = _clamped_env_int("MINIMAX_TTS_MAX_RETRIES", 1, 0, 3)

        emotion = os.environ.get("MINIMAX_TTS_EMOTION", "").strip().lower()
        if emotion and emotion not in _SUPPORTED_EMOTIONS:
            supported = ", ".join(sorted(_SUPPORTED_EMOTIONS))
            raise RuntimeError(f"Unsupported MINIMAX_TTS_EMOTION={emotion!r}; use one of: {supported}")
        self.emotion = emotion

        connect_timeout = _clamped_env_float("MINIMAX_TTS_CONNECT_TIMEOUT", 10.0, 1.0, 60.0)
        read_timeout = _clamped_env_float("MINIMAX_TTS_READ_TIMEOUT", 30.0, 2.0, 120.0)
        self.client = httpx.Client(
            timeout=httpx.Timeout(
                connect=connect_timeout,
                read=read_timeout,
                write=connect_timeout,
                pool=connect_timeout,
            ),
            limits=httpx.Limits(max_connections=2, max_keepalive_connections=1),
        )
        logger.info(
            "MiniMax TTS ready: model=%s voice=%s speed=%.2f emotion=%s",
            self.model,
            self.voice,
            self.speed,
            self.emotion or "auto",
        )

    def _voice_for_input(self, tts_input: TTSIn) -> str:
        session_voice: str | None = None
        response = getattr(tts_input, "response", None)
        response_audio = getattr(response, "audio", None)
        response_output = getattr(response_audio, "output", None)
        response_voice = getattr(response_output, "voice", None)
        if response_voice:
            session_voice = str(response_voice)

        runtime_config = getattr(tts_input, "runtime_config", None)
        if not session_voice and runtime_config is not None:
            session = getattr(runtime_config, "session", None)
            audio = getattr(session, "audio", None)
            output = getattr(audio, "output", None)
            configured_voice = getattr(output, "voice", None)
            if configured_voice:
                session_voice = str(configured_voice)

        if not session_voice or session_voice == self.voice:
            return self.voice
        if session_voice in _SELECTABLE_VOICES:
            return session_voice
        logger.warning("Ignoring unsupported MiniMax session voice %r", session_voice)
        return self.voice

    def _build_request(self, text: str, voice: str | None = None) -> dict[str, Any]:
        voice_setting: dict[str, Any] = {
            "voice_id": voice or self.voice,
            "speed": self.speed,
            "vol": self.volume,
            "pitch": self.pitch,
        }
        if self.emotion:
            voice_setting["emotion"] = self.emotion

        return {
            "model": self.model,
            "text": text,
            "stream": True,
            "stream_options": {"exclude_aggregated_audio": True},
            "voice_setting": voice_setting,
            "audio_setting": {
                "sample_rate": _PIPELINE_SAMPLE_RATE,
                "format": "pcm",
                "channel": 1,
            },
            "subtitle_enable": False,
            "output_format": "hex",
            "aigc_watermark": False,
        }

    @staticmethod
    def _parse_sse_line(line: str) -> dict[str, Any] | None:
        stripped = line.strip()
        if not stripped or stripped.startswith(":"):
            return None
        if stripped.startswith("data:"):
            stripped = stripped[5:].strip()
        if stripped == "[DONE]":
            return None
        if not stripped.startswith("{"):
            return None
        try:
            value = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"MiniMax TTS returned malformed SSE JSON: {exc}") from exc
        if not isinstance(value, dict):
            raise RuntimeError("MiniMax TTS returned a non-object SSE payload")
        return value

    @staticmethod
    def _decode_pcm_hex(value: str) -> bytes:
        if len(value) % 2:
            raise RuntimeError("MiniMax TTS returned odd-length PCM hex")
        try:
            return bytes.fromhex(value)
        except ValueError as exc:
            raise RuntimeError("MiniMax TTS returned invalid PCM hex") from exc

    def _stream_pcm(
        self, text: str, generation: int | None, voice: str | None = None
    ) -> Iterator[bytes]:
        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
        }
        request = self._build_request(text, voice)

        for attempt in range(self.max_retries + 1):
            emitted_audio = False
            try:
                with self.client.stream("POST", self.base_url, headers=headers, json=request) as response:
                    if response.status_code >= 400:
                        detail = response.read().decode("utf-8", errors="replace").strip()
                        if len(detail) > 500:
                            detail = detail[:500] + "..."
                        raise RuntimeError(f"MiniMax TTS HTTP {response.status_code}: {detail}")

                    for line in response.iter_lines():
                        if generation is not None and self.cancel_scope and self.cancel_scope.is_stale(generation):
                            logger.info("MiniMax TTS generation cancelled (interruption)")
                            return

                        payload = self._parse_sse_line(line)
                        if payload is None:
                            continue

                        base_resp = payload.get("base_resp") or {}
                        code = int(base_resp.get("status_code") or 0)
                        if code:
                            raise MiniMaxTTSAPIError(
                                code,
                                str(base_resp.get("status_msg") or "unknown error"),
                                str(payload.get("trace_id") or ""),
                            )

                        audio_hex = str((payload.get("data") or {}).get("audio") or "")
                        if audio_hex:
                            pcm = self._decode_pcm_hex(audio_hex)
                            if pcm:
                                emitted_audio = True
                                yield pcm
                return
            except MiniMaxTTSAPIError:
                raise
            except (httpx.HTTPError, RuntimeError) as exc:
                if emitted_audio or attempt >= self.max_retries:
                    raise
                logger.warning(
                    "MiniMax TTS request failed before audio; retrying (%d/%d): %s",
                    attempt + 1,
                    self.max_retries,
                    exc,
                )

    def process(self, tts_input: TTSIn) -> Iterator[TTSOut]:
        speculative_turns = self.speculative_turns
        if isinstance(tts_input, EndOfResponse):
            if speculative_turns and not speculative_turns.is_latest_after_reopen_grace(
                tts_input.turn_id, tts_input.turn_revision
            ):
                return
            yield AUDIO_RESPONSE_DONE
            return

        if speculative_turns and not speculative_turns.is_latest_after_reopen_grace(
            tts_input.turn_id, tts_input.turn_revision
        ):
            logger.debug("Dropping stale MiniMax TTS input")
            return
        if speculative_turns:
            speculative_turns.commit(tts_input.turn_id, tts_input.turn_revision)

        generation = self.cancel_scope.generation if self.cancel_scope else None
        text = tts_input.text.strip()
        if not text:
            return
        voice = self._voice_for_input(tts_input)

        console.print(f"[green]ASSISTANT: {text}")
        started = perf_counter()
        first_audio_at: float | None = None
        total_bytes = 0
        audio_buffer = bytearray()
        block_bytes = self.blocksize * 2

        for pcm in self._stream_pcm(text, generation, voice):
            if first_audio_at is None:
                first_audio_at = perf_counter()
                logger.info("MiniMax TTS TTFA: %.3fs", first_audio_at - started)
            audio_buffer.extend(pcm)
            total_bytes += len(pcm)

            while len(audio_buffer) >= block_bytes:
                if generation is not None and self.cancel_scope and self.cancel_scope.is_stale(generation):
                    return
                block = bytes(audio_buffer[:block_bytes])
                del audio_buffer[:block_bytes]
                yield np.frombuffer(block, dtype="<i2").copy()

        if not total_bytes:
            if generation is not None and self.cancel_scope and self.cancel_scope.is_stale(generation):
                return
            raise RuntimeError("MiniMax TTS completed without audio")
        if len(audio_buffer) % 2:
            raise RuntimeError("MiniMax TTS returned an invalid PCM byte count")
        if audio_buffer:
            final = np.frombuffer(bytes(audio_buffer), dtype="<i2").copy()
            if len(final) < self.blocksize:
                final = np.pad(final, (0, self.blocksize - len(final)))
            yield final

        logger.info(
            "MiniMax TTS streamed %.2fs audio in %.3fs (voice=%s)",
            total_bytes / (_PIPELINE_SAMPLE_RATE * 2),
            perf_counter() - started,
            voice,
        )

    def cleanup(self) -> None:
        self.client.close()
