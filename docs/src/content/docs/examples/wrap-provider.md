---
title: Wrap provider
description: Add request and response hooks around a provider.
---

Add request defaults, usage logging, or response cleanup with `wrapProvider`.

The request hook returns a copy with a default system prompt, and the response
hook logs usage and redacts a word from text blocks. The underlying OpenAI
provider remains responsible for the actual model request.

```nim
import std/[os, strutils]
import nimgent
import nimgent/providers/openai

let inner: OpenAIProvider = openAI(getEnv("OPENAI_API_KEY"))

let model: LanguageModel = wrapProvider(
  inner,
  mapRequest = proc (req: ProviderRequest): ProviderRequest =
    var r: ProviderRequest = req
    if r.system.len == 0:
      r.system = @["Answer in five words or fewer."]
    r,
  mapResponse = proc (req: ProviderRequest, resp: var ProviderResponse) =
    echo "usage: " & $resp.usage.inputTokens & " in / " &
      $resp.usage.outputTokens & " out"
    for blk in resp.content.mitems:
      if blk.kind == ckText and blk.text.contains("secret"):
        blk.text = blk.text.replace("secret", "[redacted]")
).model("gpt-4o-mini")

echo "calling the model..."
let response: ProviderResponse = generateText(
  model,
  prompt = "Say the secret word in one sentence.")

echo response.text
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/wrap_provider.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/wrap_provider.nim)
