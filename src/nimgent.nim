## Lightweight LLM client: shared types, generation API, and providers.

import nimgent/providers/provider
export provider

import nimgent/providers/provider_options
export provider_options

import nimgent/mcp
export mcp

import nimgent/structured_output/jsonschema
export jsonschema

import std/[asyncdispatch, asyncstreams, json, jsonutils, math, options, os,
  random, strutils, times]
export fromJsonHook
when compileOption("threads"):
  import std/typedthreads

type RunCallbacks* = object
  ## Optional observers for work owned by the high-level generation loop.
  onRetry*: proc (attempt, delayMs: int, error: ref ProviderError) {.closure.}
  onToolStart*: proc (step: int, call: ContentBlock) {.closure.}
  onToolFinish*: proc (step: int, call, output: ContentBlock,
                       durationMs: int) {.closure.}
  onStepFinish*: proc (step: int, result: StepResult) {.closure.}
  onFinish*: proc (response: ProviderResponse) {.closure.}

type
  AgentEventStream* = ref object
    ## Pull-based event stream. `result` completes with the run response or
    ## fails with the same exception that terminated the event stream.
    queue*: FutureStream[AgentEvent]
    result*: Future[ProviderResponse]
    closed: bool

proc read*(stream: AgentEventStream): Future[(bool, AgentEvent)] =
  if stream.isNil:
    raise newException(ValueError, "agent event stream must not be nil")
  stream.queue.read()

proc close*(stream: AgentEventStream) =
  if stream.isNil or stream.closed: return
  stream.closed = true
  if not stream.queue.finished:
    stream.queue.complete()

type
  EmbedResult* = object
    value*: string
    embedding*: seq[float]
    usage*: EmbeddingUsage

  EmbedManyResult* = object
    values*: seq[string]
    embeddings*: seq[seq[float]]
    usage*: EmbeddingUsage

proc checkAbort(abort: AbortCheck)
proc retryDelayMs*(attempt: int, retryAfterMs = 0): int
proc sleepAbort(ms: int, abort: AbortCheck): Future[void]

proc embedManyAsync*(model: EmbeddingModel, values: seq[string],
                     options: JsonNode = nil, maxRetries = 2,
                     abort: AbortCheck = nil,
                     providerOptions = ProviderOptions()): Future[EmbedManyResult] {.async.} =
  ## Embed strings in one provider batch, preserving input order.
  if values.len == 0: raiseProviderError("values must not be empty")
  if maxRetries < 0: raiseProviderError("maxRetries must be at least 0")
  let resolved = resolveOptions(options, providerOptions, model.provider.name)
  var attempt = 0
  while true:
    checkAbort(abort)
    try:
      let response = await model.provider.embedAsync(EmbeddingRequest(
        model: model.id, values: values, options: resolved))
      if response.embeddings.len != values.len:
        raiseProviderError("provider returned " & $response.embeddings.len &
          " embeddings for " & $values.len & " values")
      return EmbedManyResult(values: values, embeddings: response.embeddings,
        usage: response.usage)
    except ProviderError as e:
      if not e.retryable or attempt >= maxRetries: raise
      await sleepAbort(retryDelayMs(attempt, e.retryAfterMs), abort)
      inc attempt

proc embedMany*(model: EmbeddingModel, values: seq[string],
                options: JsonNode = nil, maxRetries = 2,
                abort: AbortCheck = nil,
                providerOptions = ProviderOptions()): EmbedManyResult =
  waitFor embedManyAsync(model, values, options, maxRetries, abort, providerOptions)

proc embedAsync*(model: EmbeddingModel, value: string,
                 options: JsonNode = nil, maxRetries = 2,
                 abort: AbortCheck = nil,
                 providerOptions = ProviderOptions()): Future[EmbedResult] {.async.} =
  let response = await embedManyAsync(model, @[value], options, maxRetries, abort, providerOptions)
  return EmbedResult(value: value, embedding: response.embeddings[0],
    usage: response.usage)

proc embed*(model: EmbeddingModel, value: string, options: JsonNode = nil,
            maxRetries = 2, abort: AbortCheck = nil,
            providerOptions = ProviderOptions()): EmbedResult =
  waitFor embedAsync(model, value, options, maxRetries, abort, providerOptions)

proc cosineSimilarity*(a, b: openArray[float]): float =
  ## Cosine similarity in [-1, 1]. Both vectors must be non-empty and equal-sized.
  if a.len == 0 or a.len != b.len:
    raise newException(ValueError, "vectors must be non-empty and the same length")
  var dot, normA, normB: float
  for i in 0 ..< a.len:
    dot += a[i] * b[i]
    normA += a[i] * a[i]
    normB += b[i] * b[i]
  if normA == 0 or normB == 0:
    raise newException(ValueError, "cosine similarity is undefined for a zero vector")
  dot / sqrt(normA * normB)

proc buildRequest(
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  tools: seq[ToolDefinition] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1,
  turnId = "",
  metadata: JsonNode = nil,
  toolChoice = toolChoiceAuto()
): ProviderRequest =
  if model.len == 0:
    raiseProviderError("model must not be empty")
  if prompt.len > 0 and messages.len > 0:
    raiseProviderError("pass either prompt or messages, not both")
  if prompt.len == 0 and messages.len == 0:
    raiseProviderError("prompt or messages is required")
  if not options.isNil and options.kind notin {JNull, JObject}:
    raiseProviderError("options must be a JSON object")
  validateToolChoice(toolChoice, tools)
  result = ProviderRequest(
    model: model,
    sessionId: sessionId,
    turnId: turnId,
    metadata: metadata,
    system: if system.len > 0: @[system] else: @[],
    tools: tools,
    toolChoice: toolChoice,
    maxTokens: maxTokens,
    options: options,
    wakeFd: wakeFd)
  if messages.len > 0:
    result.messages = messages
  elif prompt.len > 0:
    result.messages = @[userMessage(prompt)]

proc checkAbort(abort: AbortCheck) =
  if not abort.isNil and abort():
    raiseCancelledError()

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

proc sleepAbort(ms: int, abort: AbortCheck): Future[void] {.async.} =
  var left = ms
  while left > 0:
    checkAbort(abort)
    let chunk = min(left, 50)
    await sleepAsync(chunk)
    left -= chunk

proc canExecute(tools: openArray[Tool]): bool =
  for t in tools:
    if not t.execute.isNil or not t.executeAsync.isNil:
      return true

proc validateRun(tools: openArray[Tool], maxRetries, maxSteps: int) =
  if maxRetries < 0: raiseProviderError("maxRetries must be at least 0")
  if maxSteps < 1: raiseProviderError("maxSteps must be at least 1")
  var names: seq[string]
  for t in tools:
    if t.name.len == 0: raiseProviderError("tool name must not be empty")
    if t.name in names: raiseProviderError("duplicate tool name: " & t.name)
    names.add t.name
    if t.hosted.len == 0 and (t.inputSchema.isNil or t.inputSchema.kind != JObject):
      raiseProviderError("tool '" & t.name & "' requires a JSON Schema object")

proc invalidToolArguments(call: ContentBlock): bool =
  call.kind == ckToolUse and call.parseError.len > 0

proc toolError*(code, message: string, details: JsonNode = nil,
                retryable = false): ToolError =
  ## Construct a machine-readable local tool failure.
  ToolError(code: code, message: message, details: details,
    retryable: retryable)

proc toolFailure*(code, message: string, details: JsonNode = nil,
                  retryable = false, output = ""): ToolResult =
  ## Construct a failed tool result. The optional output is what the model sees;
  ## by default it receives the error message.
  ToolResult(output: if output.len > 0: output else: message, isError: true,
    error: toolError(code, message, details, retryable))

