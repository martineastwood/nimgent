---
title: OpenRouter
description: Use models available through OpenRouter's API.
---

Connect to OpenRouter with one API key, choose a model ID from its catalog, and use it with the standard nimgent APIs.

## Make a request

```nim
import std/os
import nimgent
import nimgent/providers/openrouter

let model = openRouter(getEnv("OPENROUTER_API_KEY")).model(
  "deepseek/deepseek-v4-flash-0731")
echo generateText(model, prompt = "Say hello in one sentence.").text
```

Set `OPENROUTER_API_KEY` before you run the program.

## Control OpenRouter routing

Use `OpenRouterOptions` to select providers or control fallback behavior for an OpenRouter request.

```nim
import std/options

let settings = ProviderOptions(
  openrouter: OpenRouterOptions(
    routing: some(OpenRouterRouting(
      sort: some("latency"),
      allowFallbacks: some(false)))))

let response = generateText(model, prompt = "Summarize this.",
  providerOptions = settings)
```

`OpenRouterRouting` also supports `order`, `only`, `ignore`, and `requireParameters`.

## Next steps

See [Settings](/nimgent/guides/providers/settings/) for portable controls, or [Middleware and routing](/nimgent/guides/middleware-and-routing/) to route models in your own application.
