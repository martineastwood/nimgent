## Run with ANTHROPIC_API_KEY set: nim c -r examples/anthropic_smoke.nim
import std/[os, json]
import nimgent
import nimgent/anthropic

let model = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")
var chunks = 0
let response = streamText(model, proc (event: StreamEvent): bool =
  if event.kind == seTextDelta: inc chunks
  true,
  prompt = "Reply with exactly ANTHROPIC_OK", maxTokens = 64)
doAssert chunks > 0
doAssert response.finishReason == frEndTurn
echo response.model, ": streaming OK (", chunks, " chunks)"
let objectResponse = generateObject(model,
  %*{"type": "object", "properties": {"ok": {"type": "boolean"}},
    "required": ["ok"], "additionalProperties": false},
  prompt = "Return ok=true", maxTokens = 128)
doAssert objectResponse.value["ok"].getBool
echo "Structured output OK"