proc normalizeToolResult[Output](output: Output): ToolResult =
  ## Keep structured values for application code while retaining a textual
  ## rendering for provider tool-result messages.
  when Output is ToolResult:
    output
  elif Output is JsonNode:
    result.value = output
    result.output = if output.isNil: "null" else: $output
  elif Output is string:
    result.value = %output
    result.output = output
  else:
    result.value = %*output
    result.output = $result.value

proc toolResultBlock(call: ContentBlock, output: ToolResult): ContentBlock =
  var normalized = output
  if normalized.isError and normalized.error.code.len == 0:
    let message = if normalized.output.len > 0: normalized.output else: "tool failed"
    normalized.error = toolError("tool_error", message)
    if normalized.output.len == 0:
      normalized.output = message
  toolResult(call.id, normalized.output, normalized.isError, normalized.images,
    value = normalized.value, errorCode = normalized.error.code,
    errorMessage = normalized.error.message,
    errorDetails = normalized.error.details,
    errorRetryable = normalized.error.retryable)

proc exceptionToolResult(e: ref CatchableError): ToolResult =
  if e of CancelledError:
    return toolFailure("cancelled", e.msg, retryable = true)
  toolFailure("exception", e.msg)

proc invalidToolResult(call: ContentBlock): ToolResult =
  if invalidToolArguments(call):
    return toolFailure("invalid_arguments", call.parseError,
      %*{"tool": call.name})
  toolFailure("unknown_tool", "Unknown tool: " & call.name,
    %*{"tool": call.name})

proc toolInputFailure(call: ContentBlock, tool: Tool): ToolResult =
  let input = if call.input.isNil: newJNull() else: call.input
  let issues = validateSchema(input, tool.inputSchema)
  if issues.len == 0:
    return ToolResult()
  var details = %*{"tool": call.name}
  details["issues"] = newJArray()
  for issue in issues:
    details["issues"].add %issue
  toolFailure("invalid_arguments", issues.join("; "), details)

proc contextAbort(abort: AbortCheck): AbortCheck =
  if not abort.isNil:
    return abort
  result = proc (): bool = false

proc tool*[Input, Output](name, description: string,
                          execute: proc (context: ToolContext,
                                        input: Input): Output {.closure.},
                          parallel = false): Tool =
  ## Typed tool with access to per-call identity, cancellation and metadata.
  rawTool(name, description, jsonSchema(Input),
    proc (context: ToolContext, input: JsonNode): ToolResult =
      var typedInput: Input
      try:
        typedInput = input.to(Input)
      except CatchableError as e:
        return toolFailure("invalid_arguments", e.msg,
          %*{"tool": name})
      normalizeToolResult(execute(context, typedInput)), parallel)

proc tool*[Input, Output](name, description: string,
                          execute: proc (context: ToolContext,
                                        input: Input): Future[Output] {.closure.},
                          parallel = false): Tool =
  ## Typed async tool with access to per-call identity, cancellation and metadata.
  rawAsyncTool(name, description, jsonSchema(Input),
    proc (context: ToolContext, input: JsonNode): Future[ToolResult] {.async.} =
      var typedInput: Input
      try:
        typedInput = input.to(Input)
      except CatchableError as e:
        return toolFailure("invalid_arguments", e.msg,
          %*{"tool": name})
      return normalizeToolResult(await execute(context, typedInput)), parallel)

proc findTool(tools: openArray[Tool], name: string): int =
  for i, t in tools:
    if t.name == name: return i
  -1

proc toolContext(call: ContentBlock, request: ProviderRequest,
                 step: int, abort: AbortCheck): ToolContext =
  ToolContext(callId: call.id, sessionId: request.sessionId,
    turnId: if request.turnId.len > 0: request.turnId else: "step:" & $step,
    abort: contextAbort(abort), metadata: request.metadata)

proc execOne(tools: openArray[Tool], call: ContentBlock,
             context: ToolContext): ContentBlock =
  if invalidToolArguments(call):
    return toolResultBlock(call, invalidToolResult(call))
  let i = findTool(tools, call.name)
  if i < 0 or tools[i].execute.isNil:
    return toolResultBlock(call, invalidToolResult(call))
  let inputFailure = toolInputFailure(call, tools[i])
  if inputFailure.isError:
    return toolResultBlock(call, inputFailure)
  try:
    toolResultBlock(call, tools[i].execute(context, call.input))
  except CatchableError as e:
    toolResultBlock(call, exceptionToolResult(e))

proc execOneAsync(tools: seq[Tool], call: ContentBlock,
                  context: ToolContext): Future[ContentBlock] {.async.} =
  if invalidToolArguments(call):
    return toolResultBlock(call, invalidToolResult(call))
  let i = findTool(tools, call.name)
  if i < 0 or (tools[i].execute.isNil and tools[i].executeAsync.isNil):
    return toolResultBlock(call, invalidToolResult(call))
  let inputFailure = toolInputFailure(call, tools[i])
  if inputFailure.isError:
    return toolResultBlock(call, inputFailure)
  try:
    if not tools[i].executeAsync.isNil:
      let output = await tools[i].executeAsync(context, call.input)
      return toolResultBlock(call, output)
    return execOne(tools, call, context)
  except CatchableError as e:
    return toolResultBlock(call, exceptionToolResult(e))

proc batchOverlaps(tools: openArray[Tool], calls: openArray[ContentBlock]): bool =
  ## True when at least two calls will run execute and every one of those is parallel.
  var n = 0
  for call in calls:
    if invalidToolArguments(call): continue
    let i = findTool(tools, call.name)
    if i < 0 or tools[i].execute.isNil: continue
    if not tools[i].parallel: return false
    inc n
  n >= 2

proc asyncBatchOverlaps(tools: openArray[Tool],
                        calls: openArray[ContentBlock]): bool =
  var n = 0
  for call in calls:
    if invalidToolArguments(call): continue
    let i = findTool(tools, call.name)
    if i < 0 or (tools[i].execute.isNil and tools[i].executeAsync.isNil): continue
    if not tools[i].parallel: return false
    inc n
  n >= 2

when compileOption("threads"):
  type
    ParallelJob = object
      execute: proc (context: ToolContext,
                    input: JsonNode): ToolResult {.closure.}
      context: ToolContext
      input: JsonNode
      call: ContentBlock
      output: ContentBlock

  proc parallelWorker(job: ptr ParallelJob) {.thread.} =
    # ponytail: execute stays a closure so sequential tools can capture.
    # parallel=true is the user's concurrency promise; the type cannot say gcsafe.
    try:
      let fn = cast[proc (context: ToolContext,
                          input: JsonNode): ToolResult {.closure, gcsafe.}](job.execute)
      job.output = toolResultBlock(job.call, fn(job.context, job.input))
    except CatchableError as e:
      job.output = toolResultBlock(job.call, exceptionToolResult(e))

  proc execToolsParallel(tools: openArray[Tool],
                         calls: openArray[ContentBlock], abort: AbortCheck,
                         request: ProviderRequest, step: int): seq[ContentBlock] =
    result.setLen(calls.len)
    var jobs = newSeq[ParallelJob](calls.len)
    var runnable: seq[int]
    for i, call in calls:
      if invalidToolArguments(call):
        result[i] = toolResultBlock(call, invalidToolResult(call))
        continue
      let t = findTool(tools, call.name)
      if t < 0 or tools[t].execute.isNil:
        result[i] = toolResultBlock(call, invalidToolResult(call))
        continue
      let inputFailure = toolInputFailure(call, tools[t])
      if inputFailure.isError:
        result[i] = toolResultBlock(call, inputFailure)
        continue
      jobs[i].execute = tools[t].execute
      jobs[i].context = toolContext(call, request, step, abort)
      jobs[i].input = if call.input.isNil: nil else: copy(call.input)
      jobs[i].call = call
      runnable.add i
    var threads = newSeq[Thread[ptr ParallelJob]](runnable.len)
    for j, i in runnable:
      createThread(threads[j], parallelWorker, addr jobs[i])
    for th in threads.mitems:
      joinThread(th)
    for i in runnable:
      result[i] = jobs[i].output

