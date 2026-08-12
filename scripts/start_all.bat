@echo off
rem ============================================================
rem  live-avatar - one-click launcher
rem
rem  Copy config.local.bat.example to config.local.bat and set your paths,
rem  then double-click (or run) this file. It starts all four
rem  services in dependency order:
rem     1) llama-server   :8080  (local LLM)
rem     2) LiveTalking    :8010  (lip-sync avatar)
rem     3) s2s backend    :8765  (speech pipeline)
rem     4) demo page      :7860  (web UI)
rem ============================================================
@echo off
chcp 65001 > nul

set "SCRIPTS=%~dp0"
if not exist "%SCRIPTS%config.local.bat" (
  echo [ERROR] Missing scripts\config.local.bat
  echo Copy config.local.bat.example to config.local.bat, then set your local paths.
  exit /b 1
)
call "%SCRIPTS%config.local.bat"

echo ============================================
echo   live-avatar 一键启动
echo   1) llama-server :8080  (local LLM)
echo   2) LiveTalking  :8010  (数字人)
echo   3) s2s backend  :8765
echo   4) demo page    :7860
echo ============================================

echo.
echo [1/4] 启动 llama-server...
call "%SCRIPTS%start_llama.bat"

echo.
echo [2/4] 启动 LiveTalking 数字人...
call "%SCRIPTS%start_livetalking.bat"

echo.
echo [3/4] 启动 s2s 后端...
call "%SCRIPTS%start_s2s.bat"

echo.
echo [4/4] 启动 demo 页面...
call "%SCRIPTS%start_demo.bat"

echo.
echo 全部已启动。等待各服务就绪后访问:
echo   demo 页面:   http://127.0.0.1:%DEMO_PORT%
echo   数字人调试:  http://127.0.0.1:%LT_PORT%/embed.html
echo   模型状态:    http://127.0.0.1:8080/health
echo.
pause
