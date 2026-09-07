## Lightweight LLM client: shared types, generate/stream facade, providers.

import nimgent/provider
export provider

import nimgent/jsonschema
export jsonschema

import std/[asyncdispatch, json, os, random, strutils, times]
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

proc buildRequest(
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system = "",
  tools: seq[ToolDefinition] = @[],
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  wakeFd: cint = -1
): ProviderRequest =
  if model.len == 0:
    raiseProviderError("model must not be empty")
  if prompt.len > 0 and messages.len > 0:
    raiseProviderError("pass either prompt or messages, not both")
  if prompt.len == 0 and messages.len == 0:
    raiseProviderError("prompt or messages is required")
  if not options.isNil and options.kind notin {JNull, JObject}:
    raiseProviderError("options must be a JSON object")
  result = ProviderRequest(
    model: model,
    sessionId: sessionId,
    system: if system.len > 0: @[system] else: @[],
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
    if not t.execute.isNil or not t.executeAsync.isNil: return true

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

proc toolOutput[Output](output: Output): ToolOutput =
  when Output is string: ToolOutput(output: output)
  elif Output is ToolOutput: output
  else: ToolOutput(output: $(%*output))

proc tool*[Input, Output](name, description: string,
                          execute: proc (input: Input): Output {.closure.},
                          parallel = false): Tool =
  ## Typed tool with a derived input schema and automatic JSON conversion.
  rawTool(name, description, jsonSchema(Input),
    proc (input: JsonNode): ToolOutput =
      toolOutput(execute(input.to(Input))),
    parallel)

proc tool*[Input, Output](name, description: string,
                          execute: proc (input: Input): Future[Output] {.closure.},
                          parallel = false): Tool =
  ## Typed async tool; parallel calls overlap when `parallel` is true.
  rawAsyncTool(name, description, jsonSchema(Input),
    proc (input: JsonNode): Future[ToolOutput] {.async.} =
      return toolOutput(await execute(input.to(Input))),
    parallel)

proc findTool(tools: openArray[Tool], name: string): int =
  for i, t in tools:
    if t.name == name: return i
  -1

proc execOne(tools: openArray[Tool], call: ContentBlock): ContentBlock =
  let bad = invalidToolCall(call)
  if bad.len > 0:
    return toolResult(call.id, bad, true)
  let i = findTool(tools, call.name)
  if i < 0 or (tools[i].execute.isNil and tools[i].executeAsync.isNil):
    return toolResult(call.id, "Unknown tool: " & call.name, true)
  try:
    let outp = tools[i].execute(call.input)
    toolResult(call.id, outp.output, outp.isError, outp.images)
  except CatchableError as e:
    toolResult(call.id, e.msg, true)

proc execOneAsync(tools: seq[Tool], call: ContentBlock): Future[ContentBlock] {.async.} =
  let bad = invalidToolCall(call)
  if bad.len > 0: return toolResult(call.id, bad, true)
  let i = findTool(tools, call.name)
  if i < 0 or (tools[i].execute.isNil and tools[i].executeAsync.isNil):
    return toolResult(call.id, "Unknown tool: " & call.name, true)
  try:
    if not tools[i].executeAsync.isNil:
      let output = await tools[i].executeAsync(call.input)
      return toolResult(call.id, output.output, output.isError, output.images)
    return execOne(tools, call)
  except CatchableError as e:
    return toolResult(call.id, e.msg, true)

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

proc asyncBatchOverlaps(tools: openArray[Tool],
                        calls: openArray[ContentBlock]): bool =
  var n = 0
  for call in calls:
    if invalidToolCall(call).len > 0: continue
    let i = findTool(tools, call.name)
    if i < 0 or (tools[i].execute.isNil and tools[i].executeAsync.isNil): continue
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

proc execToolsAsync(tools: seq[Tool], calls: seq[ContentBlock],
                    abort: AbortCheck, step: int,
                    callbacks: RunCallbacks): Future[seq[ContentBlock]] {.async.} =
  when compileOption("threads"):
    if batchOverlaps(tools, calls):
      checkAbort(abort)
      let started = epochTime()
      if not callbacks.onToolStart.isNil:
        for call in calls: callbacks.onToolStart(step, call)
      result = execTools(tools, calls, abort)
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
      pending.add execOneAsync(tools, call)
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
    let output = await execOneAsync(tools, call)
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
             callbacks: RunCallbacks): Future[ProviderResponse] {.async.} =
  var request = request
  let stepCap = max(1, maxSteps)
  var cancelled = false
  var completedSteps: seq[StepResult]
  var totalUsage: Usage
  let cb = if onEvent.isNil: nil else:
    proc (ev: StreamEvent): bool =
      if not abort.isNil and abort():
        cancelled = true
        return false
      if not onEvent(ev):
        cancelled = true
        return false
      true
  for step in 0 ..< stepCap:
    result = await retryingCall(provider, request, maxRetries, abort, cb, callbacks)
    if cancelled:
      raiseCancelledError()
    let calls = result.toolCalls
    var stepResult = StepResult(model: result.model, content: result.content,
      usage: result.usage, finishReason: result.finishReason)
    totalUsage.addUsage(result.usage)
    if calls.len == 0 or not canExecute(tools):
      completedSteps.add stepResult
      if not callbacks.onStepFinish.isNil:
        callbacks.onStepFinish(step, stepResult)
      break
    if step == stepCap - 1:
      completedSteps.add stepResult
      result.finishReason = frStepLimit
      if not callbacks.onStepFinish.isNil:
        callbacks.onStepFinish(step, stepResult)
      break
    let parts = await execToolsAsync(tools, calls, abort, step, callbacks)
    stepResult.toolResults = parts
    completedSteps.add stepResult
    if not callbacks.onStepFinish.isNil:
      callbacks.onStepFinish(step, stepResult)
    request.messages.add Message(role: roleAssistant, content: result.content)
    request.messages.add userMessage(parts)
  result.steps = completedSteps
  result.totalUsage = totalUsage
  if not onEvent.isNil and not cancelled:
    discard onEvent(StreamEvent(kind: seFinished))
  if not callbacks.onFinish.isNil: callbacks.onFinish(result)

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
  callbacks = RunCallbacks()
): Future[ProviderResponse] {.async.} =
  ## One-shot completion. `prompt` becomes a user message when `messages` is empty.
  ## `maxRetries` retries 429/5xx/transport (default 2) with jitter and
  ## Retry-After. `maxSteps` > 1 plus
  ## `tool(..., execute=)` runs tools and continues until text or the step cap.
  validateRun(tools, maxRetries, maxSteps)
  let request = buildRequest(model, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, options)
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
  callbacks = RunCallbacks()
): Future[ProviderResponse] {.async.} =
  return await generateTextAsync(model.provider, model.id, prompt, messages, system, tools,
    maxTokens, sessionId, options, maxRetries, maxSteps, abort, callbacks)

