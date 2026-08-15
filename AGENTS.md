# Local deployment completion rules

These rules apply to every change that affects the running local Live Avatar deployment.

1. Treat a code edit and a deployed runtime edit as one task. Keep the repository source/patch and the corresponding file under the configured runtime directory in sync.
2. Never launch S2S with an ad-hoc command that bypasses `scripts/config.local.bat` or the defaults in the managed restart script. In particular, preserve `LIVETALKING_URL`, MiniMax settings, the LLM URL, and the pinned S2S URL.
3. Restart every affected service before reporting completion. Use `scripts/restart_runtime.ps1`; do not leave an old process serving modified Python or JavaScript.
4. The demo must serve frontend assets with `Cache-Control: no-store`. A normal browser refresh, without clearing cache or using Ctrl+F5, must load the current files.
5. Run `scripts/verify_deployment.ps1 -Conversation` after deployment changes. It must verify all four ports, frontend cache headers and expected UI markers, LLM health, MiniMax audio output, and a second S2S connection after the test session closes.
6. Every browser or WebSocket smoke test must close its conversation in `finally`. Confirm the single S2S pipeline slot is available afterward. Never hand off a test session as an active connection.
7. Check prior regression classes before completion: stale S2S slot, stale LiveTalking WebRTC session, missing `LIVETALKING_URL`, old cached frontend modules, text-send autostart, selected MiniMax voice propagation, 320-sample PCM frames, and `/humanpcm` forwarding.
8. Do not say the deployment is complete if any required check is skipped or fails. Report the exact remaining blocker instead.

## Repository maintenance rules

1. The maintained repository is `git@github.com:angelash/live-avatar.git` and must be configured as `origin`.
2. The original project is `https://github.com/HeiXia2077/live-avatar` and must be retained as the read-only `upstream` remote for future updates.
3. Never push local maintenance commits to `upstream`. Fetch upstream changes with `git fetch upstream`, review the diff, then merge or rebase them into a maintenance branch before publishing to `origin`.
