## Deterministic provider for application tests.

import std/asyncdispatch
import nimgent/providers/provider

type FakeProvider* = ref object of Provider
  responses*: seq[ProviderResponse]
  requests*: seq[ProviderRequest]

proc textResponse*(value: string, finishReason = frStop,
                   usage = Usage()): ProviderResponse =
  ProviderResponse(content: @[text(value)], usage: usage,
    finishReason: finishReason)

proc scriptedModel*(responses: seq[ProviderResponse], id = "test"): LanguageModel =
  if responses.len == 0:
    raise newException(ValueError, "scriptedModel requires at least one response")
  FakeProvider(name: "fake", responses: responses).model(id)

method generateAsync*(provider: FakeProvider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
  provider.requests.add request
  let index = min(provider.requests.high, provider.responses.high)
  return provider.responses[index]
