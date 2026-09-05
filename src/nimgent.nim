## Lightweight LLM client: shared types, generate/stream facade, providers.

import nimgent/provider
export provider

import std/[json, os, random]
when compileOption("threads"):
  import std/typedthreads

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

const
  retryBaseMs = 250
  retryCapMs = 8_000

var retryRngSeeded = false

proc retryDelayMs*(attempt: int, retryAfterMs = 0): int =
  ## Retry-After wins (capped). Otherwise full jitter on 250ms * 2^attempt, max 8s.
  if retryAfterMs > 0:
    return min(retryAfterMs, retryAfterCapMs)
  if not retryRngSeeded:
    randomize()
    retryRngSeeded = true
  var backoff = retryBaseMs * (1 shl min(attempt, 5))
  if backoff > retryCapMs: backoff = retryCapMs
  rand(backoff)

proc sleepAbort(ms: int, abort: AbortCheck) =
  var left = ms
  while left > 0:
    checkAbort(abort)
    let chunk = min(left, 50)
    sleep(chunk)
    left -= chunk

proc canExecute(tools: openArray[Tool]): bool =
  for t in tools:
    if not t.execute.isNil: return true

proc findTool(tools: openArray[Tool], name: string): int =
  for i, t in tools:
    if t.name == name: return i
  -1

proc execOne(tools: openArray[Tool], call: ContentBlock): ContentBlock =
  let bad = invalidToolCall(call)
  if bad.len > 0:
    return toolResult(call.id, bad, true)
  let i = findTool(tools, call.name)
  if i < 0 or tools[i].execute.isNil:
    return toolResult(call.id, "Unknown tool: " & call.name, true)
  try:
    let outp = tools[i].execute(call.input)
    toolResult(call.id, outp.output, outp.isError, outp.images)
  except CatchableError as e:
    toolResult(call.id, e.msg, true)

proc batchOverlaps(tools: openArray[Tool], calls: openArray[ContentBlock]): bool =
  ## True when at least two calls will run execute and every one of those is parallel.
  var n = 0
  for call in calls:
    if invalidToolCall(call).len > 0: continue
    let i = findTool(tools, call.name)
    if i < 0 or tools[i].execute.isNil: continue
    if not tools[i].parallel: return false
    inc n
  n >= 2

when compileOption("threads"):
  type
    ParallelJob = object
      execute: proc (input: JsonNode): ToolOutput {.closure.}
      input: JsonNode
      id: string
      output: ContentBlock

  proc parallelWorker(job: ptr ParallelJob) {.thread.} =
    # ponytail: execute stays a closure so sequential tools can capture.
    # parallel=true is the user's concurrency promise; the type cannot say gcsafe.
    try:
      let fn = cast[proc (input: JsonNode): ToolOutput {.closure, gcsafe.}](job.execute)
      let outp = fn(job.input)
      job.output = toolResult(job.id, outp.output, outp.isError, outp.images)
    except CatchableError as e:
      job.output = toolResult(job.id, e.msg, true)

  proc execToolsParallel(tools: openArray[Tool],
                         calls: openArray[ContentBlock]): seq[ContentBlock] =
    result.setLen(calls.len)
    var jobs = newSeq[ParallelJob](calls.len)
    var runnable: seq[int]
    for i, call in calls:
      let bad = invalidToolCall(call)
      if bad.len > 0:
        result[i] = toolResult(call.id, bad, true)
        continue
      let t = findTool(tools, call.name)
      if t < 0 or tools[t].execute.isNil:
        result[i] = toolResult(call.id, "Unknown tool: " & call.name, true)
        continue
      jobs[i].execute = tools[t].execute
      jobs[i].input = if call.input.isNil: nil else: copy(call.input)
      jobs[i].id = call.id
      runnable.add i
    var threads = newSeq[Thread[ptr ParallelJob]](runnable.len)
    for j, i in runnable:
      createThread(threads[j], parallelWorker, addr jobs[i])
    for th in threads.mitems:
      joinThread(th)
    for i in runnable:
      result[i] = jobs[i].output

proc execTools(tools: openArray[Tool], calls: openArray[ContentBlock],
               abort: AbortCheck): seq[ContentBlock] =
  when compileOption("threads"):
    if batchOverlaps(tools, calls):
      checkAbort(abort)
      return execToolsParallel(tools, calls)
  for call in calls:
    checkAbort(abort)
    result.add execOne(tools, call)

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
      sleepAbort(retryDelayMs(attempt, e.retryAfterMs), abort)

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
  ## `maxRetries` retries 429/5xx/transport (default 2) with jitter and
  ## Retry-After. `maxSteps` > 1 plus
  ## `tool(..., execute=)` runs tools and continues until text or the step cap.
  var request = buildRequest(model, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, options)
  runLoop(provider, request, tools, maxRetries, maxSteps, abort, nil)

proc generateText*(
  provider: Provider,
  request: ProviderRequest,
  maxRetries = 2,
  abort: AbortCheck = nil
): ProviderResponse =
  ## Retry wrapper for a ready-made request. Does not run the tool loop
  ## (`maxSteps` 1); the caller owns tools.
  var req = request
  runLoop(provider, req, @[], maxRetries, 1, abort, nil)

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

proc streamText*(
  provider: Provider,
  request: ProviderRequest,
  onEvent: StreamCallback,
  maxRetries = 2,
  abort: AbortCheck = nil
): ProviderResponse =
  ## Streaming retry wrapper for a ready-made request. No tool loop.
  var req = request
  runLoop(provider, req, @[], maxRetries, 1, abort, onEvent)