proc generateText*(model: LanguageModel, prompt = "",
                   messages: seq[Message] = @[], system = "",
                   tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
                   options: JsonNode = nil, maxRetries = 2, maxSteps = 1,
                   abort: AbortCheck = nil,
                   callbacks = RunCallbacks()): ProviderResponse =
  waitFor generateTextAsync(model, prompt, messages, system, tools, maxTokens,
    sessionId, options, maxRetries, maxSteps, abort, callbacks)

proc generateTextAsync*(
  provider: Provider,
  request: ProviderRequest,
  maxRetries = 2,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks()
): Future[ProviderResponse] {.async.} =
  ## Retry wrapper for a ready-made request. Does not run the tool loop
  ## (`maxSteps` 1); the caller owns tools.
  validateRun(@[], maxRetries, 1)
  return await runLoop(provider, request, @[], maxRetries, 1, abort, nil,
    callbacks)

proc generateText*(provider: Provider, request: ProviderRequest,
                   maxRetries = 2,
                   abort: AbortCheck = nil,
                   callbacks = RunCallbacks()): ProviderResponse =
  waitFor generateTextAsync(provider, request, maxRetries, abort, callbacks)

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
  callbacks = RunCallbacks()
): Future[ProviderResponse] {.async.} =
  ## Streaming completion; `onEvent` receives deltas. Return false to cancel.
  validateRun(tools, maxRetries, maxSteps)
  let request = buildRequest(model, prompt, messages, system,
    toDefinitions(tools), maxTokens, sessionId, options, wakeFd)
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
  callbacks = RunCallbacks()
): Future[ProviderResponse] {.async.} =
  return await streamTextAsync(model.provider, model.id, onEvent, prompt,
    messages, system, tools,
    maxTokens, sessionId, options, wakeFd, maxRetries, maxSteps, abort, callbacks)

