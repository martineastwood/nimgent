## Internal representation of messages, tools and provider traffic.
##
## Provider adapters translate between this representation and their own wire
## format. The representation is deliberately close to a superset of what the
## supported APIs need, so provider-specific features stay reachable through
## `ProviderRequest.options`.

import std/[asyncdispatch, base64, json, os, strutils]

type
  Role* = enum
    roleUser = "user"
    roleAssistant = "assistant"

  ContentKind* = enum
    ckText
    ckToolUse
    ckToolResult
    ckThinking
    ckImage
    ckFile
    ckSource

  ImageContent* = object
    mimeType*: string
    data*: string  ## base64, no data: prefix
    path*: string  ## optional caller-owned source/reference path

  FileContent* = object
    mimeType*: string
    data*: string  ## base64, no data: prefix
    path*: string
    filename*: string

  SourceContent* = object
    url*: string
    title*: string
    id*: string
    citedText*: string
    raw*: JsonNode  ## provider citation object; required for Anthropic replay

  ContentBlock* = object
    googlePart*: JsonNode ## Original native Gemini part, retained for signed replay.
    ## Non-empty when the provider already ran this tool use/result
    ## (`web_search`, …). `toolCalls` skips these; generateText must not
    ## execute them. Value is the logical tool name, used to replay results.
    hosted*: string
    case kind*: ContentKind
    of ckText:
      text*: string
    of ckThinking:
      thinking*: string
      signature*: string
    of ckToolUse:
      id*: string
      name*: string
      input*: JsonNode
      parseError*: string  ## set when the provider got invalid tool JSON; do not execute
      thoughtSignature*: string ## Google tool-call signature, replayed unchanged
    of ckToolResult:
      toolUseId*: string
      output*: string
      isError*: bool
      ## Structured value returned by a local tool. `output` remains the
      ## provider-facing rendering of this value.
      value*: JsonNode
      ## Structured local tool failure, when `isError` is true.
      errorCode*: string
      errorMessage*: string
      errorDetails*: JsonNode
      errorRetryable*: bool
      images*: seq[ImageContent]
    of ckImage:
      mimeType*: string
      data*: string
      path*: string
    of ckFile:
      file*: FileContent
    of ckSource:
      source*: SourceContent

  Message* = object
    role*: Role
    content*: seq[ContentBlock]

  ToolDefinition* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    ## Non-empty: provider-hosted tool (`web_search`, …). No execute.
    hosted*: string
    hostedOptions*: JsonNode

  ToolChoiceKind* = enum
    tckAuto
    tckRequired
    tckNone
    tckSpecific

  ToolChoice* = object
    case kind*: ToolChoiceKind
    of tckSpecific:
      name*: string
    else:
      discard

  FinishReason* = enum
    frUnknown
    frEndTurn
    frToolUse
    frMaxTokens
    frStop
    frStepLimit

  ProviderCapability* = enum
    pcStreaming
    pcTools
    pcStructuredOutput
    pcImages
    pcFiles
    pcHostedTools
    pcEmbeddings

  Usage* = object
    inputTokens*: int
    outputTokens*: int
    cacheReadTokens*: int
    cacheWriteTokens*: int
    ## True when the provider reports cache statistics at all; without this we
    ## cannot distinguish "zero cached" from "not reported".
    cacheReported*: bool

  ProviderRequest* = object
    model*: string
    sessionId*: string
    ## Optional execution identity and metadata for local tool context.
    turnId*: string
    metadata*: JsonNode
    system*: seq[string]
    messages*: seq[Message]
    tools*: seq[ToolDefinition]
    ## Provider-neutral tool selection. The default is automatic selection.
    toolChoice*: ToolChoice
    maxTokens*: int
    ## Escape hatch for provider-specific knobs (thinking, routing, TTL, ...).
    options*: JsonNode
    ## When >= 0, emit seWake when this fd becomes readable during streaming.
    ## Default -1 means no side-channel wake (stdin is 0 when used).
    wakeFd*: cint = -1

  StepResult* = object
    model*: string
    content*: seq[ContentBlock]
    usage*: Usage
    finishReason*: FinishReason
    ## Results produced locally for this step, in tool-call order.
    toolResults*: seq[ContentBlock]

  ProviderResponse* = object
    ## Provider-reported model, which may differ from the requested alias after
    ## routing or fallback. It is more trustworthy than asking the model.
    model*: string
    content*: seq[ContentBlock]
    usage*: Usage
    ## Usage across every model call in `steps`. For a single call this equals usage.
    totalUsage*: Usage
    finishReason*: FinishReason
    ## Request ID returned by the provider, when available.
    requestId*: string
    ## Every model call made by the high-level tool loop.
    steps*: seq[StepResult]
  ProviderError* = object of CatchableError
    ## Raised for transport and API errors. `overflow` marks the specific case
    ## of exceeding the context window, which the agent can recover from.
    overflow*: bool
    retryable*: bool   ## 429 / 5xx / transport; generateText may retry
    aborted*: bool     ## caller abort() returned true
    status*: int       ## HTTP status, or 0 when there was no response
    retryAfterMs*: int ## from Retry-After; 0 if the server did not send one
    requestId*: string ## Provider request ID, when the server returned one.

  ObjectIssue* = object
    ## Best-effort JSON path and diagnostic message for one validation issue.
    path*: string
    message*: string

  ObjectError* = object of ProviderError
    ## generateObject could not produce a value that matches the schema.
    issueDetails*: seq[ObjectIssue]
    raw*: string

  CancelledError* = object of ProviderError

  AbortCheck* = proc (): bool {.closure.}
    ## Return true to cancel. Checked before each attempt and tool call.

  ToolContext* = object
    ## Per-invocation state supplied to context-aware tool handlers.
    callId*: string
    sessionId*: string
    turnId*: string
    abort*: AbortCheck
    metadata*: JsonNode

  ToolError* = object
    ## Machine-readable failure produced by a local tool.
    code*: string
    message*: string
    details*: JsonNode
    retryable*: bool

  ToolResult* = object
    ## Structured result produced by a local tool. `output` is the text sent
    ## back to the model; `value` is retained for application inspection.
    value*: JsonNode
    output*: string
    isError*: bool
    error*: ToolError
    images*: seq[ImageContent]

  Tool* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    ## When set, generateText/streamText can run the tool and continue (maxSteps).
    execute*: proc (context: ToolContext,
                    input: JsonNode): ToolResult {.closure.}
    executeAsync*: proc (context: ToolContext,
                         input: JsonNode): Future[ToolResult] {.closure.}
    ## Overlap execute when every runnable tool in the batch sets this and the
    ## program is compiled with `--threads:on`. execute must be safe to run
    ## concurrently (no shared mutation). niminal never sets it.
    parallel*: bool
    hosted*: string
    hostedOptions*: JsonNode

  Provider* = ref object of RootObj
    name*: string
    capabilities*: set[ProviderCapability]

  LanguageModel* = object
    provider*: Provider
    id*: string

  EmbeddingModel* = object
    provider*: Provider
    id*: string

  EmbeddingUsage* = object
    tokens*: int

  AgentEventKind* = enum
    aeRunStart
    aeStepStart
    aeTextDelta
    aeThinkingDelta
    aeToolCall
    aeToolApprovalRequired
    aeToolResult
    aeStepFinish
    aeRunFinish
    aeError

  ToolApprovalMode* = enum
    tamAllow
    tamAsk
    tamDeny

  ToolApproval* = object
    mode*: ToolApprovalMode
    reason*: string

  ToolApprovalDecision* = enum
    tadApprove
    tadDeny

  ToolApprovalRequest* = ref object
    callId*: string
    toolName*: string
    input*: JsonNode
    reason*: string
    decision: Future[ToolApprovalDecision]
    resolved: bool

  AgentEvent* = object
    runId*: string
    sessionId*: string
    turnId*: string
    step*: int
    case kind*: AgentEventKind
    of aeRunStart:
      prompt*: string
      model*: string
    of aeStepStart:
      stepModel*: string
    of aeTextDelta, aeThinkingDelta:
      text*: string
    of aeToolCall:
      call*: ContentBlock
    of aeToolApprovalRequired:
      approval*: ToolApprovalRequest
    of aeToolResult:
      toolResult*: ContentBlock
      durationMs*: int
    of aeStepFinish:
      stepResult*: StepResult
    of aeRunFinish:
      response*: ProviderResponse
    of aeError:
      error*: ref CatchableError

  AgentEventCallback* = proc (event: AgentEvent): bool {.closure.}

  ToolApprovalPolicy* = proc (step: int, call: ContentBlock,
                              tool: Tool): ToolApproval {.closure.}

  EmbeddingRequest* = object
    model*: string
    values*: seq[string]
    ## Escape hatch for provider-specific embedding settings (dimensions, user, ...).
    options*: JsonNode

  EmbeddingResponse* = object
    model*: string
    embeddings*: seq[seq[float]]
    usage*: EmbeddingUsage
    ## Request ID returned by the provider, when available.
    requestId*: string

  StreamEventKind* = enum
    seTextDelta
    seThinkingDelta
    seToolCallDelta
    seFinished
    seWake          ## Input or periodic cancellation check while waiting on the provider

  StreamEvent* = object
    case kind*: StreamEventKind
    of seTextDelta, seThinkingDelta:
      text*: string
    of seToolCallDelta:
      toolCallId*: string
      toolName*: string
      toolArgs*: string  ## argument fragment; empty when only the name arrived
    of seFinished, seWake:
      discard

  ThinkingWire* = enum
    twEffort     ## reasoning.effort / thinking.budget_tokens
    twToggle     ## reasoning.enabled / reasoning.effort=medium / thinking high
    twMaxTokens  ## reasoning.max_tokens / reasoning.effort / thinking.budget_tokens

  StreamCallback* = proc (ev: StreamEvent): bool {.closure.}
    ## Return false to cancel the stream early.

