param(
    [Parameter(Mandatory = $true)]
    [string]$S2SDir
)

$ErrorActionPreference = "Stop"
$resolvedS2S = (Resolve-Path -LiteralPath $S2SDir).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$handlerSource = Join-Path $repoRoot "integrations\s2s\minimax_tts_handler.py"
$handlerTarget = Join-Path $resolvedS2S "src\speech_to_speech\TTS\minimax_tts_handler.py"
$moduleArgsPath = Join-Path $resolvedS2S "src\speech_to_speech\arguments_classes\module_arguments.py"
$pipelinePath = Join-Path $resolvedS2S "src\speech_to_speech\s2s_pipeline.py"
$utf8 = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $handlerSource)) {
    throw "MiniMax TTS handler source not found: $handlerSource"
}

Copy-Item -LiteralPath $handlerSource -Destination $handlerTarget -Force

function Read-NormalizedFile {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path).Replace("`r`n", "`n")
}

function Write-PreservedNewlines {
    param([string]$Path, [string]$Original, [string]$Updated)
    $newline = if ($Original.Contains("`r`n")) { "`r`n" } else { "`n" }
    [System.IO.File]::WriteAllText($Path, $Updated.Replace("`n", $newline), $utf8)
}

$moduleOriginal = [System.IO.File]::ReadAllText($moduleArgsPath)
$module = $moduleOriginal.Replace("`r`n", "`n")
if (-not $module.Contains('"minimax"')) {
    $withWindows = 'Literal["chatTTS", "facebookMMS", "pocket", "kokoro", "qwen3", "windows"]'
    $withoutWindows = 'Literal["chatTTS", "facebookMMS", "pocket", "kokoro", "qwen3"]'
    if ($module.Contains($withWindows)) {
        $module = $module.Replace(
            $withWindows,
            'Literal["chatTTS", "facebookMMS", "pocket", "kokoro", "qwen3", "minimax", "windows"]'
        )
    } elseif ($module.Contains($withoutWindows)) {
        $module = $module.Replace(
            $withoutWindows,
            'Literal["chatTTS", "facebookMMS", "pocket", "kokoro", "qwen3", "minimax"]'
        )
    } else {
        throw "Expected TTS Literal integration point not found in $moduleArgsPath"
    }

    $helpWithWindows = "Either 'chatTTS', 'facebookMMS', 'pocket', 'kokoro', 'qwen3', or 'windows'."
    $helpWithoutWindows = "Either 'chatTTS', 'facebookMMS', 'pocket', 'kokoro', or 'qwen3'."
    if ($module.Contains($helpWithWindows)) {
        $module = $module.Replace(
            $helpWithWindows,
            "Either 'chatTTS', 'facebookMMS', 'pocket', 'kokoro', 'qwen3', 'minimax', or 'windows'."
        )
    } elseif ($module.Contains($helpWithoutWindows)) {
        $module = $module.Replace(
            $helpWithoutWindows,
            "Either 'chatTTS', 'facebookMMS', 'pocket', 'kokoro', 'qwen3', or 'minimax'."
        )
    }
    Write-PreservedNewlines $moduleArgsPath $moduleOriginal $module
}

$pipelineOriginal = [System.IO.File]::ReadAllText($pipelinePath)
$pipeline = $pipelineOriginal.Replace("`r`n", "`n")
if (-not $pipeline.Contains('    elif module_kwargs.tts == "minimax":')) {
    $miniMaxBranch = @'
    elif module_kwargs.tts == "minimax":
        from speech_to_speech.TTS.minimax_tts_handler import MiniMaxTTSHandler

        return MiniMaxTTSHandler(
            stop_event,
            queue_in=lm_response_queue,
            queue_out=send_audio_chunks_queue,
            setup_args=(should_listen,),
            setup_kwargs={
                "cancel_scope": getattr(qwen3_tts_handler_kwargs, "cancel_scope", None),
                "speculative_turns": getattr(qwen3_tts_handler_kwargs, "speculative_turns", None),
            },
        )
'@
    $windowsBranch = '    elif module_kwargs.tts == "windows":'
    if ($pipeline.Contains($windowsBranch)) {
        $pipeline = $pipeline.Replace($windowsBranch, $miniMaxBranch + "`n" + $windowsBranch)
    } else {
        $baseElse = @'
    else:
        raise ValueError("The TTS should be either chatTTS, facebookMMS, pocket, kokoro, or qwen3")
'@
        if (-not $pipeline.Contains($baseElse)) {
            throw "Expected TTS pipeline integration point not found in $pipelinePath"
        }
        $pipeline = $pipeline.Replace(
            $baseElse,
            $miniMaxBranch + @'
    else:
        raise ValueError("The TTS should be either chatTTS, facebookMMS, pocket, kokoro, qwen3, or minimax")
'@
        )
    }

    $pipeline = $pipeline.Replace(
        'The TTS should be either chatTTS, facebookMMS, pocket, kokoro, qwen3, or windows',
        'The TTS should be either chatTTS, facebookMMS, pocket, kokoro, qwen3, minimax, or windows'
    )
    Write-PreservedNewlines $pipelinePath $pipelineOriginal $pipeline
}

Write-Host "MiniMax TTS integration installed in $resolvedS2S"
