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
import nimgent/[anthropic, openrouter]

let anthropic = makeAnthropicProvider(
  getEnv("ANTHROPIC_API_KEY"),
  model = "claude-sonnet-4-20250514",
  endpoint = "https://api.anthropic.com/v1/messages")
```

Provider-specific knobs (thinking, routing, cache TTL) go in
`ProviderRequest.options` / the `options` argument on `generateText` /
`streamText`.

## What this is not

nimgent is not a coding agent. Session persistence, tools, compaction, and
terminal UI live in [niminal](https://github.com/martin/niminal) (or your own
app).

## Release

```sh
git tag -a v0.1.0 -m "nimgent 0.1.0"
nimble publish   # needs a GitHub PAT with public_repo scope
```
