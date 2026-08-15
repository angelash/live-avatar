param(
    [switch]$S2S,
    [switch]$Demo,
    [switch]$LiveTalking,
    [switch]$All,
    [switch]$Verify,
    [switch]$Conversation
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$configPath = Join-Path $PSScriptRoot "config.local.bat"
$logDir = Join-Path $repoRoot "logs"
New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Import-BatchConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing local config: $Path" }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*set\s+"([^"=]+)=(.*)"\s*$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
        } elseif ($line -match '^\s*set\s+([^=\s]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim(), "Process")
        }
    }
}

function Set-DefaultEnvironment {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($Name, "Process"))) {
        [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
    }
}

function Stop-MatchingPython {
    param([string]$Pattern, [int]$Port)
    $targets = @(Get-CimInstance Win32_Process | Where-Object {
        ($_.Name -eq "python.exe" -or $_.Name -eq "pythonw.exe") -and $_.CommandLine -match $Pattern
    })
    foreach ($target in ($targets | Sort-Object ProcessId -Descending)) {
        Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(20)
    do {
        $listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue
        if (-not $listener) { return }
        Start-Sleep -Milliseconds 400
    } while ((Get-Date) -lt $deadline)
    throw "Port $Port did not stop cleanly"
}

function Start-ManagedProcess {
    param(
        [string]$Name,
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$Port,
        [int]$TimeoutSeconds = 90
    )
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $stdout = Join-Path $logDir "$Name-$stamp.out.log"
    $stderr = Join-Path $logDir "$Name-$stamp.err.log"
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments `
        -WorkingDirectory $WorkingDirectory -WindowStyle Hidden `
        -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue) {
            Write-Host "$Name is listening on $Port"
            return
        }
        if ($process.HasExited) {
            throw "$Name exited before port $Port opened. See $stderr"
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw "$Name did not listen on port $Port. See $stderr"
}

function Wait-LiveTalkingSession {
    param([string]$BaseUrl, [int]$TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-RestMethod -Uri "$BaseUrl/api/admin/sessions" -TimeoutSec 5
            if (@($response.data.sessions).Count -gt 0) {
                Write-Host "LiveTalking browser session is ready"
                return
            }
        } catch {
            # The service or browser may still be reconnecting after restart.
        }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)
    throw "No LiveTalking browser session reconnected within $TimeoutSeconds seconds"
}

Import-BatchConfig $configPath
if ($All) { $S2S = $true; $Demo = $true; $LiveTalking = $true }
if (-not ($S2S -or $Demo -or $LiveTalking)) { $S2S = $true; $Demo = $true }

Set-DefaultEnvironment "DEMO_PORT" "7860"
Set-DefaultEnvironment "LT_PORT" "8010"
Set-DefaultEnvironment "LT_MODEL" "wav2lip"
Set-DefaultEnvironment "LT_AVATAR" "jimeng_dark_girl"
Set-DefaultEnvironment "S2S_HOST" "127.0.0.1"
Set-DefaultEnvironment "STT_LANG" "zh"
Set-DefaultEnvironment "STT_DEVICE" "cpu"
Set-DefaultEnvironment "STT_COMPUTE_TYPE" "int8"
Set-DefaultEnvironment "LLM_URL" "http://127.0.0.1:8080/v1"
Set-DefaultEnvironment "LLM_MODEL_NAME" "qwen3-4b"
Set-DefaultEnvironment "TTS_ENGINE" "minimax"
Set-DefaultEnvironment "MINIMAX_TTS_VOICE" "Chinese (Mandarin)_Warm_Girl"
Set-DefaultEnvironment "TTS_MODEL_NAME" "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice"
Set-DefaultEnvironment "TTS_BACKEND" "torch"
Set-DefaultEnvironment "TTS_DEVICE" "cuda"
Set-DefaultEnvironment "SPEECH_TO_SPEECH_URL" "ws://127.0.0.1:8765/v1/realtime"
Set-DefaultEnvironment "LIVETALKING_URL" "http://127.0.0.1:$($env:LT_PORT)"

