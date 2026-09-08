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

## Module layout

The implementation is grouped under `src/nimgent/structured_output/` for JSON
Schema and structured-output support, and `src/nimgent/providers/` for provider
types, adapters, transports, and streaming helpers. Existing flat imports such
as `nimgent/openai` remain available as compatibility facades.

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
import nimgent/[anthropic, google, hyper, openai, openrouter]

let openaiProvider = openAI(getEnv("OPENAI_API_KEY"))
# /v1/responses; pass a */chat/completions URL for compat servers

let hyperProvider = hyper(getEnv("HYPER_API_KEY"))
# https://hyper.charm.land/v1/chat/completions

let googleProvider = google(getEnv("AI_STUDIO_API_KEY"))
# Native Gemini API, including Google Search, URL Context, and embeddings

let anthropicProvider = anthropic(getEnv("ANTHROPIC_API_KEY"))
```

Anthropic supports native streaming with tool arguments, thinking signatures,
citations, cache usage, and cancellation. Run `nim c -r examples/anthropic_smoke.nim`
with `ANTHROPIC_API_KEY` exported to check live streaming and structured output.

Provider-specific knobs (thinking, routing, cache TTL) go in
`ProviderRequest.options` / the `options` argument on `generateText` /
`streamText`. Options must be a JSON object.

### Typed provider options

Pass scoped objects through `providerOptions` on text generation, streaming,
structured output, and embedding calls (including their async variants):

```nim
import std/options
import nimgent
import nimgent/openai

let answer = generateText(openAI(apiKey).model(modelId), prompt = "Explain this code",
  providerOptions = ProviderOptions(
    openai: OpenAIOptions(reasoningEffort: some("high"), store: some(false)),
    anthropic: AnthropicOptions(thinking: some(AdaptiveThinking)),
    openrouter: OpenRouterOptions(routing: some(OpenRouterRouting(
      order: some(@["Anthropic"]), allowFallbacks: some(false)))),
    google: GoogleOptions(reasoningEffort: some("high")))))
```

Only the selected provider's namespace is used. OpenRouter and Hyper do not
consume OpenAI settings despite sharing its transport implementation.
`Option[T]` fields omit unset values; `some(false)`, `some(0)`, and empty
sequences remain explicit. Model-specific supported values are checked by the API.

The initial types cover OpenAI reasoning effort, parallel tool calls, storage,
user identifiers and embedding dimensions; Anthropic thinking mode, budget and
effort; OpenRouter routing; and Google Gemini reasoning effort.
`dimensions` is for embedding calls only.
For manual Anthropic thinking, use `thinking: some(EnabledThinking)` with
`budgetTokens: some(2048)` (at least 1024); adaptive/disabled thinking omit budgets.

Each provider object has an `extra: JsonNode` escape hatch using native API field
names. `ProviderOptions.extra` accepts additional namespaces, for example
`%*{"hyper": {"temperature": 0.5}}`. Merge order is legacy `options`, namespaced
`extra`, the provider object's `extra`, then its typed fields. Merges are shallow:
a later nested object replaces the earlier object. Typed OpenAI reasoning effort
also overrides an effort supplied through the native Responses `reasoning` object.
Structured-output schema and forced-tool settings are applied after these options.
Caller JSON is copied before adapter processing.

Ready-made requests can use `generateText(provider, request, providerOptions = ...)`
and `streamText(provider, request, callback, providerOptions = ...)`. Direct adapter
calls continue to use raw `ProviderRequest.options`; `resolveOptions(raw, scoped,
provider.name)` is available when building those requests yourself.
Message/content-block options and explicit cache controls are deferred.

For Claude, `anthropicThinkingOptions(modelId, "high")` selects adaptive thinking
on known modern models and explicit budgets on legacy models. Supported efforts
follow [Anthropic's model-specific effort levels](https://platform.claude.com/docs/en/build-with-claude/effort).
Pass the result as `options`; manual budgets are added once to `maxTokens`,
while adaptive thinking shares the requested output limit with the answer.
Foreign JSON reasoning metadata and unsigned thinking are omitted on Anthropic
replay; native signed thinking is preserved.

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

## Embeddings

OpenAI and OpenRouter expose text embedding models with AI-SDK-style `embed`
and `embedMany` helpers. Both have async variants, retry transient failures,
and return input-token usage. Provider-specific settings such as reduced
dimensions go in `options`.

```nim
let embeddingModel = openAI(getEnv("OPENAI_API_KEY")).embeddingModel(
  "text-embedding-3-small")

let result = embedMany(
  embeddingModel,
  @["sunny day at the beach", "rainy afternoon in the city"],
  options = %*{"dimensions": 512})

echo result.usage.tokens
echo cosineSimilarity(result.embeddings[0], result.embeddings[1])
```

## Wrapping providers

`wrapProvider` runs text-generation calls through optional request and response hooks —
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
through the same hooks; embedding calls forward unchanged.

## Retries, cancel, tools

`generateText` / `streamText` retry 429, 5xx, and transport errors (`maxRetries`
defaults to 2) with jittered backoff and `Retry-After`. Context overflow and
4xx are not retried. Cancellation raises `CancelledError`, including when a
streaming callback returns `false`.

When a provider returns a request identifier, it is available as
`ProviderResponse.requestId`; failed calls expose the same value as
`ProviderError.requestId` for support and log correlation.

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

## Life cycle hooks

`generateText` and `streamText` accept a `callbacks: RunCallbacks` value with
optional observers for work owned by the generation loop: retries, local tool
execution, completed steps, and the final response. Step numbers are
zero-based; callbacks run for both blocking and async generation, including
streaming.

```nim
let onRetry = proc (attempt, delayMs: int, error: ref ProviderError) =
  echo "retry ", attempt, " in ", delayMs, "ms: ", error.msg