proc newToolApprovalRequest*(call: ContentBlock,
                             reason: string): ToolApprovalRequest =
  ToolApprovalRequest(callId: call.id, toolName: call.name,
    input: if call.input.isNil: newJNull() else: copy(call.input),
    reason: reason, decision: newFuture[ToolApprovalDecision]("toolApproval"),
    resolved: false)

proc approve*(request: ToolApprovalRequest) =
  if request.isNil or request.resolved: return
  request.resolved = true
  request.decision.complete(tadApprove)

proc deny*(request: ToolApprovalRequest) =
  if request.isNil or request.resolved: return
  request.resolved = true
  request.decision.complete(tadDeny)

proc waitDecision*(request: ToolApprovalRequest): Future[ToolApprovalDecision] =
  if request.isNil:
    return newFuture[ToolApprovalDecision]("nilToolApproval")
  request.decision

proc raiseProviderError*(msg: string, overflow = false, retryable = false,
                         aborted = false, status = 0, retryAfterMs = 0,
                         requestId = "")

proc addUsage*(a: var Usage, b: Usage) =
  a.inputTokens += b.inputTokens
  a.outputTokens += b.outputTokens
  a.cacheReadTokens += b.cacheReadTokens
  a.cacheWriteTokens += b.cacheWriteTokens
  a.cacheReported = a.cacheReported or b.cacheReported

