## Event-backed conversation state for reusable agents.
##
## A Session owns the transcript and usage for one conversation. Agent remains
## immutable configuration; a session can be used for independent runs and is
## not safe for concurrent mutation from multiple callers.

import std/[asyncdispatch, json, strutils, times]
import nimgent
import nimgent/agent

const sessionSchemaVersion* = 1

type
  SessionEventKind* = enum
    sekUser = "user"
    sekAssistant = "assistant"
    sekToolResult = "tool_result"
    sekTurnStarted = "turn_started"
    sekTurnFinished = "turn_finished"
    sekTurnFailed = "turn_failed"

  ## Provider-neutral append-only session event. Lifecycle events make an
  ## interrupted turn observable without putting incomplete messages into the
  ## model-facing transcript.
  SessionEvent* = object
    turnId*: string
    case kind*: SessionEventKind
    of sekUser, sekAssistant:
      message*: Message
      model*: string
      requestId*: string
      usage*: Usage
      finishReason*: FinishReason
    of sekToolResult:
      toolResults*: seq[ContentBlock]
    of sekTurnStarted:
      prompt*: string
    of sekTurnFinished:
      response*: ProviderResponse
    of sekTurnFailed:
      error*: string
      aborted*: bool

  Session* = ref object
    ## Stable identity passed through to providers that support server sessions.
    id*: string
    ## Agent configuration used for each turn.
    agent*: Agent
    ## Canonical append-only transcript.
    events*: seq[SessionEvent]
    turns*: int
    totalUsage*: Usage
    lastResponse*: ProviderResponse

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
  of ckFile:
    result.file = part.file
  of ckSource:
    if not part.source.raw.isNil:
      result.source.raw = copy(part.source.raw)
  else:
    discard

proc copyMessage(message: Message): Message =
  result = Message(role: message.role)
  for part in message.content:
    result.content.add copyBlock(part)

proc copyBlocks(parts: openArray[ContentBlock]): seq[ContentBlock] =
  for part in parts:
    result.add copyBlock(part)

proc copyStep(step: StepResult): StepResult =
  result = StepResult(model: step.model, usage: step.usage,
    finishReason: step.finishReason)
  for part in step.content:
    result.content.add copyBlock(part)
  for part in step.toolResults:
    result.toolResults.add copyBlock(part)

proc copyResponse(response: ProviderResponse): ProviderResponse =
  result = ProviderResponse(model: response.model, usage: response.usage,
    totalUsage: response.totalUsage, finishReason: response.finishReason,
    requestId: response.requestId)
  for part in response.content:
    result.content.add copyBlock(part)
  for step in response.steps:
    result.steps.add copyStep(step)

proc copyEvent(event: SessionEvent): SessionEvent =
  result = event
  case event.kind
  of sekUser, sekAssistant:
    result.message = copyMessage(event.message)
  of sekToolResult:
    result.toolResults = @[]
    for part in event.toolResults:
      result.toolResults.add copyBlock(part)
  of sekTurnFinished:
    result.response = copyResponse(event.response)
  else:
    discard

proc messagesFromEvents(events: openArray[SessionEvent]): seq[Message] =
  ## Convert completed message events into the provider-neutral request shape.
  for event in events:
    case event.kind
    of sekUser, sekAssistant:
      result.add copyMessage(event.message)
    of sekToolResult:
      if result.len == 0 or result[^1].role != roleUser:
        result.add Message(role: roleUser, content: @[])
      for part in event.toolResults:
        result[^1].content.add copyBlock(part)
    of sekTurnStarted, sekTurnFinished, sekTurnFailed:
      discard

proc rebuildState(session: Session) =
  session.turns = 0
  session.totalUsage = Usage()
  session.lastResponse = ProviderResponse()
  for event in session.events:
    if event.kind == sekTurnFinished:
      inc session.turns
      session.totalUsage.addUsage(event.response.totalUsage)
      session.lastResponse = copyResponse(event.response)

proc appendEvent(session: Session, event: SessionEvent) =
  session.events.add copyEvent(event)
  session.rebuildState()

proc newSessionId(): string =
  $int(epochTime() * 1_000_000)

proc newSession*(agent: Agent, messages: seq[Message] = @[], id = ""): Session =
  ## Create an empty session, or continue from an existing transcript.
  if agent.isNil:
    raiseProviderError("session agent must not be nil")
  result = Session(id: if id.len > 0: id else: newSessionId(), agent: agent)
  for message in messages:
    if message.role == roleUser:
      result.events.add SessionEvent(kind: sekUser, message: copyMessage(message))
    else:
      result.events.add SessionEvent(kind: sekAssistant, message: copyMessage(message))
  result.rebuildState()

