param(
    [switch]$Conversation
)

$ErrorActionPreference = "Stop"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$configPath = Join-Path $PSScriptRoot "config.local.bat"

function Import-BatchConfig {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing local config: $Path"
    }
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^\s*set\s+"([^"=]+)=(.*)"\s*$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2], "Process")
        } elseif ($line -match '^\s*set\s+([^=\s]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($matches[1], $matches[2].Trim(), "Process")
        }
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

Import-BatchConfig $configPath
$demoPort = if ($env:DEMO_PORT) { [int]$env:DEMO_PORT } else { 7860 }
$ltPort = if ($env:LT_PORT) { [int]$env:LT_PORT } else { 8010 }
$s2sUrl = if ($env:SPEECH_TO_SPEECH_URL) { $env:SPEECH_TO_SPEECH_URL } else { "ws://127.0.0.1:8765/v1/realtime" }
$expectedLtUrl = "http://127.0.0.1:$ltPort"

Assert-True ($env:LIVETALKING_URL -eq $expectedLtUrl) "LIVETALKING_URL is missing or incorrect"

$portResults = [ordered]@{}
foreach ($port in $demoPort, $ltPort, 8080, 8765) {
    $owners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    Assert-True ($owners.Count -eq 1) "Expected exactly one listener on port $port; found $($owners.Count)"
    $portResults[[string]$port] = $owners[0]
}

$page = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$demoPort/" -TimeoutSec 10
$cacheControl = [string]$page.Headers["Cache-Control"]
Assert-True ($cacheControl -match 'no-store') "Demo HTML is cacheable; normal refresh may load old code"
foreach ($marker in @(
    "MiniMax 音色",
    "Chinese (Mandarin)_Gentle_Senior",
    "Chinese (Mandarin)_Warm_Girl",
    "managed-reconnect-1",
    "s2s.ws.voice.minimax-v2"
)) {
    if ($marker -like "s2s.ws.*") {
        $main = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$demoPort/main.js" -TimeoutSec 10
        Assert-True ($main.Content.Contains($marker)) "Frontend marker is missing: $marker"
        Assert-True (([string]$main.Headers["Cache-Control"]) -match 'no-store') "main.js is cacheable"
    } else {
        Assert-True ($page.Content.Contains($marker)) "Frontend marker is missing: $marker"
    }
}
Assert-True ($page.Content.Contains('<option value="Chinese (Mandarin)_Warm_Girl" selected>温暖少女</option>')) "Warm Girl is not the selected default voice"
Assert-True (-not $page.Content.Contains("刚才的音色")) "The obsolete parenthetical voice label is still present"
$main = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$demoPort/main.js" -TimeoutSec 10
Assert-True ($main.Content.Contains('const DEFAULT_VOICE = "Chinese (Mandarin)_Warm_Girl";')) "Frontend default voice is not Warm Girl"

$null = Invoke-RestMethod -Uri "http://127.0.0.1:8080/health" -TimeoutSec 10
$ltConfig = Invoke-RestMethod -Uri "$expectedLtUrl/api/admin/config" -TimeoutSec 10
Assert-True ($ltConfig.code -eq 0) "LiveTalking config endpoint failed"
$ltEmbed = Invoke-WebRequest -UseBasicParsing -Uri "$expectedLtUrl/embed.html" -TimeoutSec 10
Assert-True (([string]$ltEmbed.Headers["Cache-Control"]) -match 'no-store') "LiveTalking embed.html is cacheable"
Assert-True ($ltEmbed.Content.Contains("ICE_GATHER_TIMEOUT_MS")) "LiveTalking is serving an old reconnect implementation"
if ($env:LIVETALKING_DIR) {
    $repoEmbed = Join-Path $repoRoot "web\embed.html"
    $runtimeEmbed = Join-Path $env:LIVETALKING_DIR "web\embed.html"
    Assert-True (Test-Path -LiteralPath $runtimeEmbed) "LiveTalking runtime embed.html is missing"
    Assert-True ((Get-FileHash -LiteralPath $repoEmbed).Hash -eq (Get-FileHash -LiteralPath $runtimeEmbed).Hash) "LiveTalking is serving an embed page that is out of sync with the repository"
}
$ltSessionsResponse = Invoke-RestMethod -Uri "$expectedLtUrl/api/admin/sessions" -TimeoutSec 10
$ltSessions = @($ltSessionsResponse.data.sessions)
$ltMaxSessions = [int]$ltConfig.data.config.max_session
Assert-True ($ltSessions.Count -le $ltMaxSessions) "LiveTalking has $($ltSessions.Count) sessions, exceeding max_session=$ltMaxSessions"

$conversationResult = $null
if ($Conversation) {
    Assert-True ([bool]$env:S2S_DIR) "S2S_DIR is not configured"
    $python = Join-Path $env:S2S_DIR ".venv\Scripts\python.exe"
    Assert-True (Test-Path -LiteralPath $python) "S2S Python not found: $python"
    Assert-True ($ltSessions.Count -gt 0) "No active LiveTalking browser session is available for lip-sync verification"
    $smoke = Join-Path $PSScriptRoot "smoke_test.py"
    $smokeArgs = @(
        $smoke,
        "--url", $s2sUrl,
        "--voice", "Chinese (Mandarin)_Warm_Girl",
        "--livetalking-url", $expectedLtUrl
    )
    $smokeOutput = & $python @smokeArgs
    if ($LASTEXITCODE -ne 0) { throw "Conversation smoke test failed" }
    $conversationResult = $smokeOutput | ConvertFrom-Json
    Start-Sleep -Milliseconds 800
    $leftovers = @(Get-NetTCPConnection -State Established -LocalPort 8765 -ErrorAction SilentlyContinue)
    Assert-True ($leftovers.Count -eq 0) "A smoke-test WebSocket still occupies the S2S pipeline"
}

[pscustomobject]@{
    ok = $true
    ports = $portResults
    cache_control = $cacheControl
    livetalking_url = $env:LIVETALKING_URL
    livetalking_sessions = $ltSessions.Count
    conversation = $conversationResult
} | ConvertTo-Json -Depth 5