proc model*(provider: Provider, id: string): LanguageModel =
  if provider.isNil: raise newException(ProviderError, "provider must not be nil")
  if id.len == 0: raise newException(ProviderError, "model id must not be empty")
  LanguageModel(provider: provider, id: id)

proc embeddingModel*(provider: Provider, id: string): EmbeddingModel =
  if provider.isNil: raise newException(ProviderError, "provider must not be nil")
  if id.len == 0: raise newException(ProviderError, "model id must not be empty")
  EmbeddingModel(provider: provider, id: id)

method embedAsync*(p: Provider, request: EmbeddingRequest): Future[EmbeddingResponse]
    {.base, async.} =
  raise newException(CatchableError, "provider does not implement embeddings")

proc embed*(p: Provider, request: EmbeddingRequest): EmbeddingResponse =
  waitFor p.embedAsync(request)

proc supports*(provider: Provider, capability: ProviderCapability): bool =
  not provider.isNil and capability in provider.capabilities

proc contextTokens*(u: Usage): int =
  ## Tokens occupying the context window on the last request.
  ## OpenAI/OpenRouter prompt_tokens already includes cached tokens; Anthropic
  ## splits them (input + cache_read + cache_write).
  if u.cacheReported:
    let cached = u.cacheReadTokens + u.cacheWriteTokens
    if cached > 0 and u.inputTokens < cached:
      return u.inputTokens + cached
  u.inputTokens

