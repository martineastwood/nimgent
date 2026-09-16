---
title: Middleware and routing
description: Apply a shared request policy or choose a provider from the model name.
---

Use middleware to apply a shared policy to every model request, such as adding a
system instruction or recording usage. Use routing to select a provider from the
model name while the rest of your application keeps the same model API.

## Add a shared instruction

Wrap a provider to add a default system instruction to every generation request.

```nim title="house_style.nim"
import std/os
import nimgent
import nimgent/providers/openai

let provider = wrapProvider(
  openAI(getEnv("OPENAI_API_KEY")),
  mapRequest = proc (req: ProviderRequest): ProviderRequest =
    var request = req
    if request.system.len == 0:
      request.system = @["Answer in five words or fewer."]
    request
)

let response = generateText(
  provider.model("gpt-4.1-mini"),
  prompt = "What is Nim?"
)

echo response.text
```

`mapRequest` receives each request before it is sent. Return a changed copy, as in the example, so the caller's original request stays unchanged.

The wrapped value is still a provider. You can use it with `generateText`, `streamText`, agents, conversations, and structured output just as you would use the original provider.

## Inspect or change completed responses

Use `mapResponse` to record usage, add application metadata, or redact text before the caller receives the final response.

```nim
let provider = wrapProvider(
  openAI(getEnv("OPENAI_API_KEY")),
  mapResponse = proc (req: ProviderRequest, response: var ProviderResponse) =
    echo "model: ", req.model
    echo "tokens: ", response.usage.inputTokens, " in, ",
      response.usage.outputTokens, " out"
)
```

`mapResponse` runs after a response has completed. It can change `response` directly. For streaming, your `onEvent` callback still receives text as it arrives, while `mapResponse` sees the assembled response at the end.

## Route models to providers

A router lets your application select a provider from the model ID. Return a provider for model names you recognize, or `nil` to use the default provider.

```nim title="route_models.nim"
import std/[os, strutils]
import nimgent
import nimgent/providers/[anthropic, openai]

let provider = routeProvider(
  openAI(getEnv("OPENAI_API_KEY")),
  name = "my-models",
  route = proc (model: string): Provider =
    if model.startsWith("claude-"):
      anthropic(getEnv("ANTHROPIC_API_KEY"))
    else:
      nil
)

let response = generateText(
  provider.model("claude-sonnet-4-6"),
  prompt = "Write a one-sentence greeting."
)

echo response.text
```

In this example, Claude model IDs go to Anthropic. All other model IDs use OpenAI. The router also forwards streaming, embeddings, and structured output to the selected provider.

You can check a routing decision without making a request:

```nim
echo provider.servingProvider("claude-sonnet-4-6").name
```

## Apply middleware to every routed model

Wrap the router when the same request policy should apply regardless of which provider serves the model.

```nim
let model = wrapProvider(
  provider,
  mapRequest = proc (req: ProviderRequest): ProviderRequest =
    var request = req
    request.system.add "Be concise."
    request
).model("claude-sonnet-4-6")
```

The request mapping runs before the router chooses a provider.

## Troubleshooting and limits

- **The original request changes unexpectedly:** Build and return a copy in `mapRequest`. Do not modify `req` itself.
- **You need to filter streamed text:** Use the `onEvent` callback. `mapResponse` runs only after the stream finishes.
- **A model reaches the wrong provider:** Check the exact model ID and use `servingProvider` to inspect the route before sending a request.
- **You need to transform embeddings:** Request and response mappers apply to generation requests, not embedding requests.

## Next steps

See [Providers](/guides/providers/) for provider setup and options, or [Error Handling](/guides/error-handling/) for handling failed requests.
