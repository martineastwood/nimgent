## Event-backed conversation state for reusable agents.
##
## A Conversation owns the transcript and usage for one interaction. Agent remains
## immutable configuration; a conversation can be used for independent runs and is
## not safe for concurrent mutation from multiple callers.

import std/[asyncdispatch, json, strutils, times]
import nimgent
import nimgent/agent

const conversationSchemaVersion* = 1 ## Current serialized conversation format version.

type
  ConversationEventKind* = enum
    ## Kind of event stored in a conversation transcript.
    cekUser = "user"
    cekAssistant = "assistant"
    cekToolResult = "tool_result"
    cekTurnStarted = "turn_started"
    cekTurnFinished = "turn_finished"
    cekTurnFailed = "turn_failed"

  ## Provider-neutral append-only conversation event. Lifecycle events make an
  ## interrupted turn observable without putting incomplete messages into the
  ## model-facing transcript.
  ConversationEvent* = object
    ## One durable event in a conversation transcript.
    turnId*: string
    case kind*: ConversationEventKind
    of cekUser, cekAssistant:
      message*: Message
      model*: string
      requestId*: string
      usage*: Usage
      finishReason*: FinishReason
    of cekToolResult:
      toolResults*: seq[ContentBlock]
    of cekTurnStarted:
      prompt*: string
    of cekTurnFinished:
      response*: ProviderResponse
    of cekTurnFailed:
      error*: string
      aborted*: bool

  Conversation* = ref object
    ## Stable identity passed through to providers that support server sessions.
    id*: string
    ## Agent configuration used for each turn.
    agent*: Agent
    ## Most recent messages sent to the model per turn; 0 sends the whole
    ## transcript. Counted in messages, not turns: a turn with tool calls uses
    ## several. The event log always keeps every turn.
    historyLimit*: int
    ## Canonical append-only transcript.
    events*: seq[ConversationEvent]
    turns*: int
    totalUsage*: Usage
    lastResponse*: ProviderResponse
    ## Highest turn number issued. Kept monotonic so turn ids stay unique when
    ## a caller replaces the transcript.
    turnSeq: int

proc copyBlock(part: ContentBlock): ContentBlock =
  result = part
  if not part.googlePart.isNil:
    result.googlePart = copy(part.googlePart)
  case part.kind
  of ckToolUse:
    if not part.input.isNil: result.input = copy(part.input)
  of ckToolResult:
    if not part.value.isNil: result.value = copy(part.value)
    if not part.errorDetails.isNil: result.errorDetails = copy(part.errorDetails)
    result.images = @[]
    for image in part.images:
      result.images.add image
  of ckSource:
    if not part.source.raw.isNil:
      result.source.raw = copy(part.source.raw)
  else:
    discard

proc copyBlocks(parts: openArray[ContentBlock]): seq[ContentBlock] =
  for part in parts:
    result.add copyBlock(part)

proc copyMessage(message: Message): Message =
  Message(role: message.role, content: copyBlocks(message.content))

proc copyStep(step: StepResult): StepResult =
  result = StepResult(model: step.model, usage: step.usage,
    finishReason: step.finishReason, content: copyBlocks(step.content),
    toolResults: copyBlocks(step.toolResults))

proc copyResponse(response: ProviderResponse): ProviderResponse =
  result = ProviderResponse(model: response.model, usage: response.usage,
    totalUsage: response.totalUsage, finishReason: response.finishReason,
    requestId: response.requestId, content: copyBlocks(response.content))
  for step in response.steps:
    result.steps.add copyStep(step)

proc copyEvent(event: ConversationEvent): ConversationEvent =
  result = event
  case event.kind
  of cekUser, cekAssistant:
    result.message = copyMessage(event.message)
  of cekToolResult:
    result.toolResults = copyBlocks(event.toolResults)
  of cekTurnFinished:
    result.response = copyResponse(event.response)
  else:
    discard

proc messages*(events: openArray[ConversationEvent]): seq[Message] =
  ## Convert completed message events into the provider-neutral request shape.
  ## Pass any slice of `Conversation.events` to read the part a caller wants to
  ## summarize, drop, or rewrite.
  for event in events:
    case event.kind
    of cekUser, cekAssistant:
      result.add copyMessage(event.message)
    of cekToolResult:
      if result.len == 0 or result[^1].role != roleUser:
        result.add Message(role: roleUser, content: @[])
      result[^1].content.add copyBlocks(event.toolResults)
    of cekTurnStarted, cekTurnFinished, cekTurnFailed:
      discard

