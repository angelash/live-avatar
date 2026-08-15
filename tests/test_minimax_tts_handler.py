from __future__ import annotations

import importlib.util
import json
import math
import os
import unittest
from pathlib import Path
from types import SimpleNamespace
from threading import Event
from typing import Any
from unittest.mock import patch

import httpx
import numpy as np

from speech_to_speech.pipeline.messages import AUDIO_RESPONSE_DONE, EndOfResponse, TTSInput


HANDLER_PATH = Path(__file__).parents[1] / "integrations" / "s2s" / "minimax_tts_handler.py"
SPEC = importlib.util.spec_from_file_location("live_avatar_minimax_tts_handler", HANDLER_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
MiniMaxTTSAPIError = MODULE.MiniMaxTTSAPIError
MiniMaxTTSHandler = MODULE.MiniMaxTTSHandler


class FakeResponse:
    def __init__(self, lines: list[str | BaseException], status_code: int = 200) -> None:
        self.lines = lines
        self.status_code = status_code

    def iter_lines(self):
        for item in self.lines:
            if isinstance(item, BaseException):
                raise item
            yield item

    def read(self) -> bytes:
        return b"fake error"


class FakeStreamContext:
    def __init__(self, response: FakeResponse) -> None:
        self.response = response

    def __enter__(self) -> FakeResponse:
        return self.response

    def __exit__(self, *_args: Any) -> None:
        return None


class FakeClient:
    def __init__(self, responses: list[FakeResponse]) -> None:
        self.responses = responses
        self.calls: list[dict[str, Any]] = []
        self.closed = False

    def stream(self, method: str, url: str, **kwargs: Any) -> FakeStreamContext:
        self.calls.append({"method": method, "url": url, **kwargs})
        return FakeStreamContext(self.responses.pop(0))

    def close(self) -> None:
        self.closed = True


def sse(audio: bytes = b"", *, status: int = 1, code: int = 0) -> str:
    payload = {
        "data": {"audio": audio.hex(), "status": status},
        "trace_id": "trace-for-test",
        "base_resp": {"status_code": code, "status_msg": "test status"},
    }
    return "data: " + json.dumps(payload)


class MiniMaxTTSHandlerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.env = patch.dict(os.environ, {"MINIMAX_API_KEY": "test-key"})
        self.env.start()
        self.handler = object.__new__(MiniMaxTTSHandler)
        self.handler.setup(Event())
        self.handler.client.close()

    def tearDown(self) -> None:
        self.handler.cleanup()
        self.env.stop()

    def test_build_request_uses_pipeline_native_pcm(self) -> None:
        request = self.handler._build_request("你好")
        self.assertIs(request["stream"], True)
        self.assertIs(request["stream_options"]["exclude_aggregated_audio"], True)
        self.assertEqual(
            request["audio_setting"],
            {"sample_rate": 16000, "format": "pcm", "channel": 1},
        )
        self.assertEqual(request["output_format"], "hex")

    def test_session_voice_is_used_for_next_request(self) -> None:
        runtime_config = SimpleNamespace(
            session=SimpleNamespace(
                audio=SimpleNamespace(
                    output=SimpleNamespace(voice="Chinese (Mandarin)_Warm_Girl")
                )
            )
        )
        tts_input = TTSInput.model_construct(text="你好", runtime_config=runtime_config)
        voice = self.handler._voice_for_input(tts_input)

        self.assertEqual(voice, "Chinese (Mandarin)_Warm_Girl")
        self.assertEqual(
            self.handler._build_request("你好", voice)["voice_setting"]["voice_id"],
            "Chinese (Mandarin)_Warm_Girl",
        )

    def test_unknown_session_voice_falls_back_to_configured_voice(self) -> None:
        runtime_config = SimpleNamespace(
            session=SimpleNamespace(
                audio=SimpleNamespace(output=SimpleNamespace(voice="not-a-minimax-voice"))
            )
        )
        tts_input = TTSInput.model_construct(text="你好", runtime_config=runtime_config)
        self.assertEqual(self.handler._voice_for_input(tts_input), self.handler.voice)

    def test_process_streams_fixed_int16_blocks(self) -> None:
        samples = np.arange(700, dtype=np.int16)
        first = samples[:400].astype("<i2").tobytes()
        second = samples[400:].astype("<i2").tobytes()
        self.handler.client = FakeClient(
            [FakeResponse([sse(first), sse(second, status=2), "data: [DONE]"])]
        )

        chunks = list(self.handler.process(TTSInput(text="你好")))

        self.assertEqual(self.handler.blocksize, 320)
        self.assertEqual(len(chunks), math.ceil(len(samples) / self.handler.blocksize))
        self.assertTrue(all(chunk.dtype == np.int16 for chunk in chunks))
        self.assertTrue(all(len(chunk) == self.handler.blocksize for chunk in chunks))
        rendered = np.concatenate(chunks)
        np.testing.assert_array_equal(rendered[: len(samples)], samples)
        self.assertEqual(np.count_nonzero(rendered[len(samples) :]), 0)

        call = self.handler.client.calls[0]
        self.assertEqual(call["method"], "POST")
        self.assertEqual(call["headers"]["Authorization"], "Bearer test-key")
        self.assertEqual(call["json"]["text"], "你好")

    def test_api_error_preserves_code_and_trace(self) -> None:
        self.handler.max_retries = 0
        self.handler.client = FakeClient([FakeResponse([sse(code=1004)])])

        with self.assertRaisesRegex(MiniMaxTTSAPIError, "1004") as caught:
            list(self.handler.process(TTSInput(text="你好")))

        self.assertEqual(caught.exception.trace_id, "trace-for-test")

    def test_transport_error_retries_only_before_audio(self) -> None:
        self.handler.max_retries = 1
        samples = np.arange(self.handler.blocksize, dtype=np.int16).astype("<i2").tobytes()
        self.handler.client = FakeClient(
            [
                FakeResponse([httpx.ReadTimeout("temporary timeout")]),
                FakeResponse([sse(samples, status=2)]),
            ]
        )

        chunks = list(self.handler.process(TTSInput(text="重试")))

        self.assertEqual(len(chunks), 1)
        self.assertEqual(len(self.handler.client.calls), 2)

    def test_end_of_response_emits_audio_done(self) -> None:
        result = list(self.handler.process(EndOfResponse()))
        self.assertEqual(result, [AUDIO_RESPONSE_DONE])

    def test_missing_key_fails_without_network(self) -> None:
        with patch.dict(os.environ, {"MINIMAX_API_KEY": ""}):
            instance = object.__new__(MiniMaxTTSHandler)
            with self.assertRaisesRegex(RuntimeError, "MINIMAX_API_KEY"):
                instance.setup(Event())


if __name__ == "__main__":
    unittest.main()
