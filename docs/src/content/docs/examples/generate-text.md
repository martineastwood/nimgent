---
title: Generate text
description: Make a basic text generation request with nimgent.
---

Ask a language model for a concise answer with `generateText`.

This program creates an OpenAI model from the API key in the environment, sends
a system instruction and a prompt, then reads the response with `response.text`.

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model: LanguageModel = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

echo "calling the LLM..."
let response: ProviderResponse = generateText(
  model,
  system = "You are a helpful assistant. Answer concisely and without using markdown.",
  prompt = "Explain why the sky is blue in 10 or fewer words.")

echo response.text
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/generate_text.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/generate_text.nim)