proc formatUsageLabels*(usage: Usage): seq[string] =
  ## Plain usage fragments shared by console, TUI, and status bar.
  if usage.inputTokens == 0 and usage.outputTokens == 0:
    return
  result.add "↑" & $usage.inputTokens
  result.add "↓" & $usage.outputTokens
  if usage.cacheReported:
    result.add "R" & $usage.cacheReadTokens
    if usage.cacheWriteTokens > 0:
      result.add "W" & $usage.cacheWriteTokens
    let denom = contextTokens(usage)
    if denom > 0:
      let pct = usage.cacheReadTokens * 100 / denom
      result.add "CH" & pct.formatFloat(ffDecimal, 1) & "%"

method generateAsync*(p: Provider, request: ProviderRequest): Future[ProviderResponse]
    {.base, async.} =
  raise newException(CatchableError, "provider does not implement generate")

proc generate*(p: Provider, request: ProviderRequest): ProviderResponse =
  waitFor p.generateAsync(request)

const imageOmitted* = "[image omitted: model does not accept images]"

proc text*(s: string): ContentBlock =
  ContentBlock(kind: ckText, text: s)

proc image*(mimeType, data: string, path = ""): ContentBlock =
  ContentBlock(kind: ckImage, mimeType: mimeType, data: data, path: path)

proc image*(img: ImageContent): ContentBlock =
  image(img.mimeType, img.data, img.path)

proc imageFromPath*(path, mimeType: string): ContentBlock =
  ## Read and base64-encode an image. `path` is retained as source metadata.
  image(mimeType, encode(readFile(path)), path)

proc toImage*(part: ContentBlock): ImageContent =
  ImageContent(mimeType: part.mimeType, data: part.data, path: part.path)

proc file*(mimeType, data: string, path = "", filename = ""): ContentBlock =
  ContentBlock(kind: ckFile, file: FileContent(mimeType: mimeType, data: data,
    path: path, filename: filename))

proc file*(f: FileContent): ContentBlock =
  ContentBlock(kind: ckFile, file: f)

proc fileFromPath*(path, mimeType: string, filename = ""): ContentBlock =
  ## Read and base64-encode a file. Defaults filename to the path's basename.
  file(mimeType, encode(readFile(path)), path,
    if filename.len > 0: filename else: extractFilename(path))

proc source*(url: string; title = ""; id = ""; citedText = "";
             raw: JsonNode = nil): ContentBlock =
  ContentBlock(kind: ckSource, source: SourceContent(url: url, title: title,
    id: id, citedText: citedText, raw: raw))

proc fileLabel*(f: FileContent): string =
  if f.filename.len > 0: return f.filename
  if f.path.len > 0:
    let i = max(f.path.rfind('/'), f.path.rfind('\\'))
    return if i >= 0: f.path[i + 1 .. ^1] else: f.path
  "file"

proc fileDataUri*(f: FileContent): string =
  "data:" & f.mimeType & ";base64," & f.data

proc takeFollowingSources*(content: openArray[ContentBlock],
                           i: var int): seq[ContentBlock] =
  ## Consume ckSource blocks after `content[i]`.
  while i + 1 < content.len and content[i + 1].kind == ckSource:
    inc i
    result.add content[i]