proc execTools(tools: openArray[Tool], calls: openArray[ContentBlock],
               abort: AbortCheck, request: ProviderRequest,
               step: int): seq[ContentBlock] =
  when compileOption("threads"):
    if batchOverlaps(tools, calls):
      checkAbort(abort)
      return execToolsParallel(tools, calls, abort, request, step)
  for call in calls:
    checkAbort(abort)
    result.add execOne(tools, call, toolContext(call, request, step, abort))

proc emitAgentEvent(callback: AgentEventCallback, event: AgentEvent): bool =
  if callback.isNil: return true
  callback(event)

proc execToolsAsync(tools: seq[Tool], calls: seq[ContentBlock],
                    abort: AbortCheck, step: int, request: ProviderRequest,
                    callbacks: RunCallbacks,
                    agentEvents: AgentEventCallback = nil,
                    runId = "",
                    approvalPolicy: ToolApprovalPolicy = nil): Future[seq[ContentBlock]] {.async.} =
  if not agentEvents.isNil or not approvalPolicy.isNil:
    ## The normalized event path performs approval before execution and emits
    ## one result per call. Keep this path sequential so an approval can pause
    ## one call without starting sibling side effects.
    for call in calls:
      checkAbort(abort)
      let toolIndex = findTool(tools, call.name)
      var output: ContentBlock
      var started = epochTime()
      var allowed = true
      if not approvalPolicy.isNil and toolIndex >= 0:
        let approval = approvalPolicy(step, call, tools[toolIndex])
        if approval.mode == tamDeny:
          allowed = false
          output = toolResultBlock(call, toolFailure("approval_denied",
            if approval.reason.len > 0: approval.reason else:
              "Tool execution was denied: " & call.name))
        elif approval.mode == tamAsk:
          if agentEvents.isNil:
            raiseProviderError("tool approval requires an AgentEvent consumer")
          let reason = if approval.reason.len > 0: approval.reason else:
            "Tool execution requires approval: " & call.name
          let approvalRequest = newToolApprovalRequest(call, reason)
          if not emitAgentEvent(agentEvents, AgentEvent(
              kind: aeToolApprovalRequired, runId: runId,
              sessionId: request.sessionId, turnId: request.turnId,
              step: step, approval: approvalRequest)):
            raiseCancelledError()
          let decision = await approvalRequest.waitDecision()
          if decision == tadDeny:
            allowed = false
            output = toolResultBlock(call, toolFailure("approval_denied", reason))
      if allowed:
        if not callbacks.onToolStart.isNil: callbacks.onToolStart(step, call)
        started = epochTime()
        output = await execOneAsync(tools, call,
          toolContext(call, request, step, abort))
        if not callbacks.onToolFinish.isNil:
          callbacks.onToolFinish(step, call, output,
            int((epochTime() - started) * 1000))
      result.add output
      if not emitAgentEvent(agentEvents, AgentEvent(kind: aeToolResult,
          runId: runId, sessionId: request.sessionId, turnId: request.turnId,
          step: step, toolResult: output,
          durationMs: int((epochTime() - started) * 1000))):
        raiseCancelledError()
    return
  when compileOption("threads"):
    if batchOverlaps(tools, calls):
      checkAbort(abort)
      let started = epochTime()
      if not callbacks.onToolStart.isNil:
        for call in calls: callbacks.onToolStart(step, call)
      result = execTools(tools, calls, abort, request, step)
      let durationMs = int((epochTime() - started) * 1000)
      if not callbacks.onToolFinish.isNil:
        for i, call in calls:
          callbacks.onToolFinish(step, call, result[i], durationMs)
      return
  if asyncBatchOverlaps(tools, calls):
    checkAbort(abort)
    let started = epochTime()
    var pending: seq[Future[ContentBlock]]
    for call in calls:
      if not callbacks.onToolStart.isNil: callbacks.onToolStart(step, call)
      pending.add execOneAsync(tools, call, toolContext(call, request, step, abort))
    for i, future in pending:
      let output = await future
      result.add output
      if not callbacks.onToolFinish.isNil:
        callbacks.onToolFinish(step, calls[i], output,
          int((epochTime() - started) * 1000))
    return
  for call in calls:
    checkAbort(abort)
    if not callbacks.onToolStart.isNil: callbacks.onToolStart(step, call)
    let started = epochTime()
    let output = await execOneAsync(tools, call,
      toolContext(call, request, step, abort))
    result.add output
    if not callbacks.onToolFinish.isNil:
      callbacks.onToolFinish(step, call, output,
        int((epochTime() - started) * 1000))

proc retryingCall(provider: Provider, request: ProviderRequest,
                  maxRetries: int, abort: AbortCheck,
                  onEvent: StreamCallback,
                  callbacks: RunCallbacks): Future[ProviderResponse] {.async.} =
  for attempt in 0 .. maxRetries:
    checkAbort(abort)
    var started = false
    try:
      if onEvent.isNil:
        return await provider.generateAsync(request)
      return await provider.generateStreamAsync(request, proc (ev: StreamEvent): bool =
        if ev.kind in {seTextDelta, seThinkingDelta, seToolCallDelta}:
          started = true
        if ev.kind == seFinished:
          return true
        onEvent(ev))
    except ProviderError as e:
      if started or e.aborted or e.overflow or not e.retryable or
          attempt == maxRetries:
        raise
      let delayMs = retryDelayMs(attempt, e.retryAfterMs)
      if not callbacks.onRetry.isNil:
        callbacks.onRetry(attempt + 1, delayMs, e)
      await sleepAbort(delayMs, abort)

