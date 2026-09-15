---
title: Providers
description: Connect nimgent to a model provider, switch models, and configure provider-specific features.
---

Use nimgent with OpenAI, Anthropic, Google Gemini, OpenRouter, Hyper, Mistral, OpenCode and more. 
You create a provider with an API key, bind a model, and pass that model to nimgent's generation APIs.

Once you have a model, the rest of your code can use `generateText`,
`streamText`, tools, and structured output without changing its call shape.

## Make your first request

Install nimgent with Nimble and set the API key for the provider you want to
use. This example uses OpenAI:

```sh
nimble install nimgent
export OPENAI_API_KEY=...
```

Create `hello.nim`:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = generateText(model, prompt = "Say hello in one sentence.")

echo response.text
```

Run it with:

```sh
nim c -r hello.nim
```

`openAI(...)` selects the provider, and `.model(...)` selects a model offered by
that provider. The model id is provider-specific; nimgent checks that the id is
not empty, while the provider checks whether the model is available when you
make the request.

## Choose a provider

Change the provider and model id. The generation call stays the same:

```nim
import std/os
import nimgent
import nimgent/providers/anthropic

let model = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")
let response = generateText(model, prompt = "Explain Nim in one sentence.")

echo response.text
```

Here are the available providers and constructors:

| Provider | Import | Constructor | Use it for |
| --- | --- | --- | --- |
| OpenAI | `nimgent/providers/openai` | `openAI(apiKey)` | OpenAI models and Responses API features |
| Anthropic | `nimgent/providers/anthropic` | `anthropic(apiKey)` | Claude models and Anthropic features |
| Google Gemini | `nimgent/providers/google` | `google(apiKey)` | Gemini through Google AI Studio |
| OpenRouter | `nimgent/providers/openrouter` | `openRouter(apiKey)` | Multiple model providers through one key |
| Hyper | `nimgent/providers/hyper` | `hyper(apiKey)` | Hyper's OpenAI-compatible API |
| Mistral | `nimgent/providers/mistral` | `mistral(apiKey)` | Mistral's Chat Completions API |
| OpenCode | `nimgent/providers/openai` | `openCode(apiKey, protocol = ocChat)` | OpenCode Go's model catalog |
| OpenCode Zen | `nimgent/providers/openai` | `openCodeZen(apiKey, protocol = ocChat)` | OpenCode Zen's model catalog |

You can keep several models ready and choose between them at runtime:

```nim
import std/os
import nimgent
import nimgent/providers/[openai, openrouter]

let fast = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let fallback = openRouter(getEnv("OPENROUTER_API_KEY")).model(
  "deepseek/deepseek-v4-flash-0731")

let useFallback = false
let model = if useFallback: fallback else: fast
echo generateText(model, prompt = "Summarize this file.").text
```

### OpenCode protocols

OpenCode exposes its catalog through several request formats. Choose the
protocol that matches the model or gateway you are using:

- `ocChat` - Chat Completions; the default
- `ocResponses` - OpenAI Responses
- `ocMessages` - Anthropic Messages
- `ocGoogle` - native Google Gemini paths

For example:

```nim
import std/os
import nimgent
import nimgent/providers/openai

let chatModel = openCode(getEnv("OPENCODE_API_KEY"), protocol = ocChat).model(
  "model-id")
let responsesModel = openCodeZen(getEnv("OPENCODE_API_KEY"),
  protocol = ocResponses).model("model-id")
```

Replace `model-id` with the id from the OpenCode catalog. Use `ocGoogle` when
the gateway serves a Gemini model on its native Google API paths.

## Set common generation options

Use `GenerationOptions` for controls you want to keep when switching providers:

```nim
import std/[options, os]
import nimgent
import nimgent/providers/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let response = generateText(
  model,
  prompt = "Explain Nim in one paragraph.",
  maxTokens = 200,
  generationOptions = GenerationOptions(
    temperature: some(0.3),
    topP: some(0.9)))

