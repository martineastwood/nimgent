---
title: Settings
description: Configure portable generation controls and provider-specific request options.
---

Use `GenerationOptions` for controls that should stay the same when you change providers. Use `providerOptions` when you need a setting that belongs to one provider only.

## Set portable generation options

This example sets temperature and a token limit without tying the request to one provider's request format.

```nim
import std/[options, os]
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")
let response = generateText(
  model,
  prompt = "Explain Nim in one paragraph.",
  maxTokens = 200,
  generationOptions = GenerationOptions(
    temperature: some(0.3),
    topP: some(0.9))
)

echo response.text
```

`GenerationOptions` supports `temperature`, `topP`, `topK`, presence and frequency penalties, `stopSequences`, `seed`, and `reasoning`. `maxTokens`, tools, messages, and streaming are also portable nimgent arguments.

Providers translate these controls to their own API format. A provider can still reject a setting that its selected model does not support.

## Set reasoning depth

Use `GenerationOptions.reasoning` for a portable thinking level such as `low`,
`medium`, or `high`. nimgent maps it to the wire format each provider expects:

```nim
import std/[options, os]
import nimgent
import nimgent/providers/openai

let response = generateText(
  openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini"),
  prompt = "Solve this carefully.",
  generationOptions = GenerationOptions(reasoning: some("high")))
```

For provider-specific thinking controls, combine portable reasoning with typed
options. On Anthropic, for example, `AdaptiveThinking` lets Claude choose its
own budget while `EnabledThinking` requires an explicit `budgetTokens` value.
See [Anthropic](/guides/providers/anthropic/) for those settings.

When you build provider bodies directly, `thinkingOptions(provider, level)`
returns the JSON fragment for a named provider and level.

## Set a provider-specific option

Put settings that only apply to one provider in its `ProviderOptions` namespace.

```nim
import std/[options, os]
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4.1-mini")
let response = generateText(
  model,
  prompt = "Explain this code.",
  providerOptions = ProviderOptions(
    openai: OpenAIOptions(store: some(false)))
)

echo response.text
```

Only the namespace for the selected provider is used. For example, `OpenAIOptions` does not configure an Anthropic or Google request.

All typed provider fields are optional. Leave a field unset to omit it. Use `some(false)`, `some(0)`, or `some(@[])` when you need to send an explicit false, zero, or empty list.

## Use an option nimgent does not type yet

Use `ProviderOptions.extra` for a native provider setting without a typed option.

```nim
import std/json
import nimgent

let settings = ProviderOptions(
  extra: %*{
    "google": {
      "generationConfig": {"responseMimeType": "text/plain"}
    }
  }
)
```

The key must match the provider name, such as `google`, `openai`, or `anthropic`. Pass `settings` as `providerOptions` in a generation or embedding call.

Portable `generationOptions` win when both option types set the same behavior.

## Next steps

See the setup page for your [provider](/guides/providers/), or use [Structured output](/guides/structured-output/) for schema-specific output settings.
