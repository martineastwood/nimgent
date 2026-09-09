## Reusable agent configuration and execution API.
##
## This layer owns the generic model -> tool -> model run. Applications that
## need persistence, compaction, permissions, or presentation can keep those
## concerns outside the agent and use the lower-level nimgent APIs directly.

import std/[asyncdispatch, json]
import nimgent

type
  Agent* = ref object
    ## The model and defaults are immutable by convention after construction.
    model*: LanguageModel
    instructions*: string
    tools*: seq[Tool]
    maxTokens*: int
    maxRetries*: int
    ## Maximum number of model turns. The agent defaults to a small bounded
    ## loop so an accidental tool cycle cannot run forever.
    maxSteps*: int
    toolChoice*: ToolChoice
    providerOptions*: ProviderOptions
    approvalPolicy*: ToolApprovalPolicy

proc newAgent*(model: LanguageModel, instructions = "",
               tools: seq[Tool] = @[], maxTokens = 0, maxRetries = 2,
               maxSteps = 8,
               providerOptions = ProviderOptions(),
               toolChoice = toolChoiceAuto(),
               approvalPolicy: ToolApprovalPolicy = nil): Agent =
  ## Create a reusable agent. The returned agent is configuration; each run
  ## receives its own request and response state.
  if model.provider.isNil:
    raiseProviderError("agent model provider must not be nil")
  if model.id.len == 0:
    raiseProviderError("agent model id must not be empty")
  if maxRetries < 0:
    raiseProviderError("agent maxRetries must be at least 0")
  if maxSteps < 1:
    raiseProviderError("agent maxSteps must be at least 1")
  Agent(model: model, instructions: instructions, tools: tools,
    maxTokens: maxTokens, maxRetries: maxRetries, maxSteps: maxSteps,
    toolChoice: toolChoice, providerOptions: providerOptions,
    approvalPolicy: approvalPolicy)

proc runAsync*(agent: Agent, prompt = "", messages: seq[Message] = @[],
               abort: AbortCheck = nil,
               callbacks = RunCallbacks(), sessionId = "",
               metadata: JsonNode = nil, turnId = ""): Future[ProviderResponse] {.async.} =
  ## Run until the model finishes, no executable tool calls remain, or
  ## `maxSteps` is reached.
  if agent.isNil:
    raiseProviderError("agent must not be nil")
  return await generateAgentTextAsync(agent.model, prompt = prompt,
    messages = messages, system = agent.instructions, tools = agent.tools,
    maxTokens = agent.maxTokens, maxRetries = agent.maxRetries,
    maxSteps = agent.maxSteps, abort = abort, callbacks = callbacks,
    providerOptions = agent.providerOptions, sessionId = sessionId,
    metadata = metadata, turnId = turnId, toolChoice = agent.toolChoice,
    approvalPolicy = agent.approvalPolicy)

proc run*(agent: Agent, prompt = "", messages: seq[Message] = @[],
          abort: AbortCheck = nil,
          callbacks = RunCallbacks(), sessionId = "",
          metadata: JsonNode = nil, turnId = ""): ProviderResponse =
  ## Blocking convenience wrapper around `runAsync`.
  waitFor agent.runAsync(prompt, messages, abort, callbacks, sessionId,
    metadata, turnId)

proc streamAsync*(agent: Agent, prompt: string, onEvent: StreamCallback,
                  messages: seq[Message] = @[], abort: AbortCheck = nil,
                  callbacks = RunCallbacks(), sessionId = "",
                  metadata: JsonNode = nil, turnId = ""): Future[ProviderResponse] {.async.} =
  ## Stream an agent run. `onEvent` receives normalized model deltas and may
  ## return false to cancel the run.
  if agent.isNil:
    raiseProviderError("agent must not be nil")
  if onEvent.isNil:
    raiseProviderError("agent stream callback must not be nil")
  return await streamAgentTextAsync(agent.model, prompt = prompt,
    messages = messages, system = agent.instructions, tools = agent.tools,
    maxTokens = agent.maxTokens, maxRetries = agent.maxRetries,
    maxSteps = agent.maxSteps, abort = abort, callbacks = callbacks,
    providerOptions = agent.providerOptions, sessionId = sessionId,
    metadata = metadata, turnId = turnId, toolChoice = agent.toolChoice,
    onEvent = proc (event: AgentEvent): bool =
      case event.kind
      of aeTextDelta:
        onEvent(StreamEvent(kind: seTextDelta, text: event.text))
      of aeThinkingDelta:
        onEvent(StreamEvent(kind: seThinkingDelta, text: event.text))
      of aeToolCall:
        let args = if event.call.input.isNil: "" else: $event.call.input
        onEvent(StreamEvent(kind: seToolCallDelta,
          toolCallId: event.call.id, toolName: event.call.name,
          toolArgs: args))
      else:
        true,
    approvalPolicy = agent.approvalPolicy)