proc commit(session: Session, turnId, prompt: string, response: ProviderResponse) =
  session.events.add SessionEvent(kind: sekUser, turnId: turnId,
    message: userMessage(prompt))
  if response.steps.len == 0:
    session.events.add SessionEvent(kind: sekAssistant, turnId: turnId,
      message: assistantMessage(response.content), model: response.model,
      requestId: response.requestId, usage: response.usage,
      finishReason: response.finishReason)
  else:
    for step in response.steps:
      session.events.add SessionEvent(kind: sekAssistant, turnId: turnId,
        message: assistantMessage(step.content), model: step.model,
        usage: step.usage, finishReason: step.finishReason)
      if step.toolResults.len > 0:
        session.events.add SessionEvent(kind: sekToolResult, turnId: turnId,
          toolResults: copyBlocks(step.toolResults))
  session.events.add SessionEvent(kind: sekTurnFinished, turnId: turnId,
    response: copyResponse(response))
  session.rebuildState()

proc requestMessages(session: Session, prompt: string): seq[Message] =
  result = messagesFromEvents(session.events)
  result.add userMessage(prompt)

proc nextTurnId(session: Session): string =
  session.id & ":turn:" & $(session.events.len + 1)

proc runAsync*(session: Session, prompt: string,
               abort: AbortCheck = nil,
               callbacks = RunCallbacks()): Future[ProviderResponse] {.async.} =
  ## Run one user turn and append its complete model/tool transcript.
  if session.isNil:
    raiseProviderError("session must not be nil")
  if prompt.len == 0:
    raiseProviderError("session prompt must not be empty")
  let turnId = session.nextTurnId
  session.appendEvent SessionEvent(kind: sekTurnStarted, turnId: turnId,
    prompt: prompt)
  try:
    let response = await session.agent.runAsync(
      messages = session.requestMessages(prompt), abort = abort,
      callbacks = callbacks, sessionId = session.id, turnId = turnId)
    session.commit(turnId, prompt, response)
    return response
  except CatchableError as e:
    var aborted = false
    if e of ProviderError:
      aborted = cast[ref ProviderError](e).aborted
    session.appendEvent SessionEvent(kind: sekTurnFailed, turnId: turnId,
      error: e.msg, aborted: aborted)
    raise

proc run*(session: Session, prompt: string,
          abort: AbortCheck = nil,
          callbacks = RunCallbacks()): ProviderResponse =
  ## Blocking convenience wrapper around `runAsync`.
  waitFor session.runAsync(prompt, abort, callbacks)

proc streamAsync*(session: Session, prompt: string, onEvent: StreamCallback,
                  abort: AbortCheck = nil,
                  callbacks = RunCallbacks()): Future[ProviderResponse] {.async.} =
  ## Stream one user turn and append its transcript after successful completion.
  if session.isNil:
    raiseProviderError("session must not be nil")
  if prompt.len == 0:
    raiseProviderError("session prompt must not be empty")
  if onEvent.isNil:
    raiseProviderError("session stream callback must not be nil")
  let turnId = session.nextTurnId
  session.appendEvent SessionEvent(kind: sekTurnStarted, turnId: turnId,
    prompt: prompt)
  try:
    let response = await session.agent.streamAsync("", onEvent,
      messages = session.requestMessages(prompt), abort = abort,
      callbacks = callbacks, sessionId = session.id)
    session.commit(turnId, prompt, response)
    return response
  except CatchableError as e:
    var aborted = false
    if e of ProviderError:
      aborted = cast[ref ProviderError](e).aborted
    session.appendEvent SessionEvent(kind: sekTurnFailed, turnId: turnId,
      error: e.msg, aborted: aborted)
    raise

proc stream*(session: Session, prompt: string, onEvent: StreamCallback,
             abort: AbortCheck = nil,
             callbacks = RunCallbacks()): ProviderResponse =
  ## Blocking convenience wrapper around `streamAsync`.
  waitFor session.streamAsync(prompt, onEvent, abort, callbacks)

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
    raise newException(ValueError, "session content block must be an object")
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
    raise newException(ValueError, "unknown session content block type")
  if "google_part" in node: result.googlePart = copy(node["google_part"])

