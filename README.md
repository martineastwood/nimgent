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

let provider = makeOpenRouterProvider(
  getEnv("OPENROUTER_API_KEY"),
  "https://openrouter.ai/api/v1/chat/completions")

let response = generateText(
  provider,
  model = "deepseek/deepseek-v4-flash-0731",
  prompt = "Say hello in one sentence.")

echo response.textContent
```

Stream tokens as they arrive:

```nim
let response = streamText(
  provider,
  model = "deepseek/deepseek-v4-flash-0731",
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

let openai = makeOpenAIProvider(getEnv("OPENAI_API_KEY"))
# /v1/responses; pass a */chat/completions URL for compat servers

let hyper = makeHyperProvider(getEnv("HYPER_API_KEY"))
# https://hyper.charm.land/v1/chat/completions

let anthropic = makeAnthropicProvider(
  getEnv("ANTHROPIC_API_KEY"),
  "https://api.anthropic.com/v1/messages")
```

Provider-specific knobs (thinking, routing, cache TTL) go in
`ProviderRequest.options` / the `options` argument on `generateText` /
`streamText`.

## Retries, cancel, tools

`generateText` / `streamText` retry 429, 5xx, and transport errors (`maxRetries`
defaults to 2) with jittered backoff and `Retry-After`. Context overflow and
4xx are not retried.

Pass `abort` to cancel before the next attempt (or, while streaming, from
`onEvent` by returning `false`):

```nim
var stop = false
let response = generateText(
  provider, model = "…", prompt = "…",
  abort = proc (): bool = stop)
```

Tools with an `execute` callback plus `maxSteps` > 1 run a small loop: model →
tools → model, until there are no tool calls or the step cap is hit. `maxSteps`
defaults to 1 (one model call, no loop).

```nim
let weather = tool("weather", "Look up weather",
  %*{"type": "object", "properties": {"city": {"type": "string"}}},
  proc (input: JsonNode): ToolOutput =
    ToolOutput(output: "16C and cloudy"))

let response = generateText(
  provider,
  model = "…",
  prompt = "Weather in Paris?",
  tools = @[weather],
  maxSteps = 5)
```

`hostedTool("web_search")` runs on the provider (OpenAI Responses, Anthropic).
Chat Completions skips it. Hosted calls and results stay on the assistant
message for replay; `toolCalls` / the execute loop ignore them.

```nim
let response = generateText(
  provider, model = "…", prompt = "What landed today?",
  tools = @[hostedTool("web_search")])
```

Pass a PDF as `file(...)`. Citations come back as `ckSource`.

```nim
let response = generateText(
  provider, model = "…",
  messages = @[userMessage(@[
    file("application/pdf", pdfBase64, filename = "spec.pdf"),
    text("Summarize this.")])])
```

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
  provider,
  model = "…",
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
  provider,
  model = "…",
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
