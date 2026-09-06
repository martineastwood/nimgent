## Streaming generateText example — prints tokens as they arrive.
##
##   OPENAI_API_KEY=... nim c -r examples/stream_text.nim

import std/os
import nimgent
import nimgent/openai

let provider = makeOpenAIProvider(getEnv("OPENAI_API_KEY"))

echo "calling the model..."
let response = streamText(
  provider,
  model = "gpt-4o-mini",
  system = @["You are a helpful assistant. Answer without using markdown."],
  prompt = "Explain why the sky is blue.",
  onEvent = proc (ev: StreamEvent): bool =
    if ev.kind == seTextDelta:
      stdout.write ev.text
      flushFile(stdout)
    true)

echo ""