proc rebuildState(conversation: Conversation) =
  conversation.turns = 0
  conversation.totalUsage = Usage()
  conversation.lastResponse = ProviderResponse()
  for event in conversation.events:
    if event.kind == cekTurnFinished:
      inc conversation.turns
      conversation.totalUsage.addUsage(event.response.totalUsage)
      conversation.lastResponse = copyResponse(event.response)

proc appendEvent(conversation: Conversation, event: ConversationEvent) =
  conversation.events.add copyEvent(event)
  conversation.rebuildState()

proc newConversationId(): string =
  $int(epochTime() * 1_000_000)

proc newConversation*(agent: Agent, messages: seq[Message] = @[], id = "",
                 historyLimit = 0): Conversation =
  ## Create an empty conversation, or continue from an existing transcript.
  if agent.isNil:
    raiseProviderError("conversation agent must not be nil")
  if historyLimit < 0:
    raiseProviderError("conversation historyLimit must be at least 0")
  result = Conversation(id: if id.len > 0: id else: newConversationId(), agent: agent,
    historyLimit: historyLimit)
  for message in messages:
    if message.role == roleUser:
      result.events.add ConversationEvent(kind: cekUser, message: copyMessage(message))
    else:
      result.events.add ConversationEvent(kind: cekAssistant, message: copyMessage(message))
  result.rebuildState()

proc commit(conversation: Conversation, turnId, prompt: string, response: ProviderResponse) =
  conversation.events.add ConversationEvent(kind: cekUser, turnId: turnId,
    message: userMessage(prompt))
  if response.steps.len == 0:
    conversation.events.add ConversationEvent(kind: cekAssistant, turnId: turnId,
      message: assistantMessage(response.content), model: response.model,
      requestId: response.requestId, usage: response.usage,
      finishReason: response.finishReason)
  else:
    for step in response.steps:
      conversation.events.add ConversationEvent(kind: cekAssistant, turnId: turnId,
        message: assistantMessage(step.content), model: step.model,
        usage: step.usage, finishReason: step.finishReason)
      if step.toolResults.len > 0:
        conversation.events.add ConversationEvent(kind: cekToolResult, turnId: turnId,
          toolResults: copyBlocks(step.toolResults))
  conversation.events.add ConversationEvent(kind: cekTurnFinished, turnId: turnId,
    response: copyResponse(response))
  conversation.rebuildState()

proc messages*(conversation: Conversation): seq[Message] =
  ## Model-facing view of the transcript currently in the conversation.
  messages(conversation.events)

proc isTurnStart(message: Message): bool =
  ## A window may only start at a plain user message. One that carries tool
  ## results would reach the model without the call that produced it.
  if message.role != roleUser or message.content.len == 0:
    return false
  for part in message.content:
    if part.kind == ckToolResult:
      return false
  true

proc windowMessages(history: seq[Message], limit: int): seq[Message] =
  ## Keep the most recent messages, widened to the turn they start in so tool
  ## calls keep their results.
  if limit <= 0 or history.len <= limit:
    return history
  var start = history.len - limit
  while start > 0 and not history[start].isTurnStart:
    dec start
  history[start .. ^1]

proc requestMessages(conversation: Conversation, prompt: string): seq[Message] =
  result = windowMessages(messages(conversation.events), conversation.historyLimit)
  result.add userMessage(prompt)

proc nextTurnId(conversation: Conversation): string =
  inc conversation.turnSeq
  conversation.id & ":turn:" & $conversation.turnSeq

proc replaceEvents*(conversation: Conversation, events: openArray[ConversationEvent]) =
  ## Replace the transcript, for example after compacting older turns, and
  ## rebuild `turns`, `totalUsage`, and `lastResponse` from it.
  ##
  ## The caller owns the new transcript: keep it provider-valid by starting at
  ## a user turn and keeping each tool call with its results. Use
  ## `userEventIndices` to find safe cut points.
  if conversation.isNil:
    raiseProviderError("conversation must not be nil")
  conversation.events = @[]
  for event in events:
    conversation.events.add copyEvent(event)
  conversation.rebuildState()

proc userEventIndices*(conversation: Conversation): seq[int] =
  ## Indices of user events, the boundaries a caller can safely cut at when
  ## compacting a transcript.
  if conversation.isNil:
    raiseProviderError("conversation must not be nil")
  for i, event in conversation.events:
    if event.kind == cekUser:
      result.add i