proc stream*(agent: Agent, prompt: string, onEvent: StreamCallback,
             messages: seq[Message] = @[], abort: AbortCheck = nil,
             callbacks = RunCallbacks(), sessionId = "",
             metadata: JsonNode = nil, turnId = ""): ProviderResponse =
  ## Blocking convenience wrapper around `streamAsync`.
  waitFor agent.streamAsync(prompt, onEvent, messages, abort, callbacks,
    sessionId, metadata, turnId)

proc runEventsAsync*(agent: Agent, prompt = "", messages: seq[Message] = @[],
                    abort: AbortCheck = nil,
                    callbacks = RunCallbacks(), sessionId = "",
                    metadata: JsonNode = nil, turnId = "",
                    onEvent: AgentEventCallback = nil
                    ): Future[ProviderResponse] {.async.} =
  if agent.isNil:
    raiseProviderError("agent must not be nil")
  return await generateAgentTextAsync(agent.model, prompt = prompt,
    messages = messages, system = agent.instructions, tools = agent.tools,
    maxTokens = agent.maxTokens, maxRetries = agent.maxRetries,
    maxSteps = agent.maxSteps, abort = abort, callbacks = callbacks,
    providerOptions = agent.providerOptions, sessionId = sessionId,
    metadata = metadata, turnId = turnId, toolChoice = agent.toolChoice,
    onEvent = onEvent, approvalPolicy = agent.approvalPolicy)

proc streamAsync*(agent: Agent, prompt: string, onEvent: AgentEventCallback,
                  messages: seq[Message] = @[], abort: AbortCheck = nil,
                  callbacks = RunCallbacks(), sessionId = "",
                  metadata: JsonNode = nil, turnId = ""
                  ): Future[ProviderResponse] {.async.} =
  if agent.isNil:
    raiseProviderError("agent must not be nil")
  if onEvent.isNil:
    raiseProviderError("agent stream callback must not be nil")
  return await streamAgentTextAsync(agent.model, prompt = prompt,
    messages = messages, system = agent.instructions, tools = agent.tools,
    maxTokens = agent.maxTokens, maxRetries = agent.maxRetries,
    maxSteps = agent.maxSteps, abort = abort, callbacks = callbacks,
    providerOptions = agent.providerOptions, sessionId = sessionId,
    metadata = metadata, turnId = turnId, toolChoice = agent.toolChoice,
    onEvent = onEvent, approvalPolicy = agent.approvalPolicy)

proc stream*(agent: Agent, prompt: string, onEvent: AgentEventCallback,
             messages: seq[Message] = @[], abort: AbortCheck = nil,
             callbacks = RunCallbacks(), sessionId = "",
             metadata: JsonNode = nil, turnId = ""): ProviderResponse =
  waitFor agent.streamAsync(prompt, onEvent, messages, abort, callbacks,
    sessionId, metadata, turnId)

proc events*(agent: Agent, prompt: string, messages: seq[Message] = @[],
             abort: AbortCheck = nil, callbacks = RunCallbacks(),
             sessionId = "", metadata: JsonNode = nil, turnId = ""
             ): AgentEventStream =
  if agent.isNil:
    raiseProviderError("agent must not be nil")
  eventStream(proc (callback: AgentEventCallback): Future[ProviderResponse]
              {.closure.} =
    agent.streamAsync(prompt, callback, messages, abort, callbacks,
      sessionId, metadata, turnId))
