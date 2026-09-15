---
title: Anthropic smoke test
description: Try Anthropic streaming and native structured output.
---

Make two live Anthropic requests, one streamed and one decoded into a typed
object.

The example uses `streamText` for incremental output, then calls
`generateObject[Answer]` with the same model. Set `ANTHROPIC_API_KEY` before
running it and expect both requests to use your Anthropic account.

```nim
import std/os
import nimgent
import nimgent/providers/anthropic

type Answer = object
  answer: string
  confidence: int

let model = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")

echo "streaming..."
let streamed = streamText(model,
  prompt = "Explain why the sky is blue in one sentence.",
  maxTokens = 1024,
  onEvent = proc (ev: StreamEvent): bool =
    if ev.kind == seTextDelta:
      stdout.write ev.text
      flushFile(stdout)
    true)
echo "\nfinish: ", streamed.finishReason

let structured = generateObject[Answer](model,
  prompt = "Return a one-word answer and an integer confidence from 0 to 100.",
  maxTokens = 1024)
echo "answer: ", structured.value.answer
echo "confidence: ", structured.value.confidence
```

Run it from the repository root:

```sh
ANTHROPIC_API_KEY=... nim c -r examples/anthropic_smoke.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/anthropic_smoke.nim)
