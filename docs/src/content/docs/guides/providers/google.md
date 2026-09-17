---
title: Google Gemini
description: Use Gemini through the Google AI Studio API.
---

Connect to Gemini with a Google AI Studio API key, choose a Gemini model, and use it with the standard nimgent APIs.

## Make a request

```nim
import std/os
import nimgent
import nimgent/providers/google

let model = google(getEnv("GEMINI_API_KEY")).model("gemini-3.5-flash-lite")
echo generateText(model, prompt = "Say hello in one sentence.").text
```

Set `GEMINI_API_KEY` before you run the program.

`google(...)` connects to the Gemini API from Google AI Studio. Vertex AI uses different credentials and endpoints, and is not supported by this constructor.

## Set a Google embedding task type

Use `GoogleOptions` to set the embedding `taskType` for Gemini embeddings.

```nim
import std/options

let settings = ProviderOptions(google: GoogleOptions(
  taskType: some("RETRIEVAL_DOCUMENT")
))
```

Pass `settings` to `embed` or `embedMany` as `providerOptions`. Use a task type supported by the selected Gemini embedding model.

For a Google-native setting without a typed option, use `ProviderOptions.extra` with the `google` namespace.

## Use hosted tools

Gemini can run some tools on Google's side, such as web search and URL context.
Declare them with `hostedTool` and let the model decide when to use them:

```nim
let response = generateText(
  model,
  prompt = "Find the Nim language homepage.",
  tools = @[hostedTool("web_search"), hostedTool("url_context")],
  maxSteps = 3)
```

Responses can include `ckSource` blocks with citation titles and URLs. See
[Files and images](/guides/files-and-images/) for printing sources, or the
[Google smoke test](/examples/google-smoke/) example.

## Next steps

See [Settings](/guides/providers/settings/) for portable controls, or
[Tools and agents](/guides/tools-and-agents/) for local and hosted tools.
