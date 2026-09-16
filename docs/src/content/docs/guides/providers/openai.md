---
title: OpenAI
description: Use OpenAI models with the Responses API.
---

Connect to OpenAI with an API key, choose an OpenAI model ID, and use it with the standard nimgent APIs.

## Make a request

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")
echo generateText(model, prompt = "Say hello in one sentence.").text
```

Set `OPENAI_API_KEY` before you run the program.

`openAI(...)` uses the OpenAI Responses API by default. If you pass a Chat Completions endpoint, nimgent uses that format instead:

```nim
let provider = openAI(
  getEnv("OPENAI_API_KEY"),
  endpoint = "https://api.openai.com/v1/chat/completions"
)
```

## OpenAI-specific options

Use `OpenAIOptions` for `parallelToolCalls`, `store`, `user`, and embedding `dimensions`.

```nim
import std/options

let response = generateText(
  model,
  prompt = "Explain this code.",
  providerOptions = ProviderOptions(
    openai: OpenAIOptions(store: some(false)))
)
```

Use `dimensions` with `embed` or `embedMany`. Changing dimensions means you need to re-embed every vector in a store.

## Next steps

See [Settings](/guides/providers/settings/) for portable controls, or [Files and images](/guides/files-and-images/) to attach documents and images.
