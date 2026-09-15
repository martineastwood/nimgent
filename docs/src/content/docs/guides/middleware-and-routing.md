---
title: Middleware and routing
description: Intercept every request, and pick the provider per model.
---

Two smaller pieces of the stack sit between your application and the adapters.
**Middleware** (`wrapProvider`) rewrites requests and responses on their way
through, and **routing** (`routeProvider`) decides which provider serves a given
model. Both are `Provider` values, so everything downstream — generation,
streaming, tool loops, structured output — keeps working unchanged.

Reach for them when a concern applies to *every* call rather than to one call
site: a house style, a redaction rule, a logging hook, or a gateway whose models
live on different wire formats.

## Wrapping a provider

`wrapProvider` takes a provider and optional hooks:

```nim
import std/[os, strutils]
import nimgent
import nimgent/providers/openai

let model = wrapProvider(
  openAI(getEnv("OPENAI_API_KEY")),
  mapRequest = proc (req: ProviderRequest): ProviderRequest =
    var r: ProviderRequest = req   # return a copy — see below
    if r.system.len == 0:
      r.system = @["Answer in five words or fewer."]
    r,
  mapResponse = proc (req: ProviderRequest, resp: var ProviderResponse) =
    echo "usage: ", resp.usage.inputTokens, " in / ", resp.usage.outputTokens, " out"
    for part in resp.content.mitems:
      if part.kind == ckText:
        part.text = part.text.replace("secret", "[redacted]")
).model("gpt-4o-mini")
```

Everything the wrapper returns is an ordinary provider, so `.model(...)` binds a
model on it and the rest of your code does not know the difference.

### `mapRequest` returns a new request

The signature is `proc (req: ProviderRequest): ProviderRequest`, and the
contract is that you build and return a value rather than editing `req`.

That is not stylistic. A multi-step tool loop and `generateObject`'s repair
turns reuse **one** `ProviderRequest` across several model calls, and stream and
non-stream paths both go through the same hook. Mutating the request in place
would leak one turn's edits into every later turn — a system prompt appended
three times, dropped images staying dropped after you re-enable them.

```nim
proc addHouseStyle(req: ProviderRequest): ProviderRequest =
  result = req            # value semantics: `result` starts as a copy
  result.system.add "House style: terse, no marketing language."
```

`result = req` copies the object; add to `result`, never to `req`.

### `mapResponse` edits in place

```nim
mapResponse = proc (req: ProviderRequest, resp: var ProviderResponse) =
  for part in resp.content.mitems:
    if part.kind == ckText:
      part.text = part.text.replace("API_KEY_[A-Z0-9]+", "[redacted]")
```

It receives the request that was actually sent (the mapped one, not the
original) and the response, by `var`. Editing text blocks is the common case;
because `resp` is live, changes reach the caller and any session that records
the turn.

### What passes through, and what does not

| Call | Behaviour |
| --- | --- |
| `generateAsync` / `generateText` | Both hooks run |
| `generateStreamAsync` / `streamText` | Same hooks; the response is the assembled stream result |
| `embed` / `embedMany` | **Forwarded untouched** — the mappers are not called |
| Native structured output | Forwarded, including each provider's `nativeObjectOptions` |
| Capabilities | Copied from the inner provider at wrap time, so `supports` stays truthful |

Embeddings bypassing the hooks is deliberate: a text-generation mapper that
rewrites `system` has nothing to say about an embedding batch, and silently
running it would be more surprising than skipping it.

## Guardrails and their limits

Middleware is a good fit for:

- **Defaults** — a system prompt, a `maxTokens` ceiling, a provider-namespaced
  option.
- **Redaction** — stripping secrets or personal data out of responses before
  anything else sees them.
- **Observability** — counting calls, logging usage, recording model ids.
- **Input shaping** — `dropImages(messages)` when a provider rejects image
  content, without changing how sessions store the transcript.

It is not a full middleware pipeline. There is one request hook and one response
hook per wrapper, and no hook for individual stream events:

- **Ordering is composition.** Nest wrappers — `wrapProvider(wrapProvider(p, ...), ...)` —
  and the outer wrapper's request hook runs first, its response hook last.
- **Stream deltas are not interceptable.** Filtering token-by-token means
  handling `onEvent` yourself at the call site; middleware sees the finished
  response.
- **Do not mutate the request.** See above.

## Routing on the model

A gateway — OpenCode, an internal proxy — can serve different models on
different wire formats. `routeProvider` sends each request to whichever provider
serves its model:

```nim
import nimgent/providers/openai

let gateway = routeProvider(
  openCodeChat(getEnv("OPENCODE_API_KEY")),      # the common case
  name = "gateway",
  route = proc (model: string): Provider =
    if model.startsWith("claude"):
      openCodeMessages(getEnv("OPENCODE_API_KEY"))
    elif model.startsWith("gemini"):
      openCodeGoogle(getEnv("OPENCODE_API_KEY"))
    else:
      nil))                                      # nil falls back to the default
```

The router keeps its own name — logs and traces show `gateway`, not the adapter
that happened to serve the call — and delegates generation, streaming,
embeddings, and native structured output to the chosen provider. That last one
matters: `nativeObjectOptions` is resolved per *model*, so a Claude model routed
to the Anthropic wire format gets Anthropic's structured-output shape rather
than the default's.

A `nil` from `route` means "no opinion", not "fail": the request goes to the
default provider. Returning a provider for a model you are not sure about is
worse than returning nothing, since the error you get from the wrong adapter is
rarely as clear as the one from the right one.

`servingProvider` tells you what a route would do without sending anything:

```nim
echo gateway.servingProvider("claude-sonnet-4-6").name
```

Capabilities start as the default provider's. If a routed provider supports more
— hosted tools, say — widen the field yourself, because the router cannot know
what a `route` proc will return:

```nim
var gateway = routeProvider(chatProvider, route = pickProvider)
gateway.capabilities.incl pcHostedTools
```

## Using them together

Wrap the router to apply a policy across every format, which is the usual
production shape:

```nim
let model = wrapProvider(gateway, mapRequest = addHouseStyle).model("claude-sonnet-4-6")
```

If you build `ProviderRequest` values by hand for a direct provider call, raw
`ProviderRequest.options` remains available as the low-level wire escape hatch.
High-level calls use `generationOptions` for portable controls and
`providerOptions` for provider extensions. See [Providers](/guides/providers/)
for that split.

Related: [Errors and retries](/guides/errors-and-retries/) for what a wrapper
does *not* need to handle, and [Providers](/guides/providers/) for the settings
both layers forward.
