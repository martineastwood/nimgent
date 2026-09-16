---
title: Hyper
description: Use Hyper's OpenAI-compatible API.
---

Connect to Hyper with an API key, then choose a model ID from Hyper's catalog.

## Create a model

```nim
import std/os
import nimgent
import nimgent/providers/hyper

let model = hyper(getEnv("HYPER_API_KEY")).model(getEnv("HYPER_MODEL"))
echo generateText(model, prompt = "Say hello in one sentence.").text
```

Set `HYPER_API_KEY` and `HYPER_MODEL` before you run the program. The repository does not define a Hyper model ID, so use one from Hyper's current catalog.

## Hyper-specific options

Use `HyperOptions` for `user`, `parallelToolCalls`, and `includeUsage` in streamed responses.

```nim
import std/options

let settings = ProviderOptions(
  hyper: HyperOptions(includeUsage: some(true)))
```

Pass `settings` as `providerOptions` to `streamText` when you want streamed usage information.

## Next steps

See [Settings](/guides/providers/settings/) for portable controls, or [Streaming](/guides/streaming/) to render Hyper output as it arrives.