proc runLoop(provider: Provider, request: ProviderRequest,
             tools: seq[Tool], maxRetries, maxSteps: int,
             abort: AbortCheck,
             onEvent: StreamCallback,
             callbacks: RunCallbacks,
             agentEvents: AgentEventCallback = nil,
             approvalPolicy: ToolApprovalPolicy = nil,
             prompt = ""): Future[ProviderResponse] {.async.} =
  var request = request
  validateToolChoice(request.toolChoice, request.tools)
  var cancelled = false
  var completedSteps: seq[StepResult]
  var totalUsage: Usage
  let runId = if request.turnId.len > 0: request.turnId else:
    "run:" & $epochTime()
  var currentStep = -1
  try:
    if not emitAgentEvent(agentEvents, AgentEvent(kind: aeRunStart,
        runId: runId, sessionId: request.sessionId, turnId: request.turnId,
        step: -1, prompt: prompt, model: request.model)):
      raiseCancelledError()
    let cb = if onEvent.isNil and agentEvents.isNil: nil else:
      proc (ev: StreamEvent): bool =
        if not abort.isNil and abort():
          cancelled = true
          return false
        if not onEvent.isNil and ev.kind != seFinished:
          if not onEvent(ev):
            cancelled = true
            return false
        if not agentEvents.isNil:
          case ev.kind
          of seTextDelta:
            if not emitAgentEvent(agentEvents, AgentEvent(kind: aeTextDelta,
                runId: runId, sessionId: request.sessionId,
                turnId: request.turnId, step: currentStep, text: ev.text)):
              cancelled = true
              return false
          of seThinkingDelta:
            if not emitAgentEvent(agentEvents, AgentEvent(kind: aeThinkingDelta,
                runId: runId, sessionId: request.sessionId,
                turnId: request.turnId, step: currentStep, text: ev.text)):
              cancelled = true
              return false
          else:
            discard
        true
    for step in 0 ..< maxSteps:
      currentStep = step
      if not emitAgentEvent(agentEvents, AgentEvent(kind: aeStepStart,
          runId: runId, sessionId: request.sessionId, turnId: request.turnId,
          step: step, stepModel: request.model)):
        raiseCancelledError()
      result = await retryingCall(provider, request, maxRetries, abort, cb,
        callbacks)
      if cancelled:
        raiseCancelledError()
      let calls = result.toolCalls
      for call in calls:
        if not emitAgentEvent(agentEvents, AgentEvent(kind: aeToolCall,
            runId: runId, sessionId: request.sessionId, turnId: request.turnId,
            step: step, call: call)):
          raiseCancelledError()
      var stepResult = StepResult(model: result.model, content: result.content,
        usage: result.usage, finishReason: result.finishReason)
      totalUsage.addUsage(result.usage)
      let stop = calls.len == 0 or not canExecute(tools) or
        request.toolChoice.kind == tckNone
      let finished = stop or step == maxSteps - 1
      if finished:
        if not stop:
          result.finishReason = frStepLimit
          stepResult.finishReason = frStepLimit
      else:
        stepResult.toolResults = await execToolsAsync(tools, calls, abort, step,
          request, callbacks, agentEvents, runId, approvalPolicy)
      completedSteps.add stepResult
      if not callbacks.onStepFinish.isNil:
        callbacks.onStepFinish(step, stepResult)
      if not emitAgentEvent(agentEvents, AgentEvent(kind: aeStepFinish,
          runId: runId, sessionId: request.sessionId, turnId: request.turnId,
          step: step, stepResult: stepResult)):
        raiseCancelledError()
      if finished: break
      request.messages.add Message(role: roleAssistant, content: result.content)
      request.messages.add userMessage(stepResult.toolResults)
    result.steps = completedSteps
    result.totalUsage = totalUsage
    if not onEvent.isNil and not cancelled:
      discard onEvent(StreamEvent(kind: seFinished))
    if not callbacks.onFinish.isNil: callbacks.onFinish(result)
    if not emitAgentEvent(agentEvents, AgentEvent(kind: aeRunFinish,
        runId: runId, sessionId: request.sessionId, turnId: request.turnId,
        step: currentStep, response: result)):
      raiseCancelledError()
  except CatchableError as e:
    if not emitAgentEvent(agentEvents, AgentEvent(kind: aeError,
        runId: runId, sessionId: request.sessionId, turnId: request.turnId,
        step: currentStep, error: e)):
      discard
    raise

proc generateTextAsync(
  provider: Provider,
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  tools: seq[Tool] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxSteps = 1,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks(),
  turnId = "",
  metadata: JsonNode = nil,
  toolChoice = toolChoiceAuto()
): Future[ProviderResponse] {.async.} =
  ## One-shot completion. `prompt` becomes a user message when `messages` is empty.
  ## `maxRetries` retries 429/5xx/transport (default 2) with jitter and
  ## Retry-After. `maxSteps` > 1 plus
  ## `tool(..., execute=)` runs tools and continues until text or the step cap.
  validateRun(tools, maxRetries, maxSteps)
  let request = buildRequest(model, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, options,
    turnId = turnId, metadata = metadata, toolChoice = toolChoice)
  return await runLoop(provider, request, tools, maxRetries, maxSteps, abort, nil,
    callbacks)

proc generateTextAsync*(
  model: LanguageModel,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  tools: seq[Tool] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxSteps = 1,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks(),
  providerOptions = ProviderOptions(),
  metadata: JsonNode = nil,
  turnId = "",
  toolChoice = toolChoiceAuto()
): Future[ProviderResponse] {.async.} =
  let resolved = resolveOptions(options, providerOptions, model.provider.name)
  return await generateTextAsync(model.provider, model.id, prompt, messages, system, tools,
    maxTokens, sessionId, resolved, maxRetries, maxSteps, abort, callbacks,
    turnId, metadata, toolChoice)

proc generateText*(model: LanguageModel, prompt = "",
                   messages: seq[Message] = @[], system = "",
                   tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
                   options: JsonNode = nil, maxRetries = 2, maxSteps = 1,
                   abort: AbortCheck = nil,
                   callbacks = RunCallbacks(),
                   providerOptions = ProviderOptions(),
                   metadata: JsonNode = nil, turnId = "",
                   toolChoice = toolChoiceAuto()): ProviderResponse =
  waitFor generateTextAsync(model, prompt, messages, system, tools, maxTokens,
    sessionId, options, maxRetries, maxSteps, abort, callbacks, providerOptions,
    metadata, turnId, toolChoice)

proc generateTextAsync*(
  provider: Provider,
  request: ProviderRequest,
  maxRetries = 2,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks(),
  providerOptions = ProviderOptions()
): Future[ProviderResponse] {.async.} =
  ## Retry wrapper for a ready-made request. Does not run the tool loop
  ## (`maxSteps` 1); the caller owns tools.
  validateRun(@[], maxRetries, 1)
  var resolved = request
  resolved.options = resolveOptions(request.options, providerOptions, provider.name)
  return await runLoop(provider, resolved, @[], maxRetries, 1, abort, nil,
    callbacks)

proc generateText*(provider: Provider, request: ProviderRequest,
                   maxRetries = 2,
                   abort: AbortCheck = nil,
                   callbacks = RunCallbacks(),
                   providerOptions = ProviderOptions()): ProviderResponse =
  waitFor generateTextAsync(provider, request, maxRetries, abort, callbacks, providerOptions)

proc streamTextAsync(
  provider: Provider,
  model: string,
  onEvent: StreamCallback,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  tools: seq[Tool] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1,
  maxRetries = 2,
  maxSteps = 1,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks(),
  turnId = "",
  metadata: JsonNode = nil,
  toolChoice = toolChoiceAuto()
): Future[ProviderResponse] {.async.} =
  ## Streaming completion; `onEvent` receives deltas. Return false to cancel.
  validateRun(tools, maxRetries, maxSteps)
  let request = buildRequest(model, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, options, wakeFd,
    turnId, metadata, toolChoice)
  return await runLoop(provider, request, tools, maxRetries, maxSteps, abort,
    onEvent, callbacks)

proc streamTextAsync*(
  model: LanguageModel,
  onEvent: StreamCallback,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  tools: seq[Tool] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1,
  maxRetries = 2,
  maxSteps = 1,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks(),
  providerOptions = ProviderOptions(),
  metadata: JsonNode = nil,
  turnId = "",
  toolChoice = toolChoiceAuto()
): Future[ProviderResponse] {.async.} =
  let resolved = resolveOptions(options, providerOptions, model.provider.name)
  return await streamTextAsync(model.provider, model.id, onEvent, prompt,
    messages, system, tools,
    maxTokens, sessionId, resolved, wakeFd, maxRetries, maxSteps, abort, callbacks,
    turnId, metadata, toolChoice)

proc streamText*(model: LanguageModel, onEvent: StreamCallback, prompt = "",
                 messages: seq[Message] = @[], system = "",
                 tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
                 options: JsonNode = nil, wakeFd: cint = -1, maxRetries = 2,
                 maxSteps = 1, abort: AbortCheck = nil,
                 callbacks = RunCallbacks(),
                 providerOptions = ProviderOptions(),
                 metadata: JsonNode = nil, turnId = "",
                 toolChoice = toolChoiceAuto()): ProviderResponse =
  waitFor streamTextAsync(model, onEvent, prompt, messages, system, tools,
    maxTokens, sessionId, options, wakeFd, maxRetries, maxSteps, abort,
    callbacks, providerOptions, metadata, turnId, toolChoice)