proc ephemeralCache(): JsonNode =
  %*{"type": "ephemeral"}

proc markLastArrayCache(node: JsonNode) =
  if node.isNil or node.kind != JArray or node.len == 0: return
  node[node.len - 1]["cache_control"] = ephemeralCache()

proc markContentCache(msg: JsonNode): bool =
  ## Cache breakpoint on the last content part. True if one was set.
  if msg.isNil or msg.kind != JObject: return false
  if msg.getOrDefault("role").getStr == "tool":
    msg["cache_control"] = ephemeralCache()
    return true
  if "content" notin msg:
    return false
  let c = msg["content"]
  if c.kind == JString:
    var part = %*{"type": "text", "text": c.getStr}
    part["cache_control"] = ephemeralCache()
    var arr = newJArray()
    arr.add part
    msg["content"] = arr
    return true
  if c.kind == JArray and c.len > 0:
    c[c.len - 1]["cache_control"] = ephemeralCache()
    return true
  false

proc applyCacheBreakpoints*(body: JsonNode) =
  ## Last tool, last system block, last message content — Anthropic's 4-breakpoint budget.
  if body.isNil or body.kind != JObject: return
  if "tools" in body:
    markLastArrayCache(body["tools"])
  if "system" in body:
    markLastArrayCache(body["system"])
  if "messages" notin body or body["messages"].kind != JArray: return
  let msgs = body["messages"]
  for i in countdown(msgs.len - 1, 0):
    if msgs[i].kind == JObject and msgs[i].getOrDefault("role").getStr == "system":
      discard markContentCache(msgs[i])
      break
  for i in countdown(msgs.len - 1, 0):
    if msgs[i].kind == JObject and markContentCache(msgs[i]):
      break

proc parseToolArguments*(raw: string): tuple[input: JsonNode, parseError: string] =
  ## Empty args → `{}`. Invalid JSON is a tool error, not a provider failure.
  if raw.len == 0:
    return (newJObject(), "")
  try:
    (parseJson(raw), "")
  except CatchableError as e:
    (newJObject(), "invalid tool arguments: " & e.msg)

proc toolUse*(id, name: string, input: JsonNode, parseError = "",
              hosted = ""): ContentBlock =
  ContentBlock(kind: ckToolUse, id: id, name: name, input: input,
    parseError: parseError, hosted: hosted)

proc toolUseFromArgs*(id, name, raw: string): ContentBlock =
  let parsed = parseToolArguments(raw)
  toolUse(id, name, parsed.input, parsed.parseError)

proc toolResult*(toolUseId, output: string, isError = false,
                 images: seq[ImageContent] = @[], hosted = "",
                 value: JsonNode = nil, errorCode = "", errorMessage = "",
                 errorDetails: JsonNode = nil, errorRetryable = false): ContentBlock =
  ContentBlock(kind: ckToolResult, toolUseId: toolUseId, output: output,
    isError: isError, value: value, errorCode: errorCode,
    errorMessage: errorMessage,
    errorDetails: errorDetails, errorRetryable: errorRetryable,
    images: images, hosted: hosted)

proc userMessage*(s: string): Message =
  Message(role: roleUser, content: @[text(s)])

proc userMessage*(parts: seq[ContentBlock]): Message =
  Message(role: roleUser, content: parts)

proc assistantMessage*(s: string): Message =
  Message(role: roleAssistant, content: @[text(s)])

proc assistantMessage*(parts: seq[ContentBlock]): Message =
  Message(role: roleAssistant, content: parts)

proc dropImages*(messages: seq[Message]): seq[Message] =
  ## Replace image blocks with a text note. Session storage is unchanged.
  for msg in messages:
    var parts: seq[ContentBlock] = @[]
    for p in msg.content:
      case p.kind
      of ckImage:
        parts.add text(imageOmitted)
      of ckToolResult:
        if p.images.len > 0:
          var q = p
          q.images = @[]
          if q.output.len > 0: q.output.add "\n"
          q.output.add imageOmitted
          parts.add q
        else:
          parts.add p
      else:
        parts.add p
    result.add Message(role: msg.role, content: parts)

