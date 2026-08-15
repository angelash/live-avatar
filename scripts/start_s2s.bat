@echo off
rem ============================================================
rem  live-avatar - s2s backend launcher
rem
rem  Starts the speech-to-speech pipeline (VAD+STT+LLM+TTS) on :8765.
rem  The LLM talks to llama.cpp (:8080), audio is forwarded to the
rem  LiveTalking avatar (:8010) for lip-sync.
rem
rem  Required env:
rem    S2S_DIR     - s2s project root (where .venv and src live)
rem  Optional:
rem    LIVETALKING_URL   - avatar endpoint (default http://127.0.0.1:8010)
rem    LLM_URL           - llama.cpp OpenAI-compatible URL (default http://127.0.0.1:8080/v1)
rem    LLM_MODEL_NAME    - model alias (default qwen3.5-9b)
rem    S2S_HOST          - realtime WebSocket bind address (default 127.0.0.1)
rem    STT_DEVICE        - faster-whisper device (default cuda)
rem    STT_COMPUTE_TYPE  - faster-whisper precision (default float16)
rem    TTS_ENGINE        - qwen3, minimax, or windows (default qwen3)
rem    TTS_MODEL_NAME    - Qwen3-TTS model id (default 1.7B CustomVoice)
rem    TTS_DEVICE        - Qwen3-TTS device (default cuda)
rem    TTS_BACKEND       - Qwen3-TTS backend (default torch)
rem    WINDOWS_TTS_VOICE - installed Windows voice (default Microsoft Huihui Desktop)
rem    WINDOWS_TTS_RATE  - speaking rate from -10 to 10 (default -1)
rem    WINDOWS_TTS_VOLUME - volume from 0 to 100 (default 95)
rem    MINIMAX_API_KEY   - required when TTS_ENGINE=minimax
rem    MINIMAX_TTS_BASE_URL - regional API endpoint (default mainland China)
rem    MINIMAX_TTS_MODEL - MiniMax speech model (default speech-2.8-turbo)
rem    MINIMAX_TTS_VOICE - MiniMax voice id (default Gentle Senior)
rem    MINIMAX_TTS_SPEED - speaking rate from 0.5 to 2.0 (default 1.0)
rem    MINIMAX_TTS_EMOTION - optional emotion such as happy, calm, or fluent
rem    MINIMAX_TTS_BLOCKSIZE - PCM samples per block (keep 320 for LiveTalking)
rem ============================================================
@echo off
chcp 65001 > nul

if "%S2S_DIR%"=="" (
  echo [ERROR] S2S_DIR not set. Edit scripts\start_all.bat first.
  exit /b 1
)
if not exist "%S2S_DIR%\.venv\Scripts\python.exe" (
  echo [ERROR] s2s venv not found at %S2S_DIR%\.venv
  exit /b 1
)

set LIVETALKING_URL=%LIVETALKING_URL: =%
if "%LIVETALKING_URL%"=="" set LIVETALKING_URL=http://127.0.0.1:8010
set LLM_URL=%LLM_URL: =%
if "%LLM_URL%"=="" set LLM_URL=http://127.0.0.1:8080/v1
set LLM_MODEL_NAME=%LLM_MODEL_NAME: =%
if "%LLM_MODEL_NAME%"=="" set LLM_MODEL_NAME=qwen3.5-9b
set S2S_HOST=%S2S_HOST: =%
if "%S2S_HOST%"=="" set S2S_HOST=127.0.0.1
set STT_LANG=%STT_LANG: =%
if "%STT_LANG%"=="" set STT_LANG=zh
set STT_DEVICE=%STT_DEVICE: =%
if "%STT_DEVICE%"=="" set STT_DEVICE=cuda
set STT_COMPUTE_TYPE=%STT_COMPUTE_TYPE: =%
if "%STT_COMPUTE_TYPE%"=="" set STT_COMPUTE_TYPE=float16
set TTS_ENGINE=%TTS_ENGINE: =%
if "%TTS_ENGINE%"=="" set TTS_ENGINE=qwen3
set TTS_MODEL_NAME=%TTS_MODEL_NAME: =%
if "%TTS_MODEL_NAME%"=="" set TTS_MODEL_NAME=Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice
set TTS_DEVICE=%TTS_DEVICE: =%
if "%TTS_DEVICE%"=="" set TTS_DEVICE=cuda
set TTS_BACKEND=%TTS_BACKEND: =%
if "%TTS_BACKEND%"=="" set TTS_BACKEND=torch
if "%WINDOWS_TTS_VOICE%"=="" set "WINDOWS_TTS_VOICE=Microsoft Huihui Desktop"
if "%WINDOWS_TTS_RATE%"=="" set "WINDOWS_TTS_RATE=-1"
if "%WINDOWS_TTS_VOLUME%"=="" set "WINDOWS_TTS_VOLUME=95"
if "%MINIMAX_TTS_MODEL%"=="" set "MINIMAX_TTS_MODEL=speech-2.8-turbo"
if "%MINIMAX_TTS_VOICE%"=="" set "MINIMAX_TTS_VOICE=Chinese (Mandarin)_Warm_Girl"
if "%MINIMAX_TTS_SPEED%"=="" set "MINIMAX_TTS_SPEED=1.0"
if /I "%TTS_ENGINE%"=="minimax" if "%MINIMAX_API_KEY%"=="" (
  echo [ERROR] MINIMAX_API_KEY is required when TTS_ENGINE=minimax.
  echo Put it in scripts\config.local.bat. Do not commit or share the key.
  exit /b 1
)

if "%HF_ENDPOINT%"=="" set HF_ENDPOINT=https://huggingface.co
set LIVETALKING_URL=%LIVETALKING_URL%

cd /d "%S2S_DIR%"
start "s2s-backend" .venv\Scripts\python.exe -u -m speech_to_speech.s2s_pipeline ^
  --mode realtime ^
  --ws_host "%S2S_HOST%" ^
  --stt faster-whisper ^
  --llm_backend chat-completions ^
  --tts "%TTS_ENGINE%" ^
  --model_name "%LLM_MODEL_NAME%" ^
  --responses_api_base_url "%LLM_URL%" ^
  --responses_api_api_key "dummy" ^
  --language %STT_LANG% ^
  --faster_whisper_stt_model_name "base" ^
  --faster_whisper_stt_device "%STT_DEVICE%" ^
  --faster_whisper_stt_compute_type "%STT_COMPUTE_TYPE%" ^
  --faster_whisper_stt_gen_language "%STT_LANG%" ^
  --qwen3_tts_model_name "%TTS_MODEL_NAME%" ^
  --qwen3_tts_backend "%TTS_BACKEND%" ^
  --qwen3_tts_device "%TTS_DEVICE%" ^
  --thresh 0.8 ^
  --min_silence_ms 600 ^
  --min_speech_ms 500 ^
  --log_level INFO
