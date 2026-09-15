---
title: Async generation
description: Run several model requests concurrently with Nim async code.
---

Run multiple independent model requests concurrently with `generateTextAsync`.

The `answer` procedure turns one prompt into a future, and `all` waits for all
three futures together. This keeps the event loop available while requests are
in flight instead of waiting for each answer one at a time.

```nim
import std/[asyncdispatch, os]
import nimgent
import nimgent/providers/openai

proc answer(model: LanguageModel, prompt: string): Future[string] {.async.} =
  let response: ProviderResponse = await generateTextAsync(
    model,
    system = "You are a helpful assistant. Answer in 5 or fewer words.",
    prompt = prompt)
  return response.text

proc main() {.async.} =
  let model: LanguageModel = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

  echo "calling the models..."
  let answers = await all(answer(model, "Why is the sky blue?"),
                          answer(model, "Why is grass green?"),
                          answer(model, "Why are sunsets orange?"))
  let labels = ["sky", "grass", "sunset"]
  for i, label in labels:
    echo label, ": ", answers[i]

waitFor main()
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/async_generate.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/async_generate.nim)