proc streamText*(model: LanguageModel, onEvent: StreamCallback, prompt = "",
                 messages: seq[Message] = @[], system = "",
                 tools: seq[Tool] = @[], maxTokens = 0, sessionId = "",
                 options: JsonNode = nil, wakeFd: cint = -1, maxRetries = 2,
                 maxSteps = 1, abort: AbortCheck = nil,
                 callbacks = RunCallbacks()): ProviderResponse =
  waitFor streamTextAsync(model, onEvent, prompt, messages, system, tools,
    maxTokens, sessionId, options, wakeFd, maxRetries, maxSteps, abort, callbacks)

proc streamTextAsync*(
  provider: Provider,
  request: ProviderRequest,
  onEvent: StreamCallback,
  maxRetries = 2,
  abort: AbortCheck = nil,
  callbacks = RunCallbacks()
): Future[ProviderResponse] {.async.} =
  ## Streaming retry wrapper for a ready-made request. No tool loop.
  validateRun(@[], maxRetries, 1)
  return await runLoop(provider, request, @[], maxRetries, 1, abort, onEvent,
    callbacks)

proc streamText*(provider: Provider, request: ProviderRequest,
                 onEvent: StreamCallback, maxRetries = 2,
                 abort: AbortCheck = nil,
                 callbacks = RunCallbacks()): ProviderResponse =
  waitFor streamTextAsync(provider, request, onEvent, maxRetries, abort,
    callbacks)

type
  ObjectMode* = enum
    omAuto    ## native structured output when the provider has it
    omNative  ## native only; still extracts/validates/repairs
    omJson    ## prompt + extract JSON from text
    omTool    ## forced submit tool; arguments are the value

  ObjectResult*[T] = object
    value*: T
    response*: ProviderResponse
    usage*: Usage
    repairs*: int

const objectToolName = "submit"

proc mergeOptions(base, extra: JsonNode): JsonNode =
  result = if base.isNil or base.kind != JObject: newJObject() else: copy(base)
  if extra.isNil or extra.kind != JObject: return
  for k, v in extra:
    result[k] = copy(v)

proc objectInstruction(schema: JsonNode, mode: ObjectMode): string =
  result = "Respond with a single JSON value that matches this schema:\n"
  result.add schema.pretty
  if mode == omTool:
    result.add "\nCall the " & objectToolName & " tool with that value."
  else:
    result.add "\nNo markdown, no prose."

proc toolObjectValue(resp: ProviderResponse): tuple[value: JsonNode, issue: string] =
  if resp.toolCalls.len == 0:
    return (nil, "")
  let bad = invalidToolCall(resp.toolCalls[0])
  if bad.len > 0:
    return (nil, bad)
  (resp.toolCalls[0].input, "")

proc takeObjectValue(resp: ProviderResponse, useTool: bool): tuple[value: JsonNode, issue: string] =
  if useTool:
    result = toolObjectValue(resp)
    if not result.value.isNil or result.issue.len > 0:
      return
  var parsed = extractJson(resp.text)
  if parsed.isNil:
    parsed = parsePartialJson(resp.text).value
  if not parsed.isNil:
    return (parsed, "")
  if not useTool:
    result = toolObjectValue(resp)
    if not result.value.isNil or result.issue.len > 0:
      return
  if resp.finishReason == frMaxTokens:
    return (nil, "response truncated (max tokens)")
  return (nil, "no JSON object or array in the model response")

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