proc toolCalls*(r: ProviderResponse): seq[ContentBlock] =
  for b in r.content:
    if b.kind == ckToolUse and b.hosted.len == 0:
      result.add b

proc toolCalls*(s: StepResult): seq[ContentBlock] =
  for b in s.content:
    if b.kind == ckToolUse and b.hosted.len == 0:
      result.add b

proc textContent*(blocks: openArray[ContentBlock]): string =
  for b in blocks:
    if b.kind == ckText:
      if result.len > 0: result.add "\n"
      result.add b.text

proc text*(r: ProviderResponse): string =
  textContent(r.content)

proc text*(s: StepResult): string =
  textContent(s.content)

proc mergeRequestOptions*(body, options: JsonNode) =
  if options.isNil or options.kind == JNull: return
  if options.kind != JObject:
    raise newException(ProviderError, "options must be a JSON object")
  for key, value in options:
    body[key] = value

method generateStreamAsync*(p: Provider, request: ProviderRequest,
                            onEvent: StreamCallback): Future[ProviderResponse]
    {.base, async.} =
  ## Default: non-streaming fallback that emits thinking, text, then tool calls.
  result = await p.generateAsync(request)
  for b in result.content:
    case b.kind
    of ckThinking:
      if b.thinking.len > 0:
        if not onEvent(StreamEvent(kind: seThinkingDelta, text: b.thinking)):
          return
    of ckText:
      if b.text.len > 0:
        if not onEvent(StreamEvent(kind: seTextDelta, text: b.text)):
          return
    of ckToolUse:
      if b.hosted.len == 0:
        let args = if b.input.isNil: "" else: $b.input
        if not onEvent(StreamEvent(kind: seToolCallDelta, toolCallId: b.id,
            toolName: b.name, toolArgs: args)):
          return
    else:
      discard
  discard onEvent(StreamEvent(kind: seFinished))

proc generateStream*(p: Provider, request: ProviderRequest,
                     onEvent: StreamCallback): ProviderResponse =
  waitFor p.generateStreamAsync(request, onEvent)

proc isContextOverflow*(detail: string): bool =
  ## True for known context-window overflow messages (not generic "token" noise).
  let lower = detail.toLowerAscii
  "context_length_exceeded" in lower or
  "context length" in lower or
  "context window" in lower or
  "maximum context" in lower or
  "prompt is too long" in lower or
  "too many tokens" in lower or
  "token limit" in lower or
  "exceeds the model" in lower or
  "exceeds model" in lower or
  "max input tokens" in lower

proc isRetryableStatus*(code: int): bool =
  code == 429 or code >= 500

const retryAfterCapMs* = 30_000  ## ignore wild Retry-After values

proc parseRetryAfter*(value: string): int =
  ## Milliseconds from a Retry-After header. Integer seconds only; HTTP-date
  ## is ignored (caller falls back to jittered backoff). Capped at 30s.
  let s = value.strip
  if s.len == 0: return 0
  try:
    let secs = parseInt(s)
    if secs <= 0: return 0
    result = min(secs * 1000, retryAfterCapMs)
  except ValueError:
    return 0

proc apiErrorMessage*(raw: string): string =
  ## `error.message` from an OpenAI-family JSON body, including the top-level
  ## array form Google's OpenAI-compatible endpoint returns
  ## (`[{"error": {"message": ...}}]`). Falls back to the raw text.
  var node: JsonNode
  try:
    node = parseJson(raw)
  except CatchableError:
    return raw
  if node.kind == JArray and node.len > 0:
    node = node[0]
  if node.isNil or node.kind != JObject: return raw
  result = node.getOrDefault("error").getOrDefault("message").getStr
  if result.len == 0: result = raw