proc streamTextAsync*(
  provider: Provider,
  request: ProviderRequest,
  onEvent: StreamCallback,
  maxRetries = 2,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks(),
  providerOptions = ProviderOptions()
): Future[ProviderResponse] {.async.} =
  ## Streaming retry wrapper for a ready-made request. No tool loop.
  validateRun(@[], maxRetries, 1)
  var resolved = request
  resolved.options = resolveOptions(request.options, providerOptions, provider.name)
  return await runLoop(provider, resolved, @[], maxRetries, 1, abort, onEvent,
    callbacks)

proc streamText*(provider: Provider, request: ProviderRequest,
                 onEvent: StreamCallback, maxRetries = 2,
                 abort: AbortCheck = nil,
                 callbacks = RunCallbacks(),
                 providerOptions = ProviderOptions()): ProviderResponse =
  waitFor streamTextAsync(provider, request, onEvent, maxRetries, abort,
    callbacks, providerOptions)

proc generateAgentTextAsync*(model: LanguageModel,
                             prompt = "",
                             messages: seq[Message] = @[],
                             system = "",
                             tools: seq[Tool] = @[],
                             maxTokens = 0,
                             sessionId = "",
                             options: JsonNode = nil,
                             maxRetries = 2,
                             maxSteps = 1,
                             abort: AbortCheck = nil,
                             callbacks = RunCallbacks(),
                             providerOptions = ProviderOptions(),
                             metadata: JsonNode = nil,
                             turnId = "",
                             toolChoice = toolChoiceAuto(),
                             onEvent: AgentEventCallback = nil,
                             approvalPolicy: ToolApprovalPolicy = nil
                             ): Future[ProviderResponse] {.async.} =
  let resolved = resolveOptions(options, providerOptions, model.provider.name)
  validateRun(tools, maxRetries, maxSteps)
  let request = buildRequest(model.id, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, resolved,
    turnId = turnId, metadata = metadata, toolChoice = toolChoice)
  return await runLoop(model.provider, request, tools, maxRetries, maxSteps,
    abort, nil, callbacks, onEvent, approvalPolicy, prompt)

proc streamAgentTextAsync*(model: LanguageModel,
                           prompt = "",
                           messages: seq[Message] = @[],
                           system = "",
                           tools: seq[Tool] = @[],
                           maxTokens = 0,
                           sessionId = "",
                           options: JsonNode = nil,
                           wakeFd: cint = -1,
                           maxRetries = 2,
                           maxSteps = 1,
                           abort: AbortCheck = nil,
                           callbacks = RunCallbacks(),
                           providerOptions = ProviderOptions(),
                           metadata: JsonNode = nil,
                           turnId = "",
                           toolChoice = toolChoiceAuto(),
                           onEvent: AgentEventCallback = nil,
                           approvalPolicy: ToolApprovalPolicy = nil
                           ): Future[ProviderResponse] {.async.} =
  let resolved = resolveOptions(options, providerOptions, model.provider.name)
  validateRun(tools, maxRetries, maxSteps)
  let request = buildRequest(model.id, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, resolved, wakeFd,
    turnId, metadata, toolChoice)
  return await runLoop(model.provider, request, tools, maxRetries, maxSteps,
    abort, nil, callbacks, onEvent, approvalPolicy, prompt)

proc eventStream*(run: proc (callback: AgentEventCallback): Future[ProviderResponse]
                  {.closure.}): AgentEventStream =
  result = AgentEventStream(queue: newFutureStream[AgentEvent]("agentEvents"))
  let stream = result
  proc pump(): Future[ProviderResponse] {.async.} =
    try:
      return await run(proc (event: AgentEvent): bool =
        if stream.closed: false
        else:
          discard stream.queue.write(event)
          true)
    finally:
      if not stream.queue.finished:
        stream.queue.complete()
  result.result = pump()

proc generateTextAsync*(model: LanguageModel,
                        onEvent: AgentEventCallback,
                        prompt = "",
                        messages: seq[Message] = @[],
                        system = "",
                        tools: seq[Tool] = @[],
                        maxTokens = 0,
                        sessionId = "",
                        options: JsonNode = nil,
                        maxRetries = 2,
                        maxSteps = 1,
                        abort: AbortCheck = nil,
                        callbacks = RunCallbacks(),
                        providerOptions = ProviderOptions(),
                        metadata: JsonNode = nil,
                        turnId = "",
                        toolChoice = toolChoiceAuto(),
                        approvalPolicy: ToolApprovalPolicy = nil
                        ): Future[ProviderResponse] {.async.} =
  return await generateAgentTextAsync(model, prompt, messages, system, tools,
    maxTokens, sessionId, options, maxRetries, maxSteps, abort, callbacks,
    providerOptions, metadata, turnId, toolChoice, onEvent, approvalPolicy)

proc generateText*(model: LanguageModel, onEvent: AgentEventCallback,
                   prompt = "", messages: seq[Message] = @[], system = "",
                   tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
                   options: JsonNode = nil, maxRetries = 2, maxSteps = 1,
                   abort: AbortCheck = nil, callbacks = RunCallbacks(),
                   providerOptions = ProviderOptions(),
                   metadata: JsonNode = nil, turnId = "",
                   toolChoice = toolChoiceAuto(),
                   approvalPolicy: ToolApprovalPolicy = nil): ProviderResponse =
  waitFor generateTextAsync(model, onEvent, prompt, messages, system, tools,
    maxTokens, sessionId, options, maxRetries, maxSteps, abort, callbacks,
    providerOptions, metadata, turnId, toolChoice, approvalPolicy)

proc streamTextAsync*(model: LanguageModel, onEvent: AgentEventCallback,
                      prompt = "", messages: seq[Message] = @[], system = "",
                      tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
                      options: JsonNode = nil, wakeFd: cint = -1,
                      maxRetries = 2, maxSteps = 1,
                      abort: AbortCheck = nil,
                      callbacks = RunCallbacks(),
                      providerOptions = ProviderOptions(),
                      metadata: JsonNode = nil, turnId = "",
                      toolChoice = toolChoiceAuto(),
                      approvalPolicy: ToolApprovalPolicy = nil
                      ): Future[ProviderResponse] {.async.} =
  return await streamAgentTextAsync(model, prompt, messages, system, tools,
    maxTokens, sessionId, options, wakeFd, maxRetries, maxSteps, abort,
    callbacks, providerOptions, metadata, turnId, toolChoice, onEvent,
    approvalPolicy)

proc streamText*(model: LanguageModel, onEvent: AgentEventCallback,
                 prompt = "", messages: seq[Message] = @[], system = "",
                 tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
                 options: JsonNode = nil, wakeFd: cint = -1,
                 maxRetries = 2, maxSteps = 1,
                 abort: AbortCheck = nil, callbacks = RunCallbacks(),
                 providerOptions = ProviderOptions(),
                 metadata: JsonNode = nil, turnId = "",
                 toolChoice = toolChoiceAuto(),
                 approvalPolicy: ToolApprovalPolicy = nil): ProviderResponse =
  waitFor streamTextAsync(model, onEvent, prompt, messages, system, tools,
    maxTokens, sessionId, options, wakeFd, maxRetries, maxSteps, abort,
    callbacks, providerOptions, metadata, turnId, toolChoice, approvalPolicy)

