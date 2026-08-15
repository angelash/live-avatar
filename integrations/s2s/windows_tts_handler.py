from __future__ import annotations

import base64
import logging
import os
import subprocess
import sys
from threading import Event
from time import perf_counter
from typing import Iterator

import numpy as np
from rich.console import Console

from speech_to_speech.baseHandler import BaseHandler
from speech_to_speech.pipeline.cancel_scope import CancelScope
from speech_to_speech.pipeline.handler_types import TTSIn, TTSOut
from speech_to_speech.pipeline.messages import AUDIO_RESPONSE_DONE, EndOfResponse
from speech_to_speech.pipeline.speculative_turns import SpeculativeTurnTracker

logger = logging.getLogger(__name__)
console = Console()

_POWERSHELL_SCRIPT = r"""
$ErrorActionPreference = 'Stop'
[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Speech | Out-Null
$text = [Console]::In.ReadToEnd()
$voiceName = $env:LIVE_AVATAR_WINDOWS_TTS_VOICE
$rate = [int]$env:LIVE_AVATAR_WINDOWS_TTS_RATE
$volume = [int]$env:LIVE_AVATAR_WINDOWS_TTS_VOLUME
$synth = [System.Speech.Synthesis.SpeechSynthesizer]::new()
$stream = [System.IO.MemoryStream]::new()
try {
    $synth.SelectVoice($voiceName)
    $synth.Rate = $rate
    $synth.Volume = $volume
    $format = [System.Speech.AudioFormat.SpeechAudioFormatInfo]::new(
        16000,
        [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen,
        [System.Speech.AudioFormat.AudioChannel]::Mono
    )
    $synth.SetOutputToAudioStream($stream, $format)
    $synth.Speak($text)
    $bytes = $stream.ToArray()
    [Console]::OpenStandardOutput().Write($bytes, 0, $bytes.Length)
}
finally {
    $synth.Dispose()
    $stream.Dispose()
}
"""
_ENCODED_SCRIPT = base64.b64encode(_POWERSHELL_SCRIPT.encode("utf-16le")).decode("ascii")


class WindowsTTSHandler(BaseHandler[TTSIn, TTSOut]):
    """Windows System.Speech adapter that emits pipeline-native 16 kHz PCM."""

    def setup(
        self,
        should_listen: Event,
        cancel_scope: CancelScope | None = None,
        speculative_turns: SpeculativeTurnTracker | None = None,
    ) -> None:
        if sys.platform != "win32":
            raise RuntimeError("Windows TTS is only available on Windows")

        self.should_listen = should_listen
        self.cancel_scope = cancel_scope
        self.speculative_turns = speculative_turns
        self.voice = os.environ.get("WINDOWS_TTS_VOICE", "Microsoft Huihui Desktop")
        self.rate = max(-10, min(10, int(os.environ.get("WINDOWS_TTS_RATE", "-1"))))
        self.volume = max(0, min(100, int(os.environ.get("WINDOWS_TTS_VOLUME", "95"))))
        self.blocksize = max(128, int(os.environ.get("WINDOWS_TTS_BLOCKSIZE", "512")))

        started = perf_counter()
        warmup = self._synthesize("你好")
        logger.info(
            "Windows TTS ready: voice=%s rate=%d volume=%d warmup=%.3fs bytes=%d",
            self.voice,
            self.rate,
            self.volume,
            perf_counter() - started,
            len(warmup),
        )

    def _synthesize(self, text: str) -> bytes:
        env = os.environ.copy()
        env["LIVE_AVATAR_WINDOWS_TTS_VOICE"] = self.voice
        env["LIVE_AVATAR_WINDOWS_TTS_RATE"] = str(self.rate)
        env["LIVE_AVATAR_WINDOWS_TTS_VOLUME"] = str(self.volume)
        completed = subprocess.run(
            [
                "powershell.exe",
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-EncodedCommand",
                _ENCODED_SCRIPT,
            ],
            input=text.encode("utf-8"),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=60,
            creationflags=subprocess.CREATE_NO_WINDOW,
            check=False,
        )
        if completed.returncode != 0:
            detail = completed.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"Windows TTS failed ({completed.returncode}): {detail}")
        if not completed.stdout:
            raise RuntimeError("Windows TTS produced no audio")
        if len(completed.stdout) % 2:
            raise RuntimeError("Windows TTS returned an invalid PCM byte count")
        return completed.stdout

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
            logger.debug("Dropping stale Windows TTS input")
            return
        if speculative_turns:
            speculative_turns.commit(tts_input.turn_id, tts_input.turn_revision)

        generation = self.cancel_scope.generation if self.cancel_scope else None
        text = tts_input.text.strip()
        if not text:
            return

        console.print(f"[green]ASSISTANT: {text}")
        started = perf_counter()
        pcm = self._synthesize(text)
        logger.info("Windows TTS generated %.2fs audio in %.3fs", len(pcm) / 32000, perf_counter() - started)

        if generation is not None and self.cancel_scope and self.cancel_scope.is_stale(generation):
            logger.info("Windows TTS generation cancelled (interruption)")
            return

        audio = np.frombuffer(pcm, dtype="<i2").copy()
        for offset in range(0, len(audio), self.blocksize):
            if generation is not None and self.cancel_scope and self.cancel_scope.is_stale(generation):
                return
            chunk = audio[offset : offset + self.blocksize]
            if len(chunk) < self.blocksize:
                chunk = np.pad(chunk, (0, self.blocksize - len(chunk)))
            yield chunk
