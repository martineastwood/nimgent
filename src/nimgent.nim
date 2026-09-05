## Lightweight LLM client: shared types, generate/stream facade, providers.

import nimgent/provider
export provider

import std/[json, os]

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

proc checkAbort(abort: AbortCheck) =
  if not abort.isNil and abort():
    raiseProviderError("aborted", aborted = true)

proc retryDelayMs(attempt: int): int =
  ## ponytail: 50/100/200ms; enough to back off 429s, not a full jittered policy.
  50 * (1 shl attempt)

proc canExecute(tools: openArray[Tool]): bool =
  for t in tools:
    if not t.execute.isNil: return true

proc findTool(tools: openArray[Tool], name: string): int =
  for i, t in tools:
    if t.name == name: return i
  -1

proc execTools(tools: openArray[Tool], calls: openArray[ContentBlock],
               abort: AbortCheck): seq[ContentBlock] =
  for call in calls:
    checkAbort(abort)
    let i = findTool(tools, call.name)
    if i < 0 or tools[i].execute.isNil:
      result.add toolResult(call.id, "Unknown tool: " & call.name, true)
      continue
    try:
      let outp = tools[i].execute(call.input)
      result.add toolResult(call.id, outp.output, outp.isError, outp.images)
    except CatchableError as e:
      result.add toolResult(call.id, e.msg, true)

proc retryingCall(provider: Provider, request: ProviderRequest,
                  maxRetries: int, abort: AbortCheck,
                  onEvent: StreamCallback): ProviderResponse =
  for attempt in 0 .. maxRetries:
    checkAbort(abort)
    var started = false
    try:
      if onEvent.isNil:
        return provider.generate(request)
      return provider.generateStream(request, proc (ev: StreamEvent): bool =
        if ev.kind in {seTextDelta, seThinkingDelta, seToolCallDelta}:
          started = true
        if ev.kind == seFinished:
          return true
        onEvent(ev))
    except ProviderError as e:
      if started or e.aborted or e.overflow or not e.retryable or
          attempt == maxRetries:
        raise
      sleep(retryDelayMs(attempt))

proc runLoop(provider: Provider, request: var ProviderRequest,
             tools: seq[Tool], maxRetries, maxSteps: int,
             abort: AbortCheck, onEvent: StreamCallback): ProviderResponse =
  let steps = max(1, maxSteps)
  var cancelled = false
  let cb = if onEvent.isNil: nil else:
    proc (ev: StreamEvent): bool =
      if not abort.isNil and abort():
        cancelled = true
        return false
      if not onEvent(ev):
        cancelled = true
        return false
      true
  for step in 1 .. steps:
    result = retryingCall(provider, request, maxRetries, abort, cb)
    if cancelled:
      return
    let calls = result.toolCalls
    if calls.len == 0 or step == steps or not canExecute(tools):
      break
    let parts = execTools(tools, calls, abort)
    request.messages.add Message(role: roleAssistant, content: result.content)
    request.messages.add userMessage(parts)
  if not onEvent.isNil and not cancelled:
    discard onEvent(StreamEvent(kind: seFinished))

proc generateText*(
  provider: Provider,
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
  tools: seq[Tool] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxSteps = 1,
  abort: AbortCheck = nil
): ProviderResponse =
  ## One-shot completion. `prompt` becomes a user message when `messages` is empty.
  ## `maxRetries` retries 429/5xx/transport (default 2). `maxSteps` > 1 plus
  ## `tool(..., execute=)` runs tools and continues until text or the step cap.
  var request = buildRequest(model, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, options)
  runLoop(provider, request, tools, maxRetries, maxSteps, abort, nil)

proc streamText*(
  provider: Provider,
  model: string,
  onEvent: StreamCallback,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
  tools: seq[Tool] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1,
  maxRetries = 2,
  maxSteps = 1,
  abort: AbortCheck = nil
): ProviderResponse =
  ## Streaming completion; `onEvent` receives deltas. Return false to cancel.
  var request = buildRequest(model, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, options, wakeFd)
  runLoop(provider, request, tools, maxRetries, maxSteps, abort, onEvent)
