---
title: Mistral
description: Use Mistral through its Chat Completions API.
---

Connect to Mistral with an API key, then choose a model ID from Mistral's catalog.

## Create a model

```nim
import std/os
import nimgent
import nimgent/providers/mistral

let model = mistral(getEnv("MISTRAL_API_KEY")).model("mistral-medium-latest")
echo generateText(model, prompt = "Say hello in one sentence.").text
```

Set `MISTRAL_API_KEY` before you run the program. Choose another model ID from Mistral's catalog when you need a different model.

Mistral uses its OpenAI-compatible Chat Completions API. The standard nimgent generation, streaming, and local tool APIs work with the selected model.

## Next steps

See [Settings](/nimgent/guides/providers/settings/) for portable controls, or [Tools and agents](/nimgent/guides/tools-and-agents/) to let a model call Nim functions.
