# nimgent

A lightweight LLM client library for Nim — generate and stream text across
providers without pulling in an agent loop, TUI, or coding tools.

## Install

```sh
nimble install nimgent
```

Or path-depend during development (sibling checkout):

```text
# nim.cfg
--path:"../nimgent/src"
```

## Quick start

```nim
import std/os
import nimgent
import nimgent/openrouter

let model = openRouter(getEnv("OPENROUTER_API_KEY")).model(
  "deepseek/deepseek-v4-flash-0731")

let response = generateText(
  model,
  prompt = "Say hello in one sentence.")

echo response.text
```

Stream tokens as they arrive:

```nim
let response = streamText(
  model,
  prompt = "Count to three.",
  onEvent = proc (ev: StreamEvent): bool =
    if ev.kind == seTextDelta:
      stdout.write ev.text
      flushFile(stdout)
    true)

echo ""
echo "finish: ", response.finishReason
```

## Providers

```nim
import nimgent/[anthropic, hyper, openai, openrouter]

let openaiProvider = openAI(getEnv("OPENAI_API_KEY"))
# /v1/responses; pass a */chat/completions URL for compat servers

let hyperProvider = hyper(getEnv("HYPER_API_KEY"))
# https://hyper.charm.land/v1/chat/completions

let anthropicProvider = anthropic(getEnv("ANTHROPIC_API_KEY"))
```

Provider-specific knobs (thinking, routing, cache TTL) go in
`ProviderRequest.options` / the `options` argument on `generateText` /
`streamText`. Options must be a JSON object.

## Async

Async is the primitive API. Use it in servers and existing event loops:

```nim
import std/asyncdispatch

proc main() {.async.} =
  let response = await generateTextAsync(model, prompt = "Hello")
  echo response.text

waitFor main()
```

`generateText`, `streamText`, `generateObject`, and `streamObject` are blocking
wrappers for scripts and CLI programs. Do not call the blocking wrappers from
inside an async event loop.

Providers expose a small capability set for applications that switch providers
at runtime:

```nim
if model.provider.supports(pcStreaming):
  discard
```

For deterministic application tests, `import nimgent/testing` and use
`scriptedModel(@[textResponse("hello")])`.

## Wrapping providers

`wrapProvider` runs every call through optional request and response hooks —
inject defaults, drop images, redact, log usage — without touching the
adapters. Capabilities and structured-output support forward.

```nim
let wrapped = wrapProvider(model.provider,
  mapRequest = proc (req: ProviderRequest): ProviderRequest =
    var r = req  # return a copy; the tool loop reuses one request across turns
    r.system.add "Be concise."
    r)
```

`mapResponse(req, resp)` edits the response in place. Streaming calls pass
through the same hooks.

## Retries, cancel, tools

`generateText` / `streamText` retry 429, 5xx, and transport errors (`maxRetries`
defaults to 2) with jittered backoff and `Retry-After`. Context overflow and
4xx are not retried. Cancellation raises `CancelledError`, including when a
streaming callback returns `false`.

Pass `abort` to cancel before the next attempt (or, while streaming, from
`onEvent` by returning `false`):

```nim
var stop = false
let response = generateText(
  model, prompt = "…",
  abort = proc (): bool = stop)
```

Tools with an `execute` callback plus `maxSteps` > 1 run a small loop: model →
tools → model, until there are no tool calls or the step cap is hit. `maxSteps`
defaults to 1 (one model call, no loop), matching AI SDK's explicit opt-in to
multi-step generation.

```nim
type WeatherInput = object
  city: string

let weather = tool("weather", "Look up weather",
  proc (input: WeatherInput): string = input.city & ": 16C and cloudy")

let response = generateText(
  model,
  prompt = "Weather in Paris?",
  tools = @[weather],
  maxSteps = 5)

echo response.steps.len
echo response.totalUsage.inputTokens
if response.finishReason == frStepLimit:
  echo "stopped at the step limit"
```

Tool callbacks may return a value directly or return `Future[T]`; async tool
calls marked `parallel = true` overlap without blocking the event loop.

`response.content`, `response.usage`, and `response.finishReason` describe the
final model call. `response.steps` records every call and its local tool
results; `response.totalUsage` is accumulated across them.

`hostedTool("web_search")` runs on the provider (OpenAI Responses, Anthropic).
Chat Completions skips it. Hosted calls and results stay on the assistant
message for replay; `toolCalls` / the execute loop ignore them.

```nim
let response = generateText(
  model, prompt = "What landed today?",
  tools = @[hostedTool("web_search")])
```

Pass already encoded data with `file(...)`, or load a local PDF with
`fileFromPath(...)`. Citations come back as `ckSource`.

```nim
let response = generateText(
  model,
  messages = @[userMessage(@[
    fileFromPath("spec.pdf", "application/pdf"),
    text("Summarize this.")])])
```

For multi-turn conversations, use `userMessage(...)` and
`assistantMessage(...)` to construct history.

niminal still owns its own agent loop; this helper is for apps that want the
AI-SDK-style “run my callbacks until the model is done.”

## Structured output

`generateObject` asks the model for JSON that matches a schema and validates
it. Truncated JSON is closed locally (`fixJson`). OpenAI (Responses and Chat
Completions), OpenRouter, Hyper, and Anthropic get native structured-output
knobs automatically; anything else is prompt + extract (including ``` fences).

```nim
type Recipe = object
  name: string
  servings: int
  ingredients: seq[string]

let recipe = generateObject[Recipe](
  model,
  prompt = "A weeknight lasagna.")

echo recipe.value.name
echo recipe.usage.inputTokens
```

Pass `schema = %*{...}` for the `JsonNode` form. `mode = omTool` forces a
`submit` tool. `maxRepairs` (default 0) is optional extra model turns after
local repair fails.

`streamObject` streams the first attempt. `onPartial` receives the JSON tree
whenever it changes (unclosed strings/objects are closed; not schema-valid
until the stream ends). Schema check and model repairs run after that.

```nim
let recipe = streamObject[Recipe](
  model,
  prompt = "A weeknight lasagna.",
  onPartial = proc (partial: JsonNode): bool =
    if "name" in partial:
      stdout.write "\r" & partial["name"].getStr
      flushFile(stdout)
    true)
```

## What this is not

nimgent is not a coding agent. Session persistence, compaction, workspace
tools, and terminal UI live in [niminal](https://github.com/martin/niminal)
(or your own app).

## Release

```sh
git tag -a v0.1.0 -m "nimgent 0.1.0"
nimble publish   # needs a GitHub PAT with public_repo scope
```