proc generateTextAsync*(provider: Provider, request: ProviderRequest,
                        onEvent: AgentEventCallback,
                        maxRetries = 2, abort: AbortCheck = nil,
                        callbacks = RunCallbacks(),
                        providerOptions = ProviderOptions()
                        ): Future[ProviderResponse] {.async.} =
  validateRun(@[], maxRetries, 1)
  var resolved = request
  resolved.options = resolveOptions(request.options, providerOptions, provider.name)
  return await runLoop(provider, resolved, @[], maxRetries, 1, abort, nil,
    callbacks, onEvent, nil)

proc generateText*(provider: Provider, request: ProviderRequest,
                   onEvent: AgentEventCallback,
                   maxRetries = 2, abort: AbortCheck = nil,
                   callbacks = RunCallbacks(),
                   providerOptions = ProviderOptions()): ProviderResponse =
  waitFor generateTextAsync(provider, request, onEvent, maxRetries, abort,
    callbacks, providerOptions)

proc streamTextAsync*(provider: Provider, request: ProviderRequest,
                      onEvent: AgentEventCallback,
                      maxRetries = 2, abort: AbortCheck = nil,
                      callbacks = RunCallbacks(),
                      providerOptions = ProviderOptions()
                      ): Future[ProviderResponse] {.async.} =
  validateRun(@[], maxRetries, 1)
  var resolved = request
  resolved.options = resolveOptions(request.options, providerOptions, provider.name)
  return await runLoop(provider, resolved, @[], maxRetries, 1, abort, nil,
    callbacks, onEvent, nil)

proc streamText*(provider: Provider, request: ProviderRequest,
                 onEvent: AgentEventCallback, maxRetries = 2,
                 abort: AbortCheck = nil,
                 callbacks = RunCallbacks(),
                 providerOptions = ProviderOptions()): ProviderResponse =
  waitFor streamTextAsync(provider, request, onEvent, maxRetries, abort,
    callbacks, providerOptions)

proc events*(model: LanguageModel, prompt = "",
             messages: seq[Message] = @[], system = "",
             tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
             options: JsonNode = nil, maxRetries = 2, maxSteps = 1,
             abort: AbortCheck = nil, callbacks = RunCallbacks(),
             providerOptions = ProviderOptions(), metadata: JsonNode = nil,
             turnId = "", toolChoice = toolChoiceAuto(),
             approvalPolicy: ToolApprovalPolicy = nil): AgentEventStream =
  eventStream(proc (callback: AgentEventCallback): Future[ProviderResponse]
              {.closure.} =
    streamAgentTextAsync(model, prompt, messages, system, tools, maxTokens,
      sessionId, options, -1, maxRetries, maxSteps, abort, callbacks,
      providerOptions, metadata, turnId, toolChoice, callback, approvalPolicy))

type
  ObjectMode* = enum
    omAuto    ## native structured output when the provider has it
    omNative  ## native only; still extracts/validates/repairs
    omJson    ## prompt + extract JSON from text
    omTool    ## forced submit tool; arguments are the value

  ObjectSource* = enum
    osNative  ## provider-native structured output
    osText     ## JSON extracted from model text
    osTool     ## value extracted from the submit tool

  ObjectTruncation* = enum
    otReject   ## reject locally repaired JSON after max-token truncation
    otRepair   ## accept locally repaired JSON after max-token truncation

  ObjectResult*[T] = object
    value*: T
    response*: ProviderResponse
    usage*: Usage
    repairs*: int
    attempts*: int
    locallyRepaired*: bool
    source*: ObjectSource

const objectToolName = "submit"

proc mergeOptions(base, extra: JsonNode): JsonNode =
  result = if base.isNil or base.kind != JObject: newJObject() else: copy(base)
  if extra.isNil or extra.kind != JObject: return
  for k, v in extra:
    if k == "generationConfig" and k in result and
        result[k].kind == JObject and v.kind == JObject:
      for nestedKey, nestedValue in v:
        result[k][nestedKey] = copy(nestedValue)
    else:
      result[k] = copy(v)

proc objectInstruction(schema: JsonNode, mode: ObjectMode,
                        includeSchema = true): string =
  if includeSchema:
    result = "Respond with a single JSON value that matches this schema:\n"
    result.add schema.pretty
  elif mode == omTool:
    result = "Call the " & objectToolName & " tool with the structured result."
  else:
    result = "Return the structured result as JSON. No markdown, no prose."
  if includeSchema and mode == omTool:
    result.add "\nCall the " & objectToolName & " tool with that value."
  elif includeSchema:
    result.add "\nNo markdown, no prose."

proc appendSystemInstruction(req: var ProviderRequest, instruction: string) =
  if req.system.len == 0:
    req.system.add instruction
  else:
    req.system[^1].add "\n\n" & instruction

proc toolObjectValue(resp: ProviderResponse): tuple[value: JsonNode, issue: string,
                                                    locallyRepaired: bool] =
  let calls = resp.toolCalls
  if calls.len == 0:
    return (nil, "expected one '" & objectToolName & "' tool call, got none", false)
  if calls.len != 1:
    return (nil, "expected one '" & objectToolName & "' tool call, got " &
      $calls.len, false)
  let call = calls[0]
  if call.name != objectToolName:
    return (nil, "expected '" & objectToolName & "' tool call, got '" &
      call.name & "'", false)
  if call.parseError.len > 0:
    return (nil, call.parseError, false)
  if call.input.isNil:
    return (nil, "'" & objectToolName & "' tool call has no arguments", false)
  (call.input, "", false)

proc takeObjectValue(resp: ProviderResponse, useTool: bool,
                     truncation: ObjectTruncation): tuple[value: JsonNode,
                     issue: string, locallyRepaired: bool] =
  if useTool:
    result = toolObjectValue(resp)
    if not result.value.isNil or result.issue.len > 0:
      return
  var parsed = extractJson(resp.text)
  if parsed.isNil:
    let partial = parsePartialJson(resp.text)
    if not partial.value.isNil:
      if partial.state == ppRepaired and resp.finishReason == frMaxTokens and
          truncation == otReject:
        return (nil, "response truncated (max tokens)", false)
      return (partial.value, "", partial.state == ppRepaired)
  if not parsed.isNil:
    return (parsed, "", false)
  if not useTool:
    if resp.toolCalls.len > 0:
      result = toolObjectValue(resp)
      if not result.value.isNil or result.issue.len > 0:
        return
  if resp.finishReason == frMaxTokens:
    return (nil, "response truncated (max tokens)", false)
  return (nil, "no JSON value in the model response", false)

proc repairMessage(issues: seq[string], value: JsonNode, useTool: bool): string =
  result = "Your output did not match the required schema:\n"
  for issue in issues:
    result.add "- " & issue & "\n"
  if not value.isNil:
    result.add "You returned:\n" & value.pretty & "\n"
  if useTool:
    result.add "Call " & objectToolName & " with a corrected value."
  else:
    result.add "Return a corrected JSON value that matches the schema. No markdown."

type PartialObjectCallback* = proc (value: JsonNode): bool {.closure.}
  ## Partial JSON tree. Not schema-valid. Return false to cancel.

type ObjectToolPartial = object
  id: string
  name: string
  args: string

proc objectToolSlot(parts: var seq[ObjectToolPartial], id, name: string): int =
  for i, part in parts:
    if (id.len > 0 and part.id == id) or
        (id.len == 0 and part.id.len == 0 and part.name == name):
      return i
  parts.add ObjectToolPartial(id: id, name: name)
  parts.high

type ObjectSession = object
  provider: Provider
  req: ProviderRequest
  schema: JsonNode
  useTool: bool
  source: ObjectSource
  truncation: ObjectTruncation
  maxRetries: int

