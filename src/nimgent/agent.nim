## Reusable agent configuration and execution facade.
##
## This layer owns the generic model -> tool -> model run. Applications that
## need persistence, compaction, permissions, or presentation can keep those
## concerns outside the agent and use the lower-level nimgent APIs directly.

import std/asyncdispatch
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
    providerOptions*: ProviderOptions

proc newAgent*(model: LanguageModel, instructions = "",
               tools: seq[Tool] = @[], maxTokens = 0, maxRetries = 2,
               maxSteps = 8,
               providerOptions = ProviderOptions()): Agent =
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
    providerOptions: providerOptions)

proc runAsync*(agent: Agent, prompt = "", messages: seq[Message] = @[],
               abort: AbortCheck = nil,
               callbacks = RunCallbacks(), sessionId = ""): Future[ProviderResponse] {.async.} =
  ## Run until the model finishes, no executable tool calls remain, or
  ## `maxSteps` is reached.
  if agent.isNil:
    raiseProviderError("agent must not be nil")
  return await generateTextAsync(agent.model, prompt = prompt,
    messages = messages, system = agent.instructions, tools = agent.tools,
    maxTokens = agent.maxTokens, maxRetries = agent.maxRetries,
    maxSteps = agent.maxSteps, abort = abort, callbacks = callbacks,
    providerOptions = agent.providerOptions, sessionId = sessionId)

proc run*(agent: Agent, prompt = "", messages: seq[Message] = @[],
          abort: AbortCheck = nil,
          callbacks = RunCallbacks(), sessionId = ""): ProviderResponse =
  ## Blocking convenience wrapper around `runAsync`.
  waitFor agent.runAsync(prompt, messages, abort, callbacks, sessionId)

proc streamAsync*(agent: Agent, prompt: string, onEvent: StreamCallback,
                  messages: seq[Message] = @[], abort: AbortCheck = nil,
                  callbacks = RunCallbacks(), sessionId = ""): Future[ProviderResponse] {.async.} =
  ## Stream an agent run. `onEvent` receives normalized model deltas and may
  ## return false to cancel the run.
  if agent.isNil:
    raiseProviderError("agent must not be nil")
  if onEvent.isNil:
    raiseProviderError("agent stream callback must not be nil")
  return await streamTextAsync(agent.model, onEvent, prompt = prompt,
    messages = messages, system = agent.instructions, tools = agent.tools,
    maxTokens = agent.maxTokens, maxRetries = agent.maxRetries,
    maxSteps = agent.maxSteps, abort = abort, callbacks = callbacks,
    providerOptions = agent.providerOptions, sessionId = sessionId)

proc stream*(agent: Agent, prompt: string, onEvent: StreamCallback,
             messages: seq[Message] = @[], abort: AbortCheck = nil,
             callbacks = RunCallbacks(), sessionId = ""): ProviderResponse =
  ## Blocking convenience wrapper around `streamAsync`.
  waitFor agent.streamAsync(prompt, onEvent, messages, abort, callbacks, sessionId)
