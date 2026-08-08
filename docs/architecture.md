# 架构说明

```
┌─────────────────┐        ┌──────────────────┐        ┌──────────────────┐
│  llama-server    │        │  s2s backend     │        │  s2s demo        │
│  (本地 LLM)      │        │  (语音管线)      │        │  (网页 UI)       │
│  :8080           │        │  :8765           │        │  :7860           │
│  Qwen3.5-9B      │        │  VAD→STT→LLM→TTS │        │  数字人全屏背景   │
│  llama.cpp       │        │  faster-whisper  │        │  WebSocket       │
│  OpenAI 兼容接口 │        │  Qwen3-TTS       │        │                  │
└────────┬────────┘        └────────┬─────────┘        └────────┬─────────┘
         │ OpenAI /v1/chat          │ ①TTS 语音（本机播放）      │ WebRTC 视频
         │  (中文回复)              │ ②16kHz PCM 音频转发         │ (数字人画面)
         │                          ▼                           ▼
         │                  ┌─────────────────┐        ┌──────────────────┐
         └──────────────────│ LiveTalking     │        │  浏览器 <video>  │
                            │ (数字人 :8010)  │        │   显示数字人      │
                            │ /humanpcm 路由  │        │   （不播放音频）  │
                            │ wav2lip 口型同步│        │                  │
                            └─────────────────┘        └──────────────────┘
```

## 数据流

1. **用户说话** → 浏览器采集麦克风 → WebSocket 发送到 s2s 后端
2. **VAD** (silero-vad) 检测语音起止
3. **STT** (faster-whisper, 中文) 转写文本
4. **LLM** (llama.cpp / Qwen3.5-9B) 生成中文回复，走 OpenAI `/v1/chat/completions` 兼容接口
5. **TTS** (Qwen3-TTS) 合成中文语音
6. **双路输出**：
   - 音频 WebSocket 回传浏览器 → `<audio>` 播放（用户听到声音）
   - 同一份 16kHz int16 PCM 经 `POST /humanpcm` 转发给 LiveTalking
7. **口型同步**：LiveTalking 按 20ms 切块喂给 wav2lip → 数字人口型跟随 → WebRTC 视频轨 → 浏览器 `<video>` 全屏显示

## 会话发现机制

LiveTalking 每个浏览器连接是一个 WebRTC 会话（带 sessionid）。s2s 转发桥自动：
- 启动时查询 `/api/admin/sessions` 找到第一个活跃会话
- 2 秒 TTL 内复用缓存，超时重新发现
- 收到 `session not found` 业务错误时立即失效缓存、重新发现

这样即使刷新页面导致 iframe 重连产生新会话，转发桥也能自动跟踪，口型不会"丢"。
