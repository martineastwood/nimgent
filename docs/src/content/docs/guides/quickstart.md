---
title: Quickstart
description: Make your first nimgent request in a few lines of Nim.
---

## Install

Install the package with Nimble:

```sh
nimble install nimgent
```

For a sibling checkout during development, add the source directory to
`nim.cfg`:

```text
--path:"../nimgent/src"
```

## Generate text

Create a provider, bind a model, and call `generateText`:

```nim
import std/os
import nimgent
import nimgent/providers/openrouter

let model = openRouter(getEnv("OPENROUTER_API_KEY")).model(
  "deepseek/deepseek-v4-flash-0731")

let response = generateText(model, prompt = "Say hello in one sentence.")
echo response.text
```

The blocking helpers are convenient for scripts. In a server or an existing
event loop, use the async primitive instead:

```nim
import std/asyncdispatch

proc main() {.async.} =
  let response = await generateTextAsync(model, prompt = "Hello")
  echo response.text

waitFor main()
```

## Pick a provider

Import the adapter you need and keep the rest of the application unchanged:

```nim
import nimgent/providers/[anthropic, google, hyper, openai, openrouter]

let openaiModel = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let claudeModel = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")
let geminiModel = google(getEnv("AI_STUDIO_API_KEY")).model("gemini-3.5-flash-lite")
```

Provider-specific settings belong in `providerOptions` or the raw `options`
escape hatch. See [Providers](/guides/providers/) for the typed form.