echo response.text
```

`GenerationOptions` includes `temperature`, `topP`, `topK`, presence and
frequency penalties, `stopSequences`, `seed`, and portable `reasoning`.
`maxTokens`, messages, tools, streaming, and structured output are also
provider-neutral nimgent arguments.

Providers map these settings to their own APIs where supported. A provider may
reject a setting that its model does not support, so check that provider's
model documentation when you use less common controls.

## Add provider-specific settings

Use `providerOptions` for behavior that exists only on one provider. Typed
namespaces give you completion and validation for supported extensions:

```nim
import std/[options, os]
import nimgent
import nimgent/providers/openai

let response = generateText(
  openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini"),
  prompt = "Explain this code.",
  generationOptions = GenerationOptions(reasoning: some("high")),
  providerOptions = ProviderOptions(
    openai: OpenAIOptions(store: some(false))))

echo response.text
```

The available typed namespaces are:

| Namespace | Examples |
| --- | --- |
| `OpenAIOptions` | `parallelToolCalls`, `store`, `user`, embedding `dimensions` |
| `AnthropicOptions` | `thinking`, `budgetTokens` |
| `OpenRouterOptions` | routing order, provider allow/deny lists, and fallback behavior |
| `HyperOptions` | `user`, `parallelToolCalls`, streamed `includeUsage` |

Only the namespace for the selected provider is used. An `OpenAIOptions` value
does not configure a Google or Anthropic model.

Every typed field is optional. Leave it unset to omit it; use `some(false)`,
`some(0)`, or `some(@[])` when you need to send an explicit value. For example,
OpenRouter routing can be configured like this:

```nim
import std/[options, os]
import nimgent
import nimgent/providers/openrouter

let settings = ProviderOptions(
  openrouter: OpenRouterOptions(
    routing: some(OpenRouterRouting(
      sort: some("latency"),
      allowFallbacks: some(false)))))

let model = openRouter(getEnv("OPENROUTER_API_KEY")).model(
  "deepseek/deepseek-v4-flash-0731")
let response = generateText(model, prompt = "Hello", providerOptions = settings)
```

Anthropic thinking budgets have one validation rule worth knowing: a
`budgetTokens` value requires `thinking: some(EnabledThinking)` and must be at
least `1024`.

For a provider field that nimgent does not model yet, use `ProviderOptions.extra`
with the provider name as the namespace:

```nim
import std/json
import nimgent

let settings = ProviderOptions(
  extra: %*{"google": {"generationConfig": {"responseMimeType": "text/plain"}}})
```

Portable `generationOptions` take precedence when they target the same setting.

## Check provider capabilities

Providers do not all offer the same optional features. If your application lets
users choose a provider at runtime, check the model before enabling one:

```nim
if model.provider.supports(pcStreaming):
  echo "This model can use streamText."

if model.provider.supports(pcHostedTools):
  echo "This model can use provider-hosted tools."
```

The capability names correspond to these nimgent features:

| Capability | Feature |
| --- | --- |
| `pcStreaming` | `streamText` |
| `pcTools` | Local tools |
| `pcStructuredOutput` | Native `generateObject` |
| `pcImages` / `pcFiles` | Image or file input |
| `pcHostedTools` | Tools such as provider-hosted web search |
| `pcEmbeddings` | `embed` and `embedMany` |

## Troubleshooting

- **Authentication fails:** make sure the environment variable matches the
  constructor you selected and that the key is available to the process.
- **The model is not found:** model ids belong to the provider. Copy the id
  exactly from that provider's catalog.
- **An option has no effect:** common controls belong in `GenerationOptions`;
  provider extensions belong in the matching `ProviderOptions` namespace.
- **Google authentication or endpoints do not work:** `google(...)` targets
  the Gemini API from Google AI Studio. Vertex AI uses different credentials
  and endpoints and is not supported by this constructor.
- **OpenCode requests fail:** confirm that the protocol (`ocChat`,
  `ocResponses`, `ocMessages`, or `ocGoogle`) matches the model's gateway.

## Next steps

- [Streaming](/guides/streaming/) - show text as it arrives.
- [Tools and agents](/guides/tools-and-agents/) - let models call Nim code.
- [Structured output](/guides/structured-output/) - receive validated Nim values.
- [Embeddings and retrieval](/guides/embeddings-and-retrieval/) - create and search embeddings.