let onStepFinish = proc (step: int, result: StepResult) =
  echo "step ", step, " finished: ",
    result.usage.outputTokens, " output tokens"

let onFinish = proc (response: ProviderResponse) =
  echo "run finished: ", response.steps.len, " steps"

let response = generateText(model, prompt = "…",
  callbacks = RunCallbacks(
    onRetry: onRetry,
    onStepFinish: onStepFinish,
    onFinish: onFinish))
```

The hook contract:

- `onRetry(attempt, delayMs, error)` — a retryable attempt (429/5xx/transport)
  is about to back off. `attempt` is 1-based.
- `onToolStart(step, call)` — a local tool call is starting.
- `onToolFinish(step, call, output, durationMs)` — a local tool call finished;
  `output` carries the result (`isError` for failures) and elapsed milliseconds.
- `onStepFinish(step, result)` — a model turn completed (`StepResult` with its
  content, usage, finish reason, and local tool results).
- `onFinish(response)` — the whole run is done; receives the complete
  `ProviderResponse` (steps and accumulated usage are populated).

Lifecycle hooks are observers, not handlers: they cannot change the request,
cancel, or inject output. `StreamEvent` (via `onEvent`) remains the API for
live model-output deltas and cancellation. A full example lives in
`examples/lifecycle_callbacks.nim`.

`hostedTool("web_search")` runs on the provider (OpenAI Responses, Anthropic,
native Gemini).
Chat Completions skips it. Hosted calls and results stay on the assistant
message for replay; `toolCalls` / the execute loop ignore them.

```nim
let response = generateText(
  model, prompt = "What landed today?",
  tools = @[hostedTool("web_search")])
```

For Gemini hosted tools, use the native adapter:

```nim
import nimgent/google

let model = google(getEnv("AI_STUDIO_API_KEY")).model("gemini-3.5-flash-lite")
let response = generateText(model,
  prompt = "Search for Nim's official documentation and read https://nim-lang.org.",
  tools = @[hostedTool("web_search"), hostedTool("url_context")])
```

`google_search` is also accepted as an alias for `web_search`. Hosted tool options
are passed inside the native tool object. Other hosted tools are rejected.
`google` supports generation, streaming, embeddings, custom functions, structured
JSON, images and files. Its endpoint override is an API root (default
`https://generativelanguage.googleapis.com/v1beta`).

Native options go in `GoogleOptions.extra` using Gemini field names such as
`generationConfig`. The typed `reasoningEffort` maps to native thinking settings.
Model support and quotas determine which tool combinations can run.

Web sources are returned as `ckSource`. Complete `groundingMetadata`, including
citation spans, queries and Search Suggestions HTML, is retained in a hosted
`web_search` result's JSON output. URL retrieval statuses are retained in a hosted
`url_context` result. Applications can use these to render citations and Google's
Search Suggestions. Native response parts are retained in `ContentBlock.googlePart`
for signed conversation replay; preserve this field when serializing history.
See `examples/google_smoke.nim` for live search, URL retrieval and tool-loop checks.

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

## First-class agents

For applications that want the generic model → tool → model loop, use
`nimgent/agent`:

```nim
import std/os
import nimgent/agent
import nimgent/openai

let researcher = newAgent(
  model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-5"),
  instructions = "You are a concise research assistant.",
  maxSteps = 8)

let response = researcher.run("What is the weather in Paris?")
echo response.text
```

`Agent` is reusable configuration; each `run` or `stream` call gets fresh
execution state. `run` and `stream` are blocking convenience wrappers, while
`runAsync` and `streamAsync` are intended for servers and existing event loops.
The agent defaults to a bounded eight-model-turn tool loop. niminal keeps its
own loop because its coding-agent behavior also owns workspace tools, hooks,
permissions, compaction, persistence, and TUI presentation.

## Structured output

`generateObject` asks the model for JSON that matches a schema and validates
it. Truncated JSON is rejected by default; pass `truncation = otRepair` to
accept locally closed JSON (`fixJson`). OpenAI (Responses and Chat
Completions), OpenRouter, Hyper, and Anthropic get native structured-output
knobs automatically when the schema fits the provider's strict dialect;
`omAuto` otherwise falls back to prompt + extract (including ``` fences).
`omNative` reports incompatible schemas locally instead of sending a request.
The result's `locallyRepaired` flag reports when local JSON completion was used.
`result.attempts` counts model turns (including any repair turns), while
`result.repairs` counts only the latter.
`result.source` identifies whether the value came from native structured output
(`osNative`), text extraction (`osText`), or the forced `submit` tool
(`osTool`). Failed calls expose both the legacy `ObjectError.issues` strings and
`ObjectError.issueDetails` entries with a JSON path and message.
The built-in validator supports common draft-07 constraints and local,
non-cyclic `$ref` references; unsupported schema keywords fail before a provider
request.
Native and tool modes keep the full schema in their provider/tool configuration;
the prompt-only JSON mode includes it in the instruction.

```nim
type Recipe = object
  name: string
  servings {.jsonMinimum: 1.}: int
  ingredients: seq[string]
  notes {.jsonOptional.}: string

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
