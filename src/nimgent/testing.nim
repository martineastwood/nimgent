## Deterministic provider for application tests.

import std/asyncdispatch
import nimgent/providers/provider

type FakeProvider* = ref object of Provider
  ## Deterministic provider that returns scripted responses and records requests.
  responses*: seq[ProviderResponse]
  requests*: seq[ProviderRequest]

proc textResponse*(value: string, finishReason = frStop,
                   usage = Usage()): ProviderResponse =
  ## Create a simple provider response containing one text block.
  ProviderResponse(content: @[text(value)], usage: usage,
    finishReason: finishReason)

proc scriptedModel*(responses: seq[ProviderResponse], id = "test"): LanguageModel =
  ## Create a model backed by a deterministic sequence of responses.
  if responses.len == 0:
    raise newException(ValueError, "scriptedModel requires at least one response")
  FakeProvider(name: "fake", responses: responses).model(id)

method generateAsync*(provider: FakeProvider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
  ## Return the next scripted response and record the request.
  provider.requests.add request
  let index = min(provider.requests.high, provider.responses.high)
  return provider.responses[index]
