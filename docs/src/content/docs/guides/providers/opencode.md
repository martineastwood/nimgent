---
title: OpenCode
description: Use OpenCode or OpenCode Zen with the request format their model requires.
---

OpenCode and OpenCode Zen expose models through several API formats. Choose the format that matches the model or gateway, then use the resulting provider like any other nimgent provider.

## Create a model

This example uses the default Chat Completions format.

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openCode(
  getEnv("OPENCODE_API_KEY"),
  protocol = ocChat
).model(getEnv("OPENCODE_MODEL"))

echo generateText(model, prompt = "Say hello in one sentence.").text
```

Set `OPENCODE_API_KEY` and `OPENCODE_MODEL` before you run the program. The repository does not define an OpenCode model ID, so use one from the OpenCode catalog.

## Choose the request format

Set `protocol` to match the model's gateway format:

| Protocol | Use when the gateway expects |
| --- | --- |
| `ocChat` | OpenAI Chat Completions. This is the default. |
| `ocResponses` | OpenAI Responses. |
| `ocMessages` | Anthropic Messages. |
| `ocGoogle` | Native Google Gemini paths. |

For OpenCode Zen, use `openCodeZen` with the same protocol choices:

```nim
let model = openCodeZen(
  getEnv("OPENCODE_API_KEY"),
  protocol = ocResponses
).model(getEnv("OPENCODE_MODEL"))
```

If a request fails, confirm that the selected protocol matches the model's gateway. `ocGoogle` is for Gemini models served on native Google API paths.

## Next steps

See [Settings](/guides/providers/settings/) for portable controls, or [Middleware and routing](/guides/middleware-and-routing/) to choose providers from a model ID.