type ObjectSession = object
  provider: Provider
  req: ProviderRequest
  schema: JsonNode
  useTool: bool
  maxRetries: int

proc startObjectSession(
  provider: Provider, req: ProviderRequest, schema: JsonNode,
  name, description: string, mode: ObjectMode, maxRetries: int
): ObjectSession =
  if schema.isNil or schema.kind != JObject:
    raiseObjectError("generateObject requires a JSON Schema object", @[])
  let wire = prepareWireSchema(schema)
  result.provider = provider
  result.req = req
  result.schema = schema
  result.maxRetries = maxRetries
  result.req.system.add objectInstruction(wire, mode)
  let native = provider.nativeObjectOptions(schemaName(name), description, wire)
  case mode
  of omNative:
    if native.isNil:
      raiseObjectError("provider '" & provider.name &
        "' has no native structured output", @[])
    result.req.options = mergeOptions(result.req.options, native)
  of omAuto:
    if not native.isNil:
      result.req.options = mergeOptions(result.req.options, native)
  of omTool:
    result.useTool = true
    result.req.tools = @[ToolDefinition(name: objectToolName,
      description: "Submit the structured result.", inputSchema: wire)]
    let forced = provider.forceToolOptions(objectToolName)
    if not forced.isNil:
      result.req.options = mergeOptions(result.req.options, forced)
  of omJson:
    discard

proc acceptObject(resp: ProviderResponse, schema: JsonNode,
                  useTool: bool): tuple[value: JsonNode, issues: seq[string], raw: string] =
  let taken = takeObjectValue(resp, useTool)
  result.value = taken.value
  result.raw = if taken.value.isNil: resp.text else: $taken.value
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
  var taken: tuple[value: JsonNode, issues: seq[string], raw: string]
  for repair in 0 .. maxRepairs:
    if repair > 0:
      session.req.messages.add Message(role: roleAssistant,
        content: result.response.content)
      session.req.messages.add userMessage(
        repairMessage(taken.issues, taken.value, session.useTool))
      result.response = await generateTextAsync(session.provider, session.req,
        session.maxRetries, abort)
    result.usage.addUsage(result.response.usage)
    result.repairs = repair
    taken = acceptObject(result.response, session.schema, session.useTool)
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
  abort: AbortCheck = nil
): Future[ObjectResult[JsonNode]] {.async.} =
  ## Schema in, JSON out. Uses native structured output when the provider
  ## has it (`omAuto`), extracts JSON from text or a tool call, validates.
  ## Truncated JSON is closed with `fixJson`. `maxRepairs` (default 0) is
  ## extra model turns after that.
  var session = startObjectSession(
    provider,
    buildRequest(model, prompt, messages, system, @[], maxTokens, sessionId, options),
    schema, name, description, mode, maxRetries)
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
  abort: AbortCheck = nil
): Future[ObjectResult[JsonNode]] {.async.} =
  return await generateObjectAsync(model.provider, model.id, schema, prompt,
    messages, system,
    name, description, maxTokens, sessionId, options, maxRetries, maxRepairs,
    mode, abort)

proc generateObject*(model: LanguageModel, schema: JsonNode, prompt = "",
                     messages: seq[Message] = @[], system = "",
                     name = "object", description = "", maxTokens = 0,
                     sessionId = "", options: JsonNode = nil, maxRetries = 2,
                     maxRepairs = 0, mode = omAuto,
                     abort: AbortCheck = nil): ObjectResult[JsonNode] =
  waitFor generateObjectAsync(model, schema, prompt, messages, system, name,
    description, maxTokens, sessionId, options, maxRetries, maxRepairs, mode,
    abort)

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
  onEvent: StreamCallback = nil
): Future[ObjectResult[JsonNode]] {.async.} =
  ## Like `generateObject`, but the first attempt streams. `onPartial` gets
  ## the repaired JSON tree whenever it changes (not schema-valid). Schema
  ## check and optional model repairs run after the stream ends.
  var session = startObjectSession(
    provider,
    buildRequest(model, prompt, messages, system, @[], maxTokens, sessionId,
      options, wakeFd),
    schema, name, description, mode, maxRetries)
  var cancelled = false
  var lastPartial: JsonNode = nil
  var accText = ""
  var accTool = ""
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
  onEvent: StreamCallback = nil
): Future[ObjectResult[JsonNode]] {.async.} =
  return await streamObjectAsync(model.provider, model.id, schema, prompt,
    messages, system,
    name, description, maxTokens, sessionId, options, wakeFd, maxRetries,
    maxRepairs, mode, abort, onPartial, onEvent)