proc startObjectSession(
  provider: Provider, req: ProviderRequest, schema: JsonNode,
  name, description: string, mode: ObjectMode, maxRetries, maxRepairs: int,
  truncation: ObjectTruncation
): ObjectSession =
  if maxRepairs < 0:
    raiseProviderError("maxRepairs must be at least 0")
  if schema.isNil or schema.kind != JObject:
    raiseObjectError("generateObject requires a JSON Schema object", @[])
  let schemaIssues = validateJsonSchema(schema)
  if schemaIssues.len > 0:
    raiseObjectError("generateObject received an invalid JSON Schema: " &
      schemaIssues.join("; "), schemaIssues)
  let wire = prepareWireSchema(schema)
  let nativeOptions = provider.nativeObjectOptions(
    schemaName(name), description, wire)
  let nativeIssues = if nativeOptions.isNil: @[]
                     else: provider.nativeObjectSchemaIssues(wire)
  let native = if nativeIssues.len == 0: nativeOptions else: nil
  result.provider = provider
  result.req = req
  result.schema = schema
  result.truncation = truncation
  result.maxRetries = maxRetries
  case mode
  of omNative:
    if not nativeOptions.isNil and nativeIssues.len > 0:
      raiseObjectError("schema is incompatible with provider '" & provider.name &
        "' native structured output: " & nativeIssues.join("; "), nativeIssues)
    if nativeOptions.isNil:
      raiseObjectError("provider '" & provider.name &
        "' has no native structured output", @[])
    appendSystemInstruction(result.req, objectInstruction(wire, mode, false))
    result.req.options = mergeOptions(result.req.options, native)
    result.source = osNative
  of omAuto:
    appendSystemInstruction(result.req,
      objectInstruction(if native.isNil: schema else: wire, mode, native.isNil))
    if not native.isNil:
      result.req.options = mergeOptions(result.req.options, native)
      result.source = osNative
    else:
      result.source = osText
  of omTool:
    if wire.getOrDefault("type").getStr != "object":
      raiseObjectError("tool structured output requires a root object schema",
        @["$: tool structured output requires type object at the root"])
    appendSystemInstruction(result.req, objectInstruction(wire, mode, false))
    result.useTool = true
    result.req.tools = @[ToolDefinition(name: objectToolName,
      description: "Submit the structured result.", inputSchema: wire)]
    result.req.toolChoice = toolChoiceSpecific(objectToolName)
    result.source = osTool
  of omJson:
    appendSystemInstruction(result.req, objectInstruction(schema, mode, true))
    result.source = osText

proc acceptObject(resp: ProviderResponse, schema: JsonNode,
                  useTool: bool, truncation: ObjectTruncation): tuple[value: JsonNode,
                  issues: seq[string], raw: string, locallyRepaired: bool] =
  let taken = takeObjectValue(resp, useTool, truncation)
  result.value = taken.value
  result.raw = if taken.value.isNil: resp.text else: $taken.value
  result.locallyRepaired = taken.locallyRepaired
  if taken.value.isNil:
    result.issues = @[taken.issue]
  else:
    result.issues = validateSchema(taken.value, schema)

proc emitPartial(acc: string, last: var JsonNode, onPartial: PartialObjectCallback): bool =
  if onPartial.isNil: return true
  let parsed = parsePartialJson(acc)
  if parsed.value.isNil: return true
  if not last.isNil and jsonEqual(last, parsed.value): return true
  last = parsed.value
  onPartial(parsed.value)

proc finishObjectAsync(session: ObjectSession, first: ProviderResponse,
                       maxRepairs: int,
                       abort: AbortCheck): Future[ObjectResult[JsonNode]] {.async.} =
  var session = session
  result.response = first
  result.source = session.source
  var taken: tuple[value: JsonNode, issues: seq[string], raw: string,
                   locallyRepaired: bool]
  for repair in 0 .. maxRepairs:
    if repair > 0:
      session.req.messages.add Message(role: roleAssistant,
        content: result.response.content)
      let instruction = repairMessage(taken.issues, taken.value, session.useTool)
      if session.useTool and result.response.toolCalls.len > 0:
        var parts: seq[ContentBlock]
        for call in result.response.toolCalls:
          parts.add toolResult(call.id, instruction, isError = true)
        parts.add text(instruction)
        session.req.messages.add userMessage(parts)
      else:
        session.req.messages.add userMessage(instruction)
      result.response = await generateTextAsync(session.provider, session.req,
        session.maxRetries, abort)
    result.usage.addUsage(result.response.usage)
    result.repairs = repair
    result.attempts = repair + 1
    taken = acceptObject(result.response, session.schema, session.useTool,
      session.truncation)
    result.locallyRepaired = result.locallyRepaired or taken.locallyRepaired
    if taken.issues.len == 0:
      result.value = taken.value
      return
  let prefix =
    if maxRepairs == 0: "generateObject failed: "
    else: "generateObject failed after " & $maxRepairs & " repair(s): "
  raiseObjectError(prefix & taken.issues.join("; "), taken.issues, taken.raw)

proc generateObjectAsync(
  provider: Provider,
  model: string,
  schema: JsonNode,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  name = "object",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil,
  truncation = otReject
): Future[ObjectResult[JsonNode]] {.async.} =
  ## Schema in, JSON out. Uses native structured output when the provider
  ## has it (`omAuto`), extracts JSON from text or a tool call, validates.
  ## Truncated JSON is rejected by default; set `truncation = otRepair` to
  ## accept locally repaired JSON. `maxRepairs` (default 0) is extra model
  ## turns after local parsing/validation fails.
  var session = startObjectSession(
    provider,
    buildRequest(model, prompt, messages, system, @[], maxTokens, sessionId, options),
    schema, name, description, mode, maxRetries, maxRepairs, truncation)
  let first = await generateTextAsync(session.provider, session.req,
    session.maxRetries, abort)
  return await finishObjectAsync(session, first, maxRepairs, abort)

proc generateObjectAsync*(
  model: LanguageModel,
  schema: JsonNode,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  name = "object",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil,
  providerOptions = ProviderOptions(),
  truncation = otReject
): Future[ObjectResult[JsonNode]] {.async.} =
  let resolved = resolveOptions(options, providerOptions, model.provider.name)
  return await generateObjectAsync(model.provider, model.id, schema,
    prompt = prompt, messages = messages, system = system, name = name,
    description = description, maxTokens = maxTokens, sessionId = sessionId,
    options = resolved, maxRetries = maxRetries, maxRepairs = maxRepairs,
    mode = mode, abort = abort, truncation = truncation)

proc generateObject*(model: LanguageModel, schema: JsonNode, prompt = "",
                     messages: seq[Message] = @[], system = "",
                     name = "object", description = "", maxTokens = 0,
                     sessionId = "", options: JsonNode = nil, maxRetries = 2,
                     maxRepairs = 0, mode = omAuto,
                     abort: AbortCheck = nil,
                     providerOptions = ProviderOptions(),
                     truncation = otReject): ObjectResult[JsonNode] =
  waitFor generateObjectAsync(model, schema, prompt = prompt,
    messages = messages, system = system, name = name,
    description = description, maxTokens = maxTokens, sessionId = sessionId,
    options = options, maxRetries = maxRetries, maxRepairs = maxRepairs,
    mode = mode, abort = abort, providerOptions = providerOptions,
    truncation = truncation)

