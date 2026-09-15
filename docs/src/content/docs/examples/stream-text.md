---
title: Stream text
description: Print generated text as it arrives from the model.
---

Print a model response incrementally with `streamText`.

The callback receives normalized `StreamEvent` values. This example writes only
`seTextDelta` events, so the answer appears on screen while the model is still
generating it.

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model: LanguageModel = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

echo "calling the model..."
let _: ProviderResponse = streamText(
  model,
  system = "You are a helpful assistant. Answer without using markdown.",
  prompt = "Explain why the sky is blue.",
  onEvent = proc (ev: StreamEvent): bool =
    if ev.kind == seTextDelta:
      stdout.write ev.text
      flushFile(stdout)
    true)

echo ""
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/stream_text.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/stream_text.nim)
