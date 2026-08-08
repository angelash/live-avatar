@echo off
rem ============================================================
rem  live-avatar - one-click launcher
rem
rem  Edit the CONFIG block below to point at your own installs,
rem  then double-click (or run) this file. It starts all four
rem  services in dependency order:
rem     1) llama-server   :8080  (local LLM)
rem     2) s2s backend    :8765  (speech pipeline)
rem     3) demo page      :7860  (web UI)
rem     4) LiveTalking    :8010  (lip-sync avatar)
rem ============================================================
@echo off
chcp 65001 > nul

rem ─── CONFIG: edit these to match your machine ──────────────────
set "S2S_DIR=C:\path\to\speech-to-speech"
set "LIVETALKING_DIR=C:\path\to\LiveTalking"
set "LLAMA_CPP_DIR=C:\llama.cpp"
set "LLM_MODEL_GGUF=C:\path\to\Qwen3.5-9B-Uncensored-HauhauCS-Aggressive-Q4_K_M.gguf"
rem ─── Optional overrides ─────────────────────────────────────────
rem set "LLM_CTX_SIZE=8192"
rem set "LLM_ALIAS=qwen3.5-9b"
rem set "LLM_URL=http://127.0.0.1:8080/v1"
rem set "LLM_MODEL_NAME=qwen3.5-9b"
rem set "STT_LANG=zh"
rem set "DEMO_PORT=7860"
rem set "LT_PORT=8010"
rem ────────────────────────────────────────────────────────────────

echo ============================================
echo   live-avatar 一键启动
echo   1) llama-server :8080  (local LLM)
echo   2) s2s backend  :8765
echo   3) demo page    :7860
echo   4) LiveTalking  :8010  (数字人)
echo ============================================

set SCRIPTS=%~dp0

echo.
echo [1/4] 启动 llama-server...
call "%SCRIPTS%start_llama.bat"

echo.
echo [2/4] 启动 s2s 后端...
call "%SCRIPTS%start_s2s.bat"

echo.
echo [3/4] 启动 demo 页面...
call "%SCRIPTS%start_demo.bat"

echo.
echo [4/4] 启动 LiveTalking 数字人...
call "%SCRIPTS%start_livetalking.bat"

echo.
echo 全部已启动。等待各服务就绪后访问:
echo   demo 页面:   http://127.0.0.1:%DEMO_PORT%
echo   数字人调试:  http://127.0.0.1:%LT_PORT%/embed.html
echo   模型状态:    http://127.0.0.1:8080/health
echo.
pause