proc streamObjectAsync(
  provider: Provider,
  model: string,
  schema: JsonNode,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  name = "object",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil,
  onPartial: PartialObjectCallback = nil,
  onEvent: StreamCallback = nil,
  truncation = otReject
): Future[ObjectResult[JsonNode]] {.async.} =
  ## Like `generateObject`, but the first attempt streams. `onPartial` gets
  ## the repaired JSON tree whenever it changes (not schema-valid). Schema
  ## check and optional model repairs run after the stream ends. Max-token
  ## truncation is rejected unless `truncation = otRepair`.
  var session = startObjectSession(
    provider,
    buildRequest(model, prompt, messages, system, @[], maxTokens, sessionId,
      options, wakeFd),
    schema, name, description, mode, maxRetries, maxRepairs, truncation)
  var cancelled = false
  var lastPartial: JsonNode = nil
  var accText = ""
  var accTool = ""
  var toolParts: seq[ObjectToolPartial] = @[]
  let first = await streamTextAsync(
    session.provider, session.req,
    onEvent = proc (ev: StreamEvent): bool =
      case ev.kind
      of seTextDelta:
        accText.add ev.text
        if not emitPartial(accText, lastPartial, onPartial):
          cancelled = true
          return false
      of seToolCallDelta:
        if session.useTool:
          if ev.toolName == objectToolName:
            let slot = objectToolSlot(toolParts, ev.toolCallId, ev.toolName)
            toolParts[slot].args.add ev.toolArgs
            if not emitPartial(toolParts[slot].args, lastPartial, onPartial):
              cancelled = true
              return false
        else:
          accTool.add ev.toolArgs
          if not emitPartial(accTool, lastPartial, onPartial):
            cancelled = true
            return false
      else:
        discard
      if not onEvent.isNil and not onEvent(ev):
        cancelled = true
        return false
      true,
    maxRetries = session.maxRetries, abort = abort)
  if cancelled:
    raiseCancelledError()
  return await finishObjectAsync(session, first, maxRepairs, abort)

proc streamObjectAsync*(
  model: LanguageModel,
  schema: JsonNode,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  name = "object",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil,
  onPartial: PartialObjectCallback = nil,
  onEvent: StreamCallback = nil,
  providerOptions = ProviderOptions(),
  truncation = otReject
): Future[ObjectResult[JsonNode]] {.async.} =
  let resolved = resolveOptions(options, providerOptions, model.provider.name)
  return await streamObjectAsync(model.provider, model.id, schema,
    prompt = prompt, messages = messages, system = system, name = name,
    description = description, maxTokens = maxTokens, sessionId = sessionId,
    options = resolved, wakeFd = wakeFd, maxRetries = maxRetries,
    maxRepairs = maxRepairs, mode = mode, abort = abort,
    onPartial = onPartial, onEvent = onEvent, truncation = truncation)

proc streamObject*(model: LanguageModel, schema: JsonNode, prompt = "",
                   messages: seq[Message] = @[], system = "",
                   name = "object", description = "", maxTokens = 0,
                   sessionId = "", options: JsonNode = nil, wakeFd: cint = -1,
                   maxRetries = 2, maxRepairs = 0, mode = omAuto,
                   abort: AbortCheck = nil,
                   onPartial: PartialObjectCallback = nil,
                   onEvent: StreamCallback = nil,
                   providerOptions = ProviderOptions(),
                   truncation = otReject): ObjectResult[JsonNode] =
  waitFor streamObjectAsync(model, schema, prompt = prompt,
    messages = messages, system = system, name = name,
    description = description, maxTokens = maxTokens, sessionId = sessionId,
    options = options, wakeFd = wakeFd, maxRetries = maxRetries,
    maxRepairs = maxRepairs, mode = mode, abort = abort,
    onPartial = onPartial, onEvent = onEvent,
    providerOptions = providerOptions, truncation = truncation)

proc toObject*[T](r: ObjectResult[JsonNode]): ObjectResult[T] =
  ## Decode `r.value` as `T`. Validation already ran against the schema.
  when T is JsonNode:
    {.error: "toObject[JsonNode] is a no-op; use the ObjectResult[JsonNode]".}
  try:
    result.value = jsonTo(r.value, T, Joptions(allowMissingKeys: true))
  except CatchableError as e:
    raiseObjectError("decoded JSON does not match " & $T & ": " & e.msg,
      @["$.: " & e.msg], $r.value)
  result.response = r.response
  result.usage = r.usage
  result.repairs = r.repairs
  result.attempts = r.attempts
  result.locallyRepaired = r.locallyRepaired
  result.source = r.source

proc generateObjectAsync*[T](
  model: LanguageModel,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  name = "",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil,
  providerOptions = ProviderOptions(),
  truncation = otReject
): Future[ObjectResult[T]] {.async.} =
  ## `generateObject` with `jsonSchema(T)`, then `toObject`.
  when T is JsonNode:
    {.error: "use generateObject(..., schema=) for JsonNode; not generateObject[JsonNode]".}
  let nm = if name.len > 0: name else: $T
  return toObject[T](await generateObjectAsync(model, jsonSchema(T),
    prompt = prompt, messages = messages, system = system, name = nm,
    description = description, maxTokens = maxTokens, sessionId = sessionId,
    options = options, maxRetries = maxRetries, maxRepairs = maxRepairs,
    mode = mode, abort = abort, providerOptions = providerOptions,
    truncation = truncation))

proc generateObject*[T](model: LanguageModel, prompt = "",
                        messages: seq[Message] = @[], system = "", name = "",
                        description = "", maxTokens = 0, sessionId = "",
                        options: JsonNode = nil, maxRetries = 2,
                        maxRepairs = 0, mode = omAuto,
                        abort: AbortCheck = nil,
                        providerOptions = ProviderOptions(),
                        truncation = otReject): ObjectResult[T] =
  waitFor generateObjectAsync[T](model, prompt = prompt, messages = messages,
    system = system, name = name, description = description,
    maxTokens = maxTokens, sessionId = sessionId, options = options,
    maxRetries = maxRetries, maxRepairs = maxRepairs, mode = mode,
    abort = abort, providerOptions = providerOptions, truncation = truncation)

proc streamObjectAsync*[T](
  model: LanguageModel,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  name = "",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil,
  onPartial: PartialObjectCallback = nil,
  onEvent: StreamCallback = nil,
  providerOptions = ProviderOptions(),
  truncation = otReject
): Future[ObjectResult[T]] {.async.} =
  when T is JsonNode:
    {.error: "use streamObject(..., schema=) for JsonNode; not streamObject[JsonNode]".}
  let nm = if name.len > 0: name else: $T
  return toObject[T](await streamObjectAsync(model, jsonSchema(T),
    prompt = prompt, messages = messages, system = system, name = nm,
    description = description, maxTokens = maxTokens, sessionId = sessionId,
    options = options, wakeFd = wakeFd, maxRetries = maxRetries,
    maxRepairs = maxRepairs, mode = mode, abort = abort,
    onPartial = onPartial, onEvent = onEvent,
    providerOptions = providerOptions, truncation = truncation))

proc streamObject*[T](model: LanguageModel, prompt = "",
                      messages: seq[Message] = @[], system = "", name = "",
                      description = "", maxTokens = 0, sessionId = "",
                      options: JsonNode = nil, wakeFd: cint = -1,
                      maxRetries = 2, maxRepairs = 0, mode = omAuto,
                      abort: AbortCheck = nil,
                      onPartial: PartialObjectCallback = nil,
                      onEvent: StreamCallback = nil,
                      providerOptions = ProviderOptions(),
                      truncation = otReject): ObjectResult[T] =
  waitFor streamObjectAsync[T](model, prompt = prompt, messages = messages,
    system = system, name = name, description = description,
    maxTokens = maxTokens, sessionId = sessionId, options = options,
    wakeFd = wakeFd, maxRetries = maxRetries, maxRepairs = maxRepairs,
    mode = mode, abort = abort, onPartial = onPartial, onEvent = onEvent,
    providerOptions = providerOptions, truncation = truncation)
