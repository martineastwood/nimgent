## Lightweight LLM client: shared types, generate/stream facade, providers.

import nimgent/provider
export provider

import nimgent/jsonschema
export jsonschema

import std/[json, os, random, strutils]
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

type ObjectResult*[T] = object
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

proc takeObjectValue(resp: ProviderResponse, preferTool: bool): tuple[value: JsonNode, issue: string] =
  if preferTool and resp.toolCalls.len > 0:
    let c = resp.toolCalls[0]
    let bad = invalidToolCall(c)
    if bad.len > 0:
      return (nil, bad)
    return (c.input, "")
  var parsed = extractJson(resp.textContent)
  if parsed.isNil:
    parsed = parsePartialJson(resp.textContent).value
  if not parsed.isNil:
    return (parsed, "")
  if resp.toolCalls.len > 0:
    let c = resp.toolCalls[0]
    let bad = invalidToolCall(c)
    if bad.len > 0:
      return (nil, bad)
    return (c.input, "")
  if resp.finishReason == frMaxTokens:
    return (nil, "response truncated (max tokens)")
  (nil, "no JSON object or array in the model response")

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
  msgs: seq[Message]
  sys: seq[string]
  tools: seq[Tool]
  opts: JsonNode
  useTool: bool

proc startObjectSession(
  provider: Provider, schema: JsonNode, prompt: string,
  messages: seq[Message], system: seq[string], name, description: string,
  options: JsonNode, mode: ObjectMode
): ObjectSession =
  if schema.isNil or schema.kind != JObject:
    raiseObjectError("generateObject requires a JSON Schema object", @[])
  let wire = prepareWireSchema(schema)
  result.msgs = messages
  if result.msgs.len == 0 and prompt.len > 0:
    result.msgs = @[userMessage(prompt)]
  result.sys = system
  result.sys.add objectInstruction(wire, mode)
  let native = provider.nativeObjectOptions(schemaName(name), description, wire)
  if mode == omNative and native.isNil:
    raiseObjectError("provider '" & provider.name &
      "' has no native structured output", @[])
  result.opts = options
  result.useTool = mode == omTool
  if mode in {omAuto, omNative} and not native.isNil:
    result.opts = mergeOptions(result.opts, native)
  elif result.useTool:
    result.tools = @[tool(objectToolName, "Submit the structured result.", wire)]
    let forced = provider.forceToolOptions(objectToolName)
    if not forced.isNil:
      result.opts = mergeOptions(result.opts, forced)

proc acceptObject(resp: ProviderResponse, schema: JsonNode,
                  useTool: bool): tuple[value: JsonNode, issues: seq[string], raw: string] =
  let taken = takeObjectValue(resp, useTool)
  result.value = taken.value
  result.raw = if taken.value.isNil: resp.textContent else: $taken.value
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