proc raiseProviderError*(msg: string, overflow = false, retryable = false,
                         aborted = false, status = 0, retryAfterMs = 0,
                         requestId = "") =
  let e = newException(ProviderError, msg)
  e.overflow = overflow
  e.retryable = retryable or isRetryableStatus(status)
  e.aborted = aborted
  e.status = status
  e.retryAfterMs = retryAfterMs
  e.requestId = requestId
  raise e

proc raiseCancelledError*(msg = "aborted") {.noreturn.} =
  let e = newException(CancelledError, msg)
  e.aborted = true
  raise e

proc raiseObjectError*(msg: string, issues: seq[string], raw = "") =
  let e = newException(ObjectError, msg)
  for issue in issues:
    let sep = issue.find(": ")
    if sep > 0:
      e.issueDetails.add ObjectIssue(path: issue[0 ..< sep],
        message: issue[sep + 2 .. ^1])
    else:
      e.issueDetails.add ObjectIssue(path: "$", message: issue)
  e.raw = raw
  raise e

method nativeObjectOptions*(p: Provider, name, description: string,
                            schema: JsonNode): JsonNode {.base.} =
  ## Provider-body knobs for native structured output. nil means none.
  nil

method nativeObjectSchemaIssues*(p: Provider, schema: JsonNode): seq[string]
    {.base.} =
  ## Provider-specific native-schema restrictions. Empty means compatible.
  @[]

proc rawTool*(name, description: string, inputSchema: JsonNode,
              execute: proc (context: ToolContext,
                             input: JsonNode): ToolResult {.closure.} = nil,
              parallel = false, hosted = "", hostedOptions: JsonNode = nil): Tool =
  ## Escape hatch for runtime-defined schemas.
  Tool(name: name, description: description, inputSchema: inputSchema,
       execute: execute, parallel: parallel, hosted: hosted,
       hostedOptions: hostedOptions)

proc toolChoiceAuto*(): ToolChoice =
  ToolChoice(kind: tckAuto)

proc toolChoiceRequired*(): ToolChoice =
  ToolChoice(kind: tckRequired)

proc toolChoiceNone*(): ToolChoice =
  ToolChoice(kind: tckNone)

proc toolChoiceSpecific*(name: string): ToolChoice =
  ToolChoice(kind: tckSpecific, name: name)

proc validateToolChoice*(choice: ToolChoice,
                         tools: openArray[ToolDefinition]) =
  case choice.kind
  of tckSpecific:
    if choice.name.strip.len == 0:
      raiseProviderError("specific tool choice requires a name")
    var found = false
    for tool in tools:
      if tool.name == choice.name:
        found = true
        break
    if not found:
      raiseProviderError("specific tool choice names an unavailable tool: " &
        choice.name)
  of tckRequired:
    if tools.len == 0:
      raiseProviderError("required tool choice needs at least one tool")
  else:
    discard

proc rawAsyncTool*(name, description: string, inputSchema: JsonNode,
                   execute: proc (context: ToolContext,
                                 input: JsonNode): Future[ToolResult] {.closure.},
                   parallel = false): Tool =
  ## Async escape hatch for runtime-defined schemas.
  Tool(name: name, description: description, inputSchema: inputSchema,
       executeAsync: execute, parallel: parallel)

proc hostedTool*(name: string, options: JsonNode = nil): Tool =
  ## Provider-executed tool (`web_search`, …). OpenAI Responses, Anthropic, native Gemini.
  Tool(name: name, hosted: name, hostedOptions: options)

proc toDefinitions*(tools: openArray[Tool]): seq[ToolDefinition] =
  for t in tools:
    result.add ToolDefinition(name: t.name, description: t.description,
      inputSchema: t.inputSchema, hosted: t.hosted,
      hostedOptions: t.hostedOptions)

proc thinkingBudgetTokens*(level: string): int =
  case level.toLowerAscii
  of "minimal": 1024
  of "low": 2048
  of "medium": 8000
  of "high": 16000
  of "xhigh", "max": 32000
  else: 0

