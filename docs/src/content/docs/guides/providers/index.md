---
title: Providers
description: Connect to a model provider, choose a model, and keep the rest of your code portable.
---

Choose a provider, bind one of its model IDs, and use that model with nimgent's generation APIs. Switching providers changes the setup, not how you call `generateText`, stream output, use tools, or create structured results.

## Make a request

This example connects to OpenAI and asks a model a question.

```nim title="hello.nim"
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")
let response = generateText(model, prompt = "Say hello in one sentence.")

echo response.text
```

Set your API key and run it:

```sh
export OPENAI_API_KEY=...
nim c -r hello.nim
```

`openAI(...)` creates a provider, and `.model(...)` selects a provider-specific model ID. The provider checks whether that model is available when you make the request.

## Choose a provider

Each provider has its own setup page and API key environment variable.

| Provider | Constructor | Setup |
| --- | --- | --- |
| OpenAI | `openAI(apiKey)` | [OpenAI](/nimgent/guides/providers/openai/) |
| Anthropic | `anthropic(apiKey)` | [Anthropic](/nimgent/guides/providers/anthropic/) |
| Google Gemini | `google(apiKey)` | [Google Gemini](/nimgent/guides/providers/google/) |
| OpenRouter | `openRouter(apiKey)` | [OpenRouter](/nimgent/guides/providers/openrouter/) |
| Hyper | `hyper(apiKey)` | [Hyper](/nimgent/guides/providers/hyper/) |
| Mistral | `mistral(apiKey)` | [Mistral](/nimgent/guides/providers/mistral/) |
| OpenCode and OpenCode Zen | `openCode(apiKey)` | [OpenCode](/nimgent/guides/providers/opencode/) |
| Another API | Your own `Provider` subtype | [Custom provider](/nimgent/guides/providers/custom-provider/) |

You can keep more than one model ready and choose one at runtime:

```nim
import std/os
import nimgent
import nimgent/providers/[anthropic, openai]

let fast = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")
let fallback = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")

let useFallback = false
let model = if useFallback: fallback else: fast
echo generateText(model, prompt = "Summarize this file.").text
```

## Configure a request

Use [Settings](/nimgent/guides/providers/settings/) for generation controls that travel with a model switch, such as temperature and stop sequences. It also explains provider-specific settings for features that only one provider offers.

## Troubleshooting

- **Authentication fails:** Confirm the environment variable matches the provider you constructed and is available to your program.
- **The model is not found:** Copy the exact model ID from the selected provider's catalog.
- **A feature is rejected:** Support can vary by model. Handle the provider error, then select a compatible model or adjust the request.

## Next steps

Open a provider setup page above, then continue with [Streaming](/nimgent/guides/streaming/) or [Tools and agents](/nimgent/guides/tools-and-agents/).