proc validateTurn(conversation: Conversation, prompt: string) =
  if conversation.isNil:
    raiseProviderError("conversation must not be nil")
  if prompt.len == 0:
    raiseProviderError("conversation prompt must not be empty")

proc beginTurn(conversation: Conversation, prompt: string): string =
  conversation.validateTurn(prompt)
  result = conversation.nextTurnId
  conversation.appendEvent ConversationEvent(kind: cekTurnStarted, turnId: result,
    prompt: prompt)

proc recordTurnFailure(conversation: Conversation, turnId: string, error: ref CatchableError) =
  conversation.appendEvent ConversationEvent(kind: cekTurnFailed, turnId: turnId,
    error: error.msg, aborted: error of ProviderError and
      cast[ref ProviderError](error).aborted)

proc runAsync*(conversation: Conversation, prompt: string,
               abort: AbortCheck = nil,
               callbacks = RunCallbacks()): Future[ProviderResponse] {.async.} =
  ## Run one user turn and append its complete model/tool transcript.
  let turnId = conversation.beginTurn(prompt)
  try:
    let response = await conversation.agent.runAsync(
      messages = conversation.requestMessages(prompt), abort = abort,
      callbacks = callbacks, conversationId = conversation.id, turnId = turnId)
    conversation.commit(turnId, prompt, response)
    return response
  except CatchableError as e:
    conversation.recordTurnFailure(turnId, e)
    raise

proc run*(conversation: Conversation, prompt: string,
          abort: AbortCheck = nil,
          callbacks = RunCallbacks()): ProviderResponse =
  ## Blocking convenience wrapper around `runAsync`.
  waitFor conversation.runAsync(prompt, abort, callbacks)

proc streamAsync*(conversation: Conversation, prompt: string, onEvent: StreamCallback,
                  abort: AbortCheck = nil,
                  callbacks = RunCallbacks()): Future[ProviderResponse] {.async.} =
  ## Stream one user turn and append its transcript after successful completion.
  if onEvent.isNil:
    raiseProviderError("conversation stream callback must not be nil")
  let turnId = conversation.beginTurn(prompt)
  try:
    let response = await conversation.agent.streamAsync("", onEvent,
      messages = conversation.requestMessages(prompt), abort = abort,
      callbacks = callbacks, conversationId = conversation.id)
    conversation.commit(turnId, prompt, response)
    return response
  except CatchableError as e:
    conversation.recordTurnFailure(turnId, e)
    raise

proc stream*(conversation: Conversation, prompt: string, onEvent: StreamCallback,
             abort: AbortCheck = nil,
             callbacks = RunCallbacks()): ProviderResponse =
  ## Blocking convenience wrapper around `streamAsync`.
  waitFor conversation.streamAsync(prompt, onEvent, abort, callbacks)

proc runEventsAsync*(conversation: Conversation, prompt: string,
                     abort: AbortCheck = nil,
                     callbacks = RunCallbacks(),
                     onEvent: AgentEventCallback = nil
                     ): Future[ProviderResponse] {.async.} =
  ## Run one conversation turn while receiving lifecycle events.
  let turnId = conversation.beginTurn(prompt)
  try:
    let response = await conversation.agent.runEventsAsync("",
      messages = conversation.requestMessages(prompt), abort = abort,
      callbacks = callbacks, conversationId = conversation.id, turnId = turnId,
      onEvent = onEvent)
    conversation.commit(turnId, prompt, response)
    return response
  except CatchableError as e:
    conversation.recordTurnFailure(turnId, e)
    raise

proc streamAsync*(conversation: Conversation, prompt: string,
                  onEvent: AgentEventCallback,
                  abort: AbortCheck = nil,
                  callbacks = RunCallbacks()): Future[ProviderResponse] {.async.} =
  ## Stream one conversation turn while receiving lifecycle events.
  if onEvent.isNil:
    raiseProviderError("conversation stream callback must not be nil")
  let turnId = conversation.beginTurn(prompt)
  try:
    let response = await conversation.agent.streamAsync("", onEvent,
      messages = conversation.requestMessages(prompt), abort = abort,
      callbacks = callbacks, conversationId = conversation.id, turnId = turnId)
    conversation.commit(turnId, prompt, response)
    return response
  except CatchableError as e:
    conversation.recordTurnFailure(turnId, e)
    raise

proc stream*(conversation: Conversation, prompt: string,
             onEvent: AgentEventCallback,
             abort: AbortCheck = nil,
             callbacks = RunCallbacks()): ProviderResponse =
  ## Synchronously stream one conversation turn with lifecycle events.
  waitFor conversation.streamAsync(prompt, onEvent, abort, callbacks)

