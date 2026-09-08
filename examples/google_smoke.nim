## AI_STUDIO_API_KEY=... nim c -r examples/google_smoke.nim
import std/[json, os, strutils]
import nimgent
import nimgent/google

let key = getEnv("AI_STUDIO_API_KEY", getEnv("GEMINI_API_KEY"))
let model = google(key).model(getEnv("GOOGLE_MODEL", "gemini-3.5-flash-lite"))

let embedded = embed(google(key).embeddingModel("gemini-embedding-001"), "hello world")
doAssert embedded.embedding.len > 0
echo "Embedding dimensions: ", embedded.embedding.len

var failures = 0
template runCheck(label: string, body: untyped) =
  block:
    if paramCount() == 0 or label in commandLineParams():
      try:
        body
      except CatchableError as e:
        inc failures
        echo label, " FAILED: ", e.msg.split("Async traceback:")[0]

runCheck "search":
  let searched = generateText(model,
    prompt = "Search the web for the Nim programming language official website and describe it in one sentence.",
    tools = @[hostedTool("web_search")], maxTokens = 2048, maxRetries = 0)
  doAssert searched.text.len > 0
  var sources = 0
  for part in searched.content:
    if part.kind == ckSource: inc sources
  doAssert sources > 0
  echo "Search: ", searched.text
  echo "Sources: ", sources

runCheck "url_context":
  var chunks = 0
  let browsed = streamText(model, proc (ev: StreamEvent): bool =
      if ev.kind == seTextDelta: inc chunks
      true,
    prompt = "Read https://nim-lang.org and describe the language in one sentence.",
    tools = @[hostedTool("url_context")], maxTokens = 2048, maxRetries = 0)
  doAssert browsed.text.len > 0 and chunks > 0
  var retrieved = false
  for part in browsed.content:
    if part.kind == ckToolResult and part.hosted == "url_context":
      retrieved = "URL_RETRIEVAL_STATUS_SUCCESS" in part.output
  doAssert retrieved
  echo "URL context: ", browsed.text

runCheck "tool_loop":
  type LookupInput = object
    name: string
  var calls = 0
  let lookup = tool("lookup_code", "Look up the secret code for a name",
    proc (input: LookupInput): string =
      inc calls
      "ORCHID-742")
  let answer = streamText(model, proc (ev: StreamEvent): bool = true,
    prompt = "Use lookup_code to find Alice's secret code and report it verbatim.",
    tools = @[lookup], maxTokens = 2048, maxSteps = 3, maxRetries = 0)
  doAssert calls > 0 and "ORCHID-742" in answer.text
  echo "Native streamed tool round trip: ", answer.text

doAssert failures == 0
echo "GOOGLE NATIVE E2E OK"
