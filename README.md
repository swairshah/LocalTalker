# LocalTalker

LocalTalker is a standalone macOS voice app based on Commander.

It keeps the same local speech pipeline:

- always-on mic capture
- local VAD (Silero ONNX)
- local STT via `qwen_asr`
- local TTS via `pocket-tts-cli`
- streamed `<voice>` playback with barge-in

The assistant backend is changed from Pi RPC to a local `llama.cpp` server (`llama-server`).

## What changed vs Commander

- Uses `llama.cpp` (`llama-server`) for LLM responses.
- Adds a right-side model panel in the main UI.
- Lets you switch `.gguf` models at runtime.

## Model location

Put `.gguf` files in:

`~/Library/Application Support/LocalTalker/Models/llama`

(You can also keep models in `~/Models` or `~/Downloads`; LocalTalker scans those too.)

## Shortcuts

- `⌘/` — pause/resume mic
- `⌘.` — stop speech + abort current response
- `⌘⇧N` — start a fresh session

## Run

```bash
./scripts/setup.sh
./run.sh
```

## Notes

- ONNX Runtime is downloaded into `vendor/onnxruntime`.
- You still need local binaries for:
  - `qwen_asr`
  - `pocket-tts-cli`
  - `llama-server` (from llama.cpp)