proc events*(conversation: Conversation, prompt: string,
             abort: AbortCheck = nil,
             callbacks = RunCallbacks()): AgentEventStream =
  let turnId = conversation.beginTurn(prompt)
  let stream = eventStream(proc (callback: AgentEventCallback): Future[ProviderResponse]
                           {.closure.} =
    conversation.agent.streamAsync("", callback,
      messages = conversation.requestMessages(prompt), abort = abort,
      callbacks = callbacks, conversationId = conversation.id, turnId = turnId))
  ## Persist the transcript independently of the consumer's event-draining
  ## loop, while keeping the stream's result Future authoritative.
  proc commitWhenDone() {.async.} =
    try:
      let response = await stream.result
      conversation.commit(turnId, prompt, response)
    except CatchableError as e:
      conversation.recordTurnFailure(turnId, e)
  asyncCheck commitWhenDone()
  stream

proc usageJson(usage: Usage): JsonNode =
  %*{
    "input_tokens": usage.inputTokens,
    "output_tokens": usage.outputTokens,
    "cache_read_tokens": usage.cacheReadTokens,
    "cache_write_tokens": usage.cacheWriteTokens,
    "cache_reported": usage.cacheReported
  }

proc parseUsage(node: JsonNode): Usage =
  if node.isNil or node.kind != JObject: return
  result.inputTokens = node.getOrDefault("input_tokens").getInt
  result.outputTokens = node.getOrDefault("output_tokens").getInt
  result.cacheReadTokens = node.getOrDefault("cache_read_tokens").getInt
  result.cacheWriteTokens = node.getOrDefault("cache_write_tokens").getInt
  result.cacheReported = node.getOrDefault("cache_reported").getBool

proc imageJson(image: ImageContent): JsonNode =
  result = %*{"mime_type": image.mimeType}
  if image.path.len > 0: result["path"] = %image.path
  if image.data.len > 0: result["data"] = %image.data

proc parseImage(node: JsonNode): ImageContent =
  ImageContent(mimeType: node.getOrDefault("mime_type").getStr,
    data: node.getOrDefault("data").getStr,
    path: node.getOrDefault("path").getStr)

proc blockJson(part: ContentBlock): JsonNode =
  case part.kind
  of ckText:
    result = %*{"type": "text", "text": part.text}
  of ckThinking:
    result = %*{"type": "thinking", "thinking": part.thinking,
      "signature": part.signature}
  of ckToolUse:
    result = %*{"type": "tool_use", "id": part.id, "name": part.name,
      "input": if part.input.isNil: newJNull() else: copy(part.input)}
    if part.parseError.len > 0: result["parse_error"] = %part.parseError
    if part.thoughtSignature.len > 0:
      result["thought_signature"] = %part.thoughtSignature
  of ckToolResult:
    result = %*{"type": "tool_result", "tool_use_id": part.toolUseId,
      "output": part.output, "is_error": part.isError}
    if not part.value.isNil: result["value"] = copy(part.value)
    if part.errorCode.len > 0: result["error_code"] = %part.errorCode
    if part.errorMessage.len > 0: result["error_message"] = %part.errorMessage
    if not part.errorDetails.isNil: result["error_details"] = copy(part.errorDetails)
    if part.errorRetryable: result["error_retryable"] = %true
    if part.images.len > 0:
      result["images"] = newJArray()
      for image in part.images:
        result["images"].add imageJson(image)
  of ckImage:
    result = %*{"type": "image", "mime_type": part.mimeType}
    if part.path.len > 0: result["path"] = %part.path
    if part.data.len > 0: result["data"] = %part.data
  of ckFile:
    result = %*{"type": "file", "mime_type": part.file.mimeType,
      "filename": part.file.filename}
    if part.file.path.len > 0: result["path"] = %part.file.path
    if part.file.data.len > 0: result["data"] = %part.file.data
  of ckSource:
    result = %*{"type": "source", "url": part.source.url,
      "title": part.source.title, "id": part.source.id,
      "cited_text": part.source.citedText}
    if not part.source.raw.isNil: result["raw"] = copy(part.source.raw)
  if not part.googlePart.isNil: result["google_part"] = copy(part.googlePart)
  if part.hosted.len > 0: result["hosted"] = %part.hosted

