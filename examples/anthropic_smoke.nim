## Live Anthropic smoke test: streaming plus native structured output.
##
##   ANTHROPIC_API_KEY=... nim c -r examples/anthropic_smoke.nim

import std/os
import nimgent
import nimgent/anthropic

type Answer = object
  answer: string
  confidence: int

let model = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")

echo "streaming..."
let streamed = streamText(model,
  prompt = "Explain why the sky is blue in one sentence.",
  onEvent = proc (ev: StreamEvent): bool =
    if ev.kind == seTextDelta:
      stdout.write ev.text
      flushFile(stdout)
    true)
echo "\nfinish: ", streamed.finishReason

let structured = generateObject[Answer](model,
  prompt = "Return a one-word answer and an integer confidence from 0 to 100.")
echo "answer: ", structured.value.answer
echo "confidence: ", structured.value.confidence
