---
summary: "Talk mode: continuous speech conversations with TTS"
read_when:
  - Implementing Talk mode on macOS/iOS/Android
  - Changing voice/TTS/interrupt behavior
title: "Talk Mode"
---

# Talk Mode

Talk mode is a continuous voice conversation loop:

1. Listen for speech
2. Send transcript to the model (main session, chat.send)
3. Wait for the response
4. Speak it via the configured Talk provider (`talk.speak`)

## Behavior (macOS)

- **Always-on overlay** while Talk mode is enabled.
- **Listening → Thinking → Speaking** phase transitions.
- On a **short pause** (silence window), the current transcript is sent.
- Replies are **written to WebChat** (same as typing).
- **Interrupt on speech** (default on): if the user starts talking while the assistant is speaking, we stop playback and note the interruption timestamp for the next prompt.

## Voice directives in replies

The assistant may prefix its reply with a **single JSON line** to control voice:

```json
{ "voice": "<voice-id>", "once": true }
```

Rules:

- First non-empty line only.
- Unknown keys are ignored.
- `once: true` applies to the current reply only.
- Without `once`, the voice becomes the new default for Talk mode.
- The JSON line is stripped before TTS playback.

Supported keys:

- `voice` / `voice_id` / `voiceId`
- `model` / `model_id` / `modelId`
- `speed`, `rate` (WPM), `stability`, `similarity`, `style`, `speakerBoost`
- `seed`, `normalize`, `lang`, `output_format`, `latency_tier`
- `once`

## Config (`~/.openclaw/openclaw.json`)

```json5
{
  talk: {
    provider: "mistral",
    providers: {
      elevenlabs: {
        modelId: "eleven_multilingual_v2",
        apiKey: { source: "env", id: "ELEVENLABS_API_KEY" },
        voiceId: "JBFqnCBsd6RMkjVDRZzb",
        outputFormat: "mp3_44100_128",
      },
    },
    silenceTimeoutMs: 1500,
    interruptOnSpeech: true,
  },
}
```

Defaults:

- `provider`: selects the active provider from `providers` (defaults to first key when `talk.provider` is unset)
- `interruptOnSpeech`: true
- `silenceTimeoutMs`: when unset, Talk keeps the platform default pause window before sending the transcript (`700 ms on macOS and Android, 900 ms on iOS`)
- `providers.*.voiceId`: provider-specific fallback (`MISTRAL_VOICE_ID`, `ELEVENLABS_VOICE_ID`, or `SAG_VOICE_ID`)
- `providers.*.modelId`: provider-specific model (`eleven_v3` for ElevenLabs, `voxtral-mini-tts-2603` for Mistral)
- `providers.*.apiKey`: falls back to provider-specific env var (e.g. `MISTRAL_API_KEY`, `ELEVENLABS_API_KEY`)
- `providers.elevenlabs.outputFormat`: defaults to `pcm_44100` on macOS/iOS and `pcm_24000` on Android (set `mp3_*` to force MP3 streaming)

## macOS UI

- Menu bar toggle: **Talk**
- Config tab: **Talk Mode** group (voice id + interrupt toggle)
- Overlay:
  - **Listening**: cloud pulses with mic level
  - **Thinking**: sinking animation
  - **Speaking**: radiating rings
  - Click cloud: stop speaking
  - Click X: exit Talk mode

## Notes

- Requires Speech + Microphone permissions.
- Uses `chat.send` against session key `main`.
- The gateway resolves Talk playback through `talk.speak` using the active Talk provider. Android falls back to local system TTS only when that RPC is unavailable.
- `stability` for `eleven_v3` is validated to `0.0`, `0.5`, or `1.0`; other models accept `0..1`.
- `latency_tier` is validated to `0..4` when set.
- Android supports `pcm_16000`, `pcm_22050`, `pcm_24000`, and `pcm_44100` output formats for low-latency AudioTrack streaming.
