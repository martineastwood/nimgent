## Lightweight LLM client: shared types, generate/stream facade, providers.

import nimgent/provider
export provider

import std/json

proc buildRequest(
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
  tools: seq[ToolDefinition] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1
): ProviderRequest =
  result = ProviderRequest(
    model: model,
    sessionId: sessionId,
    system: system,
    tools: tools,
    maxTokens: maxTokens,
    options: options,
    wakeFd: wakeFd)
  if messages.len > 0:
    result.messages = messages
  elif prompt.len > 0:
    result.messages = @[userMessage(prompt)]

proc generateText*(
  provider: Provider,
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
  tools: seq[ToolDefinition] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil
): ProviderResponse =
  ## One-shot completion. `prompt` becomes a user message when `messages` is empty.
  provider.generate(buildRequest(model, prompt, messages, system, tools,
    maxTokens, sessionId, options))

proc streamText*(
  provider: Provider,
  model: string,
  onEvent: StreamCallback,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
  tools: seq[ToolDefinition] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1
): ProviderResponse =
  ## Streaming completion; `onEvent` receives deltas. Return false to cancel.
  provider.generateStream(
    buildRequest(model, prompt, messages, system, tools, maxTokens,
      sessionId, options, wakeFd),
    onEvent)