proc messageJson(message: Message): JsonNode =
  result = %*{"role": $message.role, "content": newJArray()}
  for part in message.content:
    result["content"].add blockJson(part)

proc parseMessage(node: JsonNode): Message =
  if node.isNil or node.kind != JObject or "content" notin node or
      node["content"].kind != JArray:
    raise newException(ValueError, "session message must contain a content array")
  let role = try:
    parseEnum[Role](node.getOrDefault("role").getStr)
  except ValueError:
    raise newException(ValueError, "unknown session message role")
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

proc eventJson(event: SessionEvent): JsonNode =
  result = %*{"type": $event.kind, "turn_id": event.turnId}
  case event.kind
  of sekUser, sekAssistant:
    result["message"] = messageJson(event.message)
    if event.kind == sekAssistant:
      result["model"] = %event.model
      result["request_id"] = %event.requestId
      result["usage"] = usageJson(event.usage)
      result["finish_reason"] = %($event.finishReason)
  of sekToolResult:
    result["tool_results"] = newJArray()
    for part in event.toolResults:
      result["tool_results"].add blockJson(part)
  of sekTurnStarted:
    result["prompt"] = %event.prompt
  of sekTurnFinished:
    result["response"] = responseJson(event.response)
  of sekTurnFailed:
    result["error"] = %event.error
    result["aborted"] = %event.aborted

proc parseEvent(node: JsonNode): SessionEvent =
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "session event must be an object")
  let turnId = node.getOrDefault("turn_id").getStr
  let kind = parseEnum[SessionEventKind](node.getOrDefault("type").getStr)
  case kind
  of sekUser:
    result = SessionEvent(kind: sekUser, turnId: turnId,
      message: parseMessage(node.getOrDefault("message")))
  of sekAssistant:
    result = SessionEvent(kind: sekAssistant, turnId: turnId,
      message: parseMessage(node.getOrDefault("message")),
      model: node.getOrDefault("model").getStr,
      requestId: node.getOrDefault("request_id").getStr,
      usage: parseUsage(node.getOrDefault("usage")),
      finishReason: parseEnum[FinishReason](
        node.getOrDefault("finish_reason").getStr))
  of sekToolResult:
    result = SessionEvent(kind: sekToolResult, turnId: turnId)
    for part in node.getOrDefault("tool_results"):
      result.toolResults.add parseBlock(part)
  of sekTurnStarted:
    result = SessionEvent(kind: sekTurnStarted, turnId: turnId,
      prompt: node.getOrDefault("prompt").getStr)
  of sekTurnFinished:
    result = SessionEvent(kind: sekTurnFinished, turnId: turnId,
      response: parseResponse(node.getOrDefault("response")))
  of sekTurnFailed:
    result = SessionEvent(kind: sekTurnFailed, turnId: turnId,
      error: node.getOrDefault("error").getStr,
      aborted: node.getOrDefault("aborted").getBool)

proc sessionJson*(session: Session): JsonNode =
  ## Serialize the event log. Agent configuration is intentionally excluded.
  if session.isNil:
    raiseProviderError("session must not be nil")
  result = %*{"version": sessionSchemaVersion, "id": session.id,
    "events": newJArray()}
  for event in session.events:
    result["events"].add eventJson(event)

proc sessionJsonString*(session: Session): string =
  $session.sessionJson

proc sessionFromJson*(agent: Agent, node: JsonNode): Session =
  ## Rehydrate a session with a caller-supplied Agent configuration.
  if agent.isNil:
    raiseProviderError("session agent must not be nil")
  if node.isNil or node.kind != JObject:
    raise newException(ValueError, "session JSON must be an object")
  let version = node.getOrDefault("version").getInt
  if version != sessionSchemaVersion:
    raise newException(ValueError, "unsupported session JSON version: " & $version)
  if "events" notin node or node["events"].kind != JArray:
    raise newException(ValueError, "session JSON must contain an events array")
  result = Session(id: node.getOrDefault("id").getStr, agent: agent)
  if result.id.len == 0: result.id = newSessionId()
  for event in node["events"]:
    result.events.add parseEvent(event)
  result.rebuildState()

proc sessionFromJson*(agent: Agent, raw: string): Session =
  sessionFromJson(agent, parseJson(raw))

proc reset*(session: Session) =
  ## Clear the transcript, counters, and last response while retaining the agent.
  if session.isNil:
    raiseProviderError("session must not be nil")
  session.events = @[]
  session.rebuildState()