proc parseBlock(node: JsonNode): ContentBlock =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "conversation content block must be an object")
  case node.getOrDefault("type").getStr
  of "text":
    result = text(node.getOrDefault("text").getStr)
  of "thinking":
    result = ContentBlock(kind: ckThinking,
      thinking: node.getOrDefault("thinking").getStr,
      signature: node.getOrDefault("signature").getStr)
  of "tool_use":
    let input = if "input" in node: copy(node["input"]) else: newJObject()
    result = toolUse(node.getOrDefault("id").getStr,
      node.getOrDefault("name").getStr, input,
      node.getOrDefault("parse_error").getStr,
      node.getOrDefault("hosted").getStr)
    result.thoughtSignature = node.getOrDefault("thought_signature").getStr
  of "tool_result":
    var images: seq[ImageContent]
    if "images" in node and node["images"].kind == JArray:
      for image in node["images"]:
        images.add parseImage(image)
    result = toolResult(node.getOrDefault("tool_use_id").getStr,
      node.getOrDefault("output").getStr,
      node.getOrDefault("is_error").getBool, images,
      node.getOrDefault("hosted").getStr)
    if "value" in node: result.value = copy(node["value"])
    result.errorCode = node.getOrDefault("error_code").getStr
    result.errorMessage = node.getOrDefault("error_message").getStr
    if "error_details" in node: result.errorDetails = copy(node["error_details"])
    result.errorRetryable = node.getOrDefault("error_retryable").getBool
  of "image":
    result = image(node.getOrDefault("mime_type").getStr,
      node.getOrDefault("data").getStr, node.getOrDefault("path").getStr)
  of "file":
    result = file(node.getOrDefault("mime_type").getStr,
      node.getOrDefault("data").getStr, node.getOrDefault("path").getStr,
      node.getOrDefault("filename").getStr)
  of "source":
    let raw = if "raw" in node: copy(node["raw"]) else: nil
    result = source(node.getOrDefault("url").getStr,
      node.getOrDefault("title").getStr, node.getOrDefault("id").getStr,
      node.getOrDefault("cited_text").getStr, raw)
  else:
    raise newException(ValueError, "unknown conversation content block type")
  if "google_part" in node: result.googlePart = copy(node["google_part"])

proc messageJson(message: Message): JsonNode =
  result = %*{"role": $message.role, "content": newJArray()}
  for part in message.content:
    result["content"].add blockJson(part)

proc parseMessage(node: JsonNode): Message =
  if node.isNil or node.kind != JObject or "content" notin node or
      node["content"].kind != JArray:
    raise newException(ValueError, "conversation message must contain a content array")
  let role = try:
    parseEnum[Role](node.getOrDefault("role").getStr)
  except ValueError:
    raise newException(ValueError, "unknown conversation message role")
  result = Message(role: role)
  for part in node["content"]:
    result.content.add parseBlock(part)

proc stepJson(step: StepResult): JsonNode =
  result = %*{"model": step.model, "content": newJArray(),
    "usage": usageJson(step.usage), "finish_reason": $step.finishReason,
    "tool_results": newJArray()}
  for part in step.content:
    result["content"].add blockJson(part)
  for part in step.toolResults:
    result["tool_results"].add blockJson(part)

proc parseStep(node: JsonNode): StepResult =
  result.model = node.getOrDefault("model").getStr
  result.usage = parseUsage(node.getOrDefault("usage"))
  result.finishReason = parseEnum[FinishReason](
    node.getOrDefault("finish_reason").getStr)
  for part in node.getOrDefault("content"):
    result.content.add parseBlock(part)
  for part in node.getOrDefault("tool_results"):
    result.toolResults.add parseBlock(part)

proc responseJson(response: ProviderResponse): JsonNode =
  result = %*{"model": response.model, "content": newJArray(),
    "usage": usageJson(response.usage), "total_usage": usageJson(response.totalUsage),
    "finish_reason": $response.finishReason, "request_id": response.requestId,
    "steps": newJArray()}
  for part in response.content:
    result["content"].add blockJson(part)
  for step in response.steps:
    result["steps"].add stepJson(step)

proc parseResponse(node: JsonNode): ProviderResponse =
  result.model = node.getOrDefault("model").getStr
  result.usage = parseUsage(node.getOrDefault("usage"))
  result.totalUsage = parseUsage(node.getOrDefault("total_usage"))
  result.finishReason = parseEnum[FinishReason](
    node.getOrDefault("finish_reason").getStr)
  result.requestId = node.getOrDefault("request_id").getStr
  for part in node.getOrDefault("content"):
    result.content.add parseBlock(part)
  for step in node.getOrDefault("steps"):
    result.steps.add parseStep(step)

