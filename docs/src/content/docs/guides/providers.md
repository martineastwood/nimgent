---
title: Providers
description: Configure provider adapters without changing application code.
---

nimgent exposes one `LanguageModel` shape across its provider adapters. The
adapter owns authentication, request encoding, streaming, and response
normalization.

## Supported adapters

```nim
import nimgent/providers/[anthropic, google, hyper, openai, openrouter]
```

| Adapter | Constructor | API surface |
| --- | --- | --- |
| OpenAI | `openAI(apiKey)` | Responses API and Chat Completions compatibility |
| Anthropic | `anthropic(apiKey)` | Native Messages API and streaming |
| Google | `google(apiKey)` | Native Gemini generation, hosted tools, and embeddings |
| OpenRouter | `openRouter(apiKey)` | OpenAI-compatible routing and models |
| Hyper | `hyper(apiKey)` | OpenAI-compatible Chat Completions endpoint |

Bind a model once and pass it to the same generation helpers:

```nim
let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = generateText(model, prompt = "Explain this function.")
```

## Typed provider options

Use `ProviderOptions` when the setting has a first-class nimgent type:

```nim
import std/options
import nimgent
import nimgent/providers/openai

let response = generateText(
  openAI(apiKey).model(modelId),
  prompt = "Explain this code.",
  providerOptions = ProviderOptions(
    openai: OpenAIOptions(
      reasoningEffort: some("high"),
      store: some(false))))
```

Only the selected provider namespace is used. Unset `Option` fields are
omitted, while explicit `false`, `0`, and empty sequences remain explicit.

## Raw options

Provider-specific fields that are not modeled yet can be passed as JSON:

```nim
let response = generateText(
  model,
  prompt = "Be concise.",
  options = %*{"temperature": 0.2})
```

Options must be a JSON object. Caller JSON is copied before adapter processing,
so provider encoding does not mutate application-owned values.

## Capabilities

Applications that switch providers at runtime can inspect capabilities:

```nim
if model.provider.supports(pcStreaming):
  discard
```