proc thinkingOptions*(provider, level: string, wire = twEffort): JsonNode =
  ## Provider-body knobs for a thinking/reasoning level. Empty or `none` is `{}`.
  ## Catalog snapping (which rungs exist) stays with the caller.
  result = newJObject()
  let p = provider.toLowerAscii
  let lv = level.toLowerAscii
  if lv.len == 0 or lv == "none":
    return
  case wire
  of twEffort:
    case p
    of "openrouter", "openai", "hyper":
      result["reasoning"] = %*{"effort": lv}
    of "google":
      # OpenAI-compatible surface uses the standard top-level reasoning_effort.
      result["reasoning_effort"] = %lv
    of "anthropic":
      let budget = thinkingBudgetTokens(lv)
      if budget > 0:
        result["thinking"] = %*{"type": "enabled", "budget_tokens": budget}
    else:
      discard
  of twToggle:
    case p
    of "openrouter":
      result["reasoning"] = %*{"enabled": true}
    of "openai", "hyper":
      result["reasoning"] = %*{"effort": "medium"}
    of "google":
      result = thinkingOptions(p, "high", twEffort)
    of "anthropic":
      result = thinkingOptions(p, "high", twEffort)
    else:
      discard
  of twMaxTokens:
    case p
    of "openrouter":
      result["reasoning"] = %*{"max_tokens": thinkingBudgetTokens(lv)}
    of "openai", "hyper":
      result["reasoning"] = %*{"effort": lv}
    of "google":
      result = thinkingOptions(p, lv, twEffort)
    of "anthropic":
      result = thinkingOptions(p, lv, twEffort)
    else:
      discard

type
  RequestMapper* = proc (req: ProviderRequest): ProviderRequest {.closure.}
    ## Return a new request. Do not mutate `req` in place: the tool loop and
    ## generateObject repairs reuse one request across turns.
  ResponseMapper* = proc (req: ProviderRequest, resp: var ProviderResponse) {.closure.}

  WrapProvider* = ref object of Provider
    ## Provider middleware: forwards every call to `inner` through optional
    ## request and response hooks (inject defaults, drop images, redact, log).
    inner*: Provider
    mapRequest*: RequestMapper
    mapResponse*: ResponseMapper

proc wrapProvider*(inner: Provider, name = "",
                   mapRequest: RequestMapper = nil,
                   mapResponse: ResponseMapper = nil): WrapProvider =
  ## Wrap `inner` so generate, stream, and generateObject all pass through the
  ## hooks. Capabilities and the structured-output methods forward, so
  ## `supports` stays truthful through the wrapper.
  if inner.isNil:
    raise newException(ProviderError, "provider must not be nil")
  WrapProvider(name: if name.len > 0: name else: inner.name,
    capabilities: inner.capabilities, inner: inner,
    mapRequest: mapRequest, mapResponse: mapResponse)

method generateAsync*(p: WrapProvider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
  let mapped = if p.mapRequest.isNil: request else: p.mapRequest(request)
  result = await p.inner.generateAsync(mapped)
  if not p.mapResponse.isNil: p.mapResponse(mapped, result)

method generateStreamAsync*(p: WrapProvider, request: ProviderRequest,
                            onEvent: StreamCallback): Future[ProviderResponse] {.async.} =
  let mapped = if p.mapRequest.isNil: request else: p.mapRequest(request)
  result = await p.inner.generateStreamAsync(mapped, onEvent)
  if not p.mapResponse.isNil: p.mapResponse(mapped, result)

method embedAsync*(p: WrapProvider,
                   request: EmbeddingRequest): Future[EmbeddingResponse] {.async.} =
  ## Text-generation mappers intentionally do not alter embedding requests.
  return await p.inner.embedAsync(request)

method nativeObjectOptions*(p: WrapProvider, name, description: string,
                            schema: JsonNode): JsonNode =
  p.inner.nativeObjectOptions(name, description, schema)

method nativeObjectSchemaIssues*(p: WrapProvider,
                                 schema: JsonNode): seq[string] =
  p.inner.nativeObjectSchemaIssues(schema)
