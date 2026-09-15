---
title: Provider options
description: Configure common and provider-specific model settings.
---

Pass typed provider settings alongside portable generation options.

`ProviderOptions` can contain settings for several providers, but nimgent uses
only the namespace matching the selected model. `GenerationOptions` holds the
portable `reasoning` setting, while the example also configures OpenAI,
Anthropic, and OpenRouter values.

```nim
import std/[options, os]
import nimgent
import nimgent/providers/openai

let settings = ProviderOptions(
  openai: OpenAIOptions(store: some(false)),
  anthropic: AnthropicOptions(thinking: some(AdaptiveThinking)),
  openrouter: OpenRouterOptions(routing: some(OpenRouterRouting(
    sort: some("latency"), allowFallbacks: some(false)))))

let model = openAI(getEnv("OPENAI_API_KEY")).model(getEnv("OPENAI_MODEL", "gpt-5"))
echo generateText(model, prompt = "Why is the sky blue?",
  generationOptions = GenerationOptions(reasoning: some("high")),
  providerOptions = settings).text
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/provider_options.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/provider_options.nim)