proc runObjectLoop(
  provider: Provider, model: string, schema: JsonNode,
  session: var ObjectSession, maxTokens: int, sessionId: string,
  maxRetries, maxRepairs: int, abort: AbortCheck,
  streamFirst: bool, onPartial: PartialObjectCallback,
  onEvent: StreamCallback, wakeFd: cint
): ObjectResult[JsonNode] =
  var lastRaw = ""
  var lastIssues: seq[string] = @[]
  for repair in 0 .. maxRepairs:
    var cancelled = false
    if streamFirst and repair == 0:
      var lastPartial: JsonNode = nil
      var accText = ""
      var accTool = ""
      result.response = streamText(
        provider, model, onEvent = proc (ev: StreamEvent): bool =
          case ev.kind
          of seTextDelta:
            accText.add ev.text
            if not emitPartial(accText, lastPartial, onPartial):
              cancelled = true
              return false
          of seToolCallDelta:
            accTool.add ev.toolArgs
            if accTool.len > 0 and not emitPartial(accTool, lastPartial, onPartial):
              cancelled = true
              return false
          else:
            discard
          if not onEvent.isNil and not onEvent(ev):
            cancelled = true
            return false
          true,
        messages = session.msgs, system = session.sys, tools = session.tools,
        maxTokens = maxTokens, sessionId = sessionId, options = session.opts,
        wakeFd = wakeFd, maxRetries = maxRetries, maxSteps = 1, abort = abort)
    else:
      result.response = generateText(
        provider, model, messages = session.msgs, system = session.sys,
        tools = session.tools, maxTokens = maxTokens, sessionId = sessionId,
        options = session.opts, maxRetries = maxRetries, maxSteps = 1,
        abort = abort)
    result.usage.addUsage(result.response.usage)
    result.repairs = repair
    if cancelled:
      raiseProviderError("aborted", aborted = true)
    let taken = acceptObject(result.response, schema, session.useTool)
    lastRaw = taken.raw
    lastIssues = taken.issues
    if taken.issues.len == 0:
      result.value = taken.value
      return
    session.msgs.add Message(role: roleAssistant, content: result.response.content)
    session.msgs.add userMessage(repairMessage(lastIssues, taken.value, session.useTool))
  let prefix =
    if maxRepairs == 0: "generateObject failed: "
    else: "generateObject failed after " & $maxRepairs & " repair(s): "
  raiseObjectError(prefix & lastIssues.join("; "), lastIssues, lastRaw)

proc generateObject*(
  provider: Provider,
  model: string,
  schema: JsonNode,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
  name = "object",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil
): ObjectResult[JsonNode] =
  ## Schema in, JSON out. Uses native structured output when the provider
  ## has it (`omAuto`), extracts JSON from text or a tool call, validates.
  ## Truncated JSON is closed with `fixJson`. `maxRepairs` (default 0) is
  ## extra model turns after that.
  var session = startObjectSession(provider, schema, prompt, messages, system,
    name, description, options, mode)
  runObjectLoop(provider, model, schema, session, maxTokens, sessionId,
    maxRetries, maxRepairs, abort, false, nil, nil, -1)

proc streamObject*(
  provider: Provider,
  model: string,
  schema: JsonNode,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
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
): ObjectResult[JsonNode] =
  ## Like `generateObject`, but the first attempt streams. `onPartial` gets
  ## the repaired JSON tree whenever it changes (not schema-valid). Schema
  ## check and optional model repairs run after the stream ends.
  var session = startObjectSession(provider, schema, prompt, messages, system,
    name, description, options, mode)
  runObjectLoop(provider, model, schema, session, maxTokens, sessionId,
    maxRetries, maxRepairs, abort, true, onPartial, onEvent, wakeFd)

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

proc generateObject*[T](
  provider: Provider,
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
  name = "",
  description = "",
  maxTokens = 0,
  sessionId = "",
  options: JsonNode = nil,
  maxRetries = 2,
  maxRepairs = 0,
  mode = omAuto,
  abort: AbortCheck = nil
): ObjectResult[T] =
  ## `generateObject` with `jsonSchema(T)`, then `toObject`.
  when T is JsonNode:
    {.error: "use generateObject(..., schema=) for JsonNode; not generateObject[JsonNode]".}
  let nm = if name.len > 0: name else: $T
  toObject[T](generateObject(
    provider, model, jsonSchema(T), prompt, messages, system, nm, description,
    maxTokens, sessionId, options, maxRetries, maxRepairs, mode, abort))

proc streamObject*[T](
  provider: Provider,
  model: string,
  prompt = "",
  messages: seq[Message] = @[],
  system: seq[string] = @[],
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
): ObjectResult[T] =
  when T is JsonNode:
    {.error: "use streamObject(..., schema=) for JsonNode; not streamObject[JsonNode]".}
  let nm = if name.len > 0: name else: $T
  toObject[T](streamObject(
    provider, model, jsonSchema(T), prompt, messages, system, nm, description,
    maxTokens, sessionId, options, wakeFd, maxRetries, maxRepairs, mode, abort,
    onPartial, onEvent))