proc eventJson(event: ConversationEvent): JsonNode =
  result = %*{"type": $event.kind, "turn_id": event.turnId}
  case event.kind
  of cekUser, cekAssistant:
    result["message"] = messageJson(event.message)
    if event.kind == cekAssistant:
      result["model"] = %event.model
      result["request_id"] = %event.requestId
      result["usage"] = usageJson(event.usage)
      result["finish_reason"] = %($event.finishReason)
  of cekToolResult:
    result["tool_results"] = newJArray()
    for part in event.toolResults:
      result["tool_results"].add blockJson(part)
  of cekTurnStarted:
    result["prompt"] = %event.prompt
  of cekTurnFinished:
    result["response"] = responseJson(event.response)
  of cekTurnFailed:
    result["error"] = %event.error
    result["aborted"] = %event.aborted

proc parseEvent(node: JsonNode): ConversationEvent =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "conversation event must be an object")
  let turnId = node.getOrDefault("turn_id").getStr
  let kind = parseEnum[ConversationEventKind](node.getOrDefault("type").getStr)
  case kind
  of cekUser:
    result = ConversationEvent(kind: cekUser, turnId: turnId,
      message: parseMessage(node.getOrDefault("message")))
  of cekAssistant:
    result = ConversationEvent(kind: cekAssistant, turnId: turnId,
      message: parseMessage(node.getOrDefault("message")),
      model: node.getOrDefault("model").getStr,
      requestId: node.getOrDefault("request_id").getStr,
      usage: parseUsage(node.getOrDefault("usage")),
      finishReason: parseEnum[FinishReason](
        node.getOrDefault("finish_reason").getStr))
  of cekToolResult:
    result = ConversationEvent(kind: cekToolResult, turnId: turnId)
    for part in node.getOrDefault("tool_results"):
      result.toolResults.add parseBlock(part)
  of cekTurnStarted:
    result = ConversationEvent(kind: cekTurnStarted, turnId: turnId,
      prompt: node.getOrDefault("prompt").getStr)
  of cekTurnFinished:
    result = ConversationEvent(kind: cekTurnFinished, turnId: turnId,
      response: parseResponse(node.getOrDefault("response")))
  of cekTurnFailed:
    result = ConversationEvent(kind: cekTurnFailed, turnId: turnId,
      error: node.getOrDefault("error").getStr,
      aborted: node.getOrDefault("aborted").getBool)

proc conversationJson*(conversation: Conversation): JsonNode =
  ## Serialize the event log. Agent configuration is intentionally excluded.
  if conversation.isNil:
    raiseProviderError("conversation must not be nil")
  result = %*{"version": conversationSchemaVersion, "id": conversation.id,
    "events": newJArray()}
  if conversation.historyLimit > 0:
    result["history_limit"] = %conversation.historyLimit
  for event in conversation.events:
    result["events"].add eventJson(event)

proc conversationJsonString*(conversation: Conversation): string =
  ## Serialize a conversation transcript as a JSON string.
  $conversation.conversationJson

proc conversationFromJson*(agent: Agent, node: JsonNode): Conversation =
  ## Rehydrate a conversation with a caller-supplied Agent configuration.
  if agent.isNil:
    raiseProviderError("conversation agent must not be nil")
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "conversation JSON must be an object")
  let version = node.getOrDefault("version").getInt
  if version != conversationSchemaVersion:
    raise newException(ValueError, "unsupported conversation JSON version: " & $version)
  if "events" notin node or node["events"].kind != JArray:
    raise newException(ValueError, "conversation JSON must contain an events array")
  result = Conversation(id: node.getOrDefault("id").getStr, agent: agent,
    historyLimit: node.getOrDefault("history_limit").getInt)
  if result.id.len == 0: result.id = newConversationId()
  for event in node["events"]:
    result.events.add parseEvent(event)
  result.turnSeq = result.events.len
  result.rebuildState()

proc conversationFromJson*(agent: Agent, raw: string): Conversation =
  ## Rehydrate a conversation from a JSON string and agent configuration.
  conversationFromJson(agent, parseJson(raw))

proc reset*(conversation: Conversation) =
  ## Clear the transcript, counters, and last response while retaining the agent
  ## configuration and history window.
  if conversation.isNil:
    raiseProviderError("conversation must not be nil")
  conversation.events = @[]
  conversation.rebuildState()