if ($LiveTalking) {
    if (-not $env:LIVETALKING_DIR) { throw "LIVETALKING_DIR is not configured" }
    $embedSource = Join-Path $repoRoot "web\embed.html"
    $embedTarget = Join-Path $env:LIVETALKING_DIR "web\embed.html"
    if (-not (Test-Path -LiteralPath $embedSource)) { throw "Missing managed embed page: $embedSource" }
    if (-not (Test-Path -LiteralPath (Split-Path -Parent $embedTarget))) { throw "Missing LiveTalking web directory" }
    Copy-Item -LiteralPath $embedSource -Destination $embedTarget -Force
    Stop-MatchingPython "app\.py.*--transport\s+webrtc" ([int]$env:LT_PORT)
    $ltPython = Join-Path $env:LIVETALKING_DIR ".venv\Scripts\python.exe"
    $previousPythonPath = $env:PYTHONPATH
    $env:PYTHONPATH = $env:LIVETALKING_DIR
    Start-ManagedProcess "livetalking" $ltPython @(
        "app.py", "--transport", "webrtc", "--model", $env:LT_MODEL,
        "--avatar_id", $env:LT_AVATAR, "--listenport", $env:LT_PORT,
        "--listenhost", "127.0.0.1"
    ) $env:LIVETALKING_DIR ([int]$env:LT_PORT) 120
    $env:PYTHONPATH = $previousPythonPath
}

if ($S2S) {
    if (-not $env:S2S_DIR) { throw "S2S_DIR is not configured" }
    Stop-MatchingPython "speech_to_speech\.s2s_pipeline" 8765
    $s2sPython = Join-Path $env:S2S_DIR ".venv\Scripts\python.exe"
    Start-ManagedProcess "s2s" $s2sPython @(
        "-u", "-m", "speech_to_speech.s2s_pipeline", "--mode", "realtime",
        "--ws_host", $env:S2S_HOST, "--stt", "faster-whisper",
        "--llm_backend", "chat-completions", "--tts", $env:TTS_ENGINE,
        "--model_name", $env:LLM_MODEL_NAME,
        "--responses_api_base_url", $env:LLM_URL,
        "--responses_api_api_key", "dummy", "--language", $env:STT_LANG,
        "--faster_whisper_stt_model_name", "base",
        "--faster_whisper_stt_device", $env:STT_DEVICE,
        "--faster_whisper_stt_compute_type", $env:STT_COMPUTE_TYPE,
        "--faster_whisper_stt_gen_language", $env:STT_LANG,
        "--qwen3_tts_model_name", $env:TTS_MODEL_NAME,
        "--qwen3_tts_backend", $env:TTS_BACKEND,
        "--qwen3_tts_device", $env:TTS_DEVICE,
        "--thresh", "0.8", "--min_silence_ms", "600",
        "--min_speech_ms", "500", "--log_level", "INFO"
    ) $env:S2S_DIR 8765 90
}

if ($Demo) {
    if (-not $env:S2S_DIR) { throw "S2S_DIR is not configured" }
    Stop-MatchingPython "uvicorn\s+demo\.server:app" ([int]$env:DEMO_PORT)
    $demoPython = Join-Path $env:S2S_DIR ".venv\Scripts\python.exe"
    Start-ManagedProcess "demo" $demoPython @(
        "-m", "uvicorn", "demo.server:app", "--host", "127.0.0.1",
        "--port", $env:DEMO_PORT
    ) $env:S2S_DIR ([int]$env:DEMO_PORT) 45
}

if ($Verify) {
    if ($Conversation) {
        Wait-LiveTalkingSession "http://127.0.0.1:$($env:LT_PORT)"
    }
    & (Join-Path $PSScriptRoot "verify_deployment.ps1") -Conversation:$Conversation
}