proc streamObject*(model: LanguageModel, schema: JsonNode, prompt = "",
                   messages: seq[Message] = @[], system = "",
                   name = "object", description = "", maxTokens = 0,
                   sessionId = "", options: JsonNode = nil, wakeFd: cint = -1,
                   maxRetries = 2, maxRepairs = 0, mode = omAuto,
                   abort: AbortCheck = nil,
                   onPartial: PartialObjectCallback = nil,
                   onEvent: StreamCallback = nil): ObjectResult[JsonNode] =
  waitFor streamObjectAsync(model, schema, prompt, messages, system, name,
    description, maxTokens, sessionId, options, wakeFd, maxRetries, maxRepairs,
    mode, abort, onPartial, onEvent)

proc toObject*[T](r: ObjectResult[JsonNode]): ObjectResult[T] =
  ## Decode `r.value` as `T`. Validation already ran against the schema.
  when T is JsonNode:
    {.error: "toObject[JsonNode] is a no-op; use the ObjectResult[JsonNode]".}
  try:
    result.value = r.value.to(T)
  except CatchableError as e:
    raiseObjectError("decoded JSON does not match " & $T & ": " & e.msg,
      @["$.: " & e.msg], $r.value)
  result.response = r.response
  result.usage = r.usage
  result.repairs = r.repairs

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
  abort: AbortCheck = nil
): Future[ObjectResult[T]] {.async.} =
  ## `generateObject` with `jsonSchema(T)`, then `toObject`.
  when T is JsonNode:
    {.error: "use generateObject(..., schema=) for JsonNode; not generateObject[JsonNode]".}
  let nm = if name.len > 0: name else: $T
  return toObject[T](await generateObjectAsync(
    model, jsonSchema(T), prompt, messages, system, nm, description,
    maxTokens, sessionId, options, maxRetries, maxRepairs, mode, abort))

proc generateObject*[T](model: LanguageModel, prompt = "",
                        messages: seq[Message] = @[], system = "", name = "",
                        description = "", maxTokens = 0, sessionId = "",
                        options: JsonNode = nil, maxRetries = 2,
                        maxRepairs = 0, mode = omAuto,
                        abort: AbortCheck = nil): ObjectResult[T] =
  waitFor generateObjectAsync[T](model, prompt, messages, system, name,
    description, maxTokens, sessionId, options, maxRetries, maxRepairs, mode,
    abort)

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
  onEvent: StreamCallback = nil
): Future[ObjectResult[T]] {.async.} =
  when T is JsonNode:
    {.error: "use streamObject(..., schema=) for JsonNode; not streamObject[JsonNode]".}
  let nm = if name.len > 0: name else: $T
  return toObject[T](await streamObjectAsync(
    model, jsonSchema(T), prompt, messages, system, nm, description,
    maxTokens, sessionId, options, wakeFd, maxRetries, maxRepairs, mode, abort,
    onPartial, onEvent))

proc streamObject*[T](model: LanguageModel, prompt = "",
                      messages: seq[Message] = @[], system = "", name = "",
                      description = "", maxTokens = 0, sessionId = "",
                      options: JsonNode = nil, wakeFd: cint = -1,
                      maxRetries = 2, maxRepairs = 0, mode = omAuto,
                      abort: AbortCheck = nil,
                      onPartial: PartialObjectCallback = nil,
                      onEvent: StreamCallback = nil): ObjectResult[T] =
  waitFor streamObjectAsync[T](model, prompt, messages, system, name,
    description, maxTokens, sessionId, options, wakeFd, maxRetries, maxRepairs,
    mode, abort, onPartial, onEvent)
