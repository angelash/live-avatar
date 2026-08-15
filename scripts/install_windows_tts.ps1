param(
    [Parameter(Mandatory = $true)]
    [string]$S2SDir
)

$ErrorActionPreference = "Stop"
$resolvedS2S = (Resolve-Path -LiteralPath $S2SDir).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$handlerSource = Join-Path $repoRoot "integrations\s2s\windows_tts_handler.py"
$handlerTarget = Join-Path $resolvedS2S "src\speech_to_speech\TTS\windows_tts_handler.py"
$moduleArgsPath = Join-Path $resolvedS2S "src\speech_to_speech\arguments_classes\module_arguments.py"
$pipelinePath = Join-Path $resolvedS2S "src\speech_to_speech\s2s_pipeline.py"
$utf8 = [System.Text.UTF8Encoding]::new($false)

if (-not (Test-Path -LiteralPath $handlerSource)) {
    throw "Windows TTS handler source not found: $handlerSource"
}

Copy-Item -LiteralPath $handlerSource -Destination $handlerTarget -Force

function Update-PythonFile {
    param(
        [string]$Path,
        [string]$OldText,
        [string]$NewText,
        [string]$AlreadyAppliedText
    )

    $raw = [System.IO.File]::ReadAllText($Path)
    $newline = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalized = $raw.Replace("`r`n", "`n")
    if ($normalized.Contains($AlreadyAppliedText)) {
        return
    }
    if (-not $normalized.Contains($OldText)) {
        throw "Expected integration point not found in $Path"
    }
    $updated = $normalized.Replace($OldText, $NewText).Replace("`n", $newline)
    [System.IO.File]::WriteAllText($Path, $updated, $utf8)
}

$oldTtsType = '    tts: Optional[Literal["chatTTS", "facebookMMS", "pocket", "kokoro", "qwen3"]] = field('
$newTtsType = '    tts: Optional[Literal["chatTTS", "facebookMMS", "pocket", "kokoro", "qwen3", "windows"]] = field('
Update-PythonFile $moduleArgsPath $oldTtsType $newTtsType $newTtsType

$oldTtsHelp = '            "help": "The TTS to use. Either ''chatTTS'', ''facebookMMS'', ''pocket'', ''kokoro'', or ''qwen3''. Default is ''qwen3''."'
$newTtsHelp = '            "help": "The TTS to use. Either ''chatTTS'', ''facebookMMS'', ''pocket'', ''kokoro'', ''qwen3'', or ''windows''. Default is ''qwen3''."'
Update-PythonFile $moduleArgsPath $oldTtsHelp $newTtsHelp $newTtsHelp

$oldPipeline = @'
    else:
        raise ValueError("The TTS should be either chatTTS, facebookMMS, pocket, kokoro, or qwen3")
'@
$newPipeline = @'
    elif module_kwargs.tts == "windows":
        from speech_to_speech.TTS.windows_tts_handler import WindowsTTSHandler

        return WindowsTTSHandler(
            stop_event,
            queue_in=lm_response_queue,
            queue_out=send_audio_chunks_queue,
            setup_args=(should_listen,),
            setup_kwargs={
                "cancel_scope": getattr(qwen3_tts_handler_kwargs, "cancel_scope", None),
                "speculative_turns": getattr(qwen3_tts_handler_kwargs, "speculative_turns", None),
            },
        )
    else:
        raise ValueError("The TTS should be either chatTTS, facebookMMS, pocket, kokoro, qwen3, or windows")
'@
Update-PythonFile $pipelinePath $oldPipeline $newPipeline '    elif module_kwargs.tts == "windows":'

Write-Host "Windows TTS integration installed in $resolvedS2S"
