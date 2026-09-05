## OpenRouter adapter using its OpenAI-compatible chat completions API.

import std/[asyncdispatch, asyncstreams, httpclient, json, net, streams, strutils]
import nimgent/provider

type
  OpenRouterProvider* = ref object of Provider
    apiKey: string
    endpoint: string
    timeoutSeconds: int
    siteUrl: string
    siteName: string

proc textParts(message: Message): string =
  for part in message.content:
    if part.kind == ckText:
      if result.len > 0: result.add "\n"
      result.add part.text

proc openAiImagePart*(mimeType, data: string): JsonNode =
  %*{"type": "image_url", "image_url": {
    "url": "data:" & mimeType & ";base64," & data}}

proc flushUserContent(result: var JsonNode, parts: var seq[JsonNode]) =
  if parts.len == 0: return
  var hasImage = false
  var textOnly = ""
  for p in parts:
    if p["type"].getStr == "image_url":
      hasImage = true
    elif p["type"].getStr == "text":
      if textOnly.len > 0: textOnly.add "\n"
      textOnly.add p["text"].getStr
  if hasImage:
    var arr = newJArray()
    for p in parts: arr.add p
    result.add %*{"role": "user", "content": arr}
  else:
    result.add %*{"role": "user", "content": %textOnly}
  parts.setLen(0)

proc addUserMessages(result: var JsonNode, message: Message) =
  var parts: seq[JsonNode] = @[]
  for part in message.content:
    case part.kind
    of ckText:
      parts.add %*{"type": "text", "text": part.text}
    of ckImage:
      parts.add openAiImagePart(part.mimeType, part.data)
    of ckToolResult:
      flushUserContent(result, parts)
      result.add %*{"role": "tool", "tool_call_id": part.toolUseId,
        "content": part.output}
      if part.images.len > 0:
        var imgParts = newJArray()
        imgParts.add %*{"type": "text", "text": "(image from tool)"}
        for img in part.images:
          imgParts.add openAiImagePart(img.mimeType, img.data)
        result.add %*{"role": "user", "content": imgParts}
    else:
      discard
  if parts.len > 0:
    flushUserContent(result, parts)
  elif message.content.len == 0:
    result.add %*{"role": "user", "content": ""}

proc encodeMessage(result: var JsonNode, message: Message) =
  if message.role == roleUser:
    addUserMessages(result, message)
    return

  var encoded = %*{"role": "assistant"}
  let content = textParts(message)
  if content.len > 0:
    encoded["content"] = %content
  else:
    encoded["content"] = newJNull()

  var calls = newJArray()
  for part in message.content:
    if part.kind == ckToolUse:
      calls.add %*{
        "id": part.id,
        "type": "function",
        "function": {
          "name": part.name,
          "arguments": part.input.pretty(0)
        }
      }
  if calls.len > 0:
    encoded["tool_calls"] = calls
  result.add encoded

proc makeOpenRouterProvider*(apiKey, endpoint: string,
                             timeoutSeconds = 300, siteUrl = "",
                             siteName = ""): OpenRouterProvider =
  OpenRouterProvider(name: "openrouter", apiKey: apiKey, endpoint: endpoint,
                     timeoutSeconds: timeoutSeconds, siteUrl: siteUrl,
                     siteName: siteName)

proc buildBody*(request: ProviderRequest, stream: bool): JsonNode =
  result = %*{
    "model": request.model,
    "messages": newJArray()
  }
  if stream:
    result["stream"] = %true
    result["stream_options"] = %*{"include_usage": true}
  if request.sessionId.len > 0:
    result["session_id"] = %request.sessionId
  var messages = newJArray()
  if request.maxTokens > 0:
    result["max_tokens"] = %request.maxTokens
  if request.system.len > 0:
    var parts = newJArray()
    for s in request.system:
      parts.add %*{"type": "text", "text": s}
    messages.add %*{"role": "system", "content": parts}
  for message in request.messages:
    encodeMessage(messages, message)
  result["messages"] = messages
  if request.tools.len > 0:
    result["tools"] = newJArray()
    for tool in request.tools:
      result["tools"].add %*{
        "type": "function",
        "function": {
          "name": tool.name,
          "description": tool.description,
          "parameters": tool.inputSchema
        }
      }
  if not request.options.isNil and request.options.kind != JNull:
    for key, value in request.options:
      result[key] = value
  applyCacheBreakpoints(result)

proc makeHeaders(provider: OpenRouterProvider): HttpHeaders =
  result = {
    "Authorization": "Bearer " & provider.apiKey,
    "Content-Type": "application/json"
  }.newHttpHeaders
  if provider.siteUrl.len > 0:
    result["HTTP-Referer"] = provider.siteUrl
  if provider.siteName.len > 0:
    result["X-Title"] = provider.siteName

proc parseUsage(usage: JsonNode, result: var Usage) =
  result.inputTokens = usage.getOrDefault("prompt_tokens").getInt
  result.outputTokens = usage.getOrDefault("completion_tokens").getInt
  let details = usage.getOrDefault("prompt_tokens_details")
  result.cacheReadTokens = details.getOrDefault("cached_tokens").getInt
  result.cacheWriteTokens = details.getOrDefault("cache_write_tokens").getInt
  result.cacheReported = ("cached_tokens" in details) or
    ("cache_write_tokens" in details)

proc finishFrom(reason: string): FinishReason =
  case reason
  of "tool_calls": frToolUse
  of "stop": frStop
  of "length": frMaxTokens
  else: frUnknown

proc ensureApiKey(provider: OpenRouterProvider) =
  if provider.apiKey.len == 0:
    raiseProviderError("OPENROUTER API key is not configured")

proc newClient(provider: OpenRouterProvider): HttpClient =
  newHttpClient(timeout = provider.timeoutSeconds * 1000,
                sslContext = newContext(verifyMode = CVerifyPeer))

proc raiseApiError(code: int, raw: string) =
  var detail = raw
  try:
    detail = parseJson(raw).getOrDefault("error").getOrDefault("message").getStr
  except CatchableError:
    discard
  raiseProviderError("OpenRouter API error (" & $code & "): " & detail,
    overflow = isContextOverflow(detail), retryable = isRetryableStatus(code),
    status = code)

proc popLine*(buf: var string): tuple[ok: bool, line: string] =
  let nl = buf.find('\n')
  if nl < 0: return (false, "")
  var line = buf[0 ..< nl]
  buf = buf[nl + 1 .. ^1]
  if line.len > 0 and line[^1] == '\r':
    line.setLen(line.len - 1)
  (true, line)

proc drainBodyStream(stream: FutureStream[string]): string =
  while true:
    let (more, chunk) = waitFor stream.read()
    if not more:
      break
    result.add chunk

# ponytail: one in-flight stream; kqueue asserts if unregister runs on an
# fd that was never registered or was already dropped (AssertionDefect,
# not CatchableError). Hold the fd we put in the selector and drop it once.
var wakeWatchFd: cint = -1

proc registerWakeWatch(wakeFd: cint) =
  if wakeWatchFd >= 0: return
  if wakeFd < 0: return
  try:
    register(AsyncFD(wakeFd))
  except CatchableError:
    return
  wakeWatchFd = wakeFd

proc unregisterWakeWatch() =
  if wakeWatchFd < 0: return
  let fd = wakeWatchFd
  wakeWatchFd = -1
  try:
    unregister(AsyncFD(fd))
  except CatchableError:
    discard
  except Defect:
    # kqueue: unregister of a missing fd is AssertionDefect, not CatchableError.
    discard

proc waitWakeOnce(wakeFd: cint): Future[void] =
  result = newFuture[void]("wakeFd")
  registerWakeWatch(wakeFd)
  if wakeWatchFd < 0: return
  let afd = AsyncFD(wakeWatchFd)
  var fut = result
  addRead(afd, proc (s: AsyncFD): bool =
    if not fut.finished:
      fut.complete()
    false)

proc awaitWithWake[T](fut: Future[T], wakeFd: cint,
                      onEvent: StreamCallback): bool =
  ## Block until `fut` completes. False if wakeFd cancel won.
  while not fut.finished:
    if wakeFd < 0:
      discard waitFor fut
      break
    let wake = waitWakeOnce(wakeFd)
    waitFor fut or wake
    if fut.finished:
      if not wake.finished:
        unregisterWakeWatch()
      break
    if not onEvent(StreamEvent(kind: seWake)):
      unregisterWakeWatch()
      return false
  true

proc postChat(provider: OpenRouterProvider, body: JsonNode,
              failPrefix: string): tuple[client: HttpClient, response: Response] =
  provider.ensureApiKey()
  result.client = provider.newClient()
  let headers = provider.makeHeaders()
  try:
    result.response = result.client.request(provider.endpoint, HttpPost, $body, headers)
  except CatchableError as e:
    result.client.close()
    raiseProviderError(failPrefix & e.msg, retryable = true)

method generate*(provider: OpenRouterProvider,
                 request: ProviderRequest): ProviderResponse =
  let body = buildBody(request, stream = false)
  let (client, response) = provider.postChat(body, "OpenRouter request failed: ")
  defer: client.close()
  let raw = response.bodyStream.readAll()
  if response.code.int >= 400:
    raiseApiError(response.code.int, raw)

  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError as e:
    raiseProviderError("OpenRouter returned invalid JSON: " & e.msg)

  if "choices" notin data or data["choices"].len == 0:
    raiseProviderError("OpenRouter response contained no choices")
  result.model = data.getOrDefault("model").getStr
  let message = data["choices"][0]["message"]
  if "content" in message and message["content"].kind == JString:
    result.content.add text(message["content"].getStr)
  if "tool_calls" in message:
    for call in message["tool_calls"]:
      let function = call["function"]
      var input: JsonNode
      try:
        input = parseJson(function["arguments"].getStr)
      except CatchableError as e:
        raiseProviderError("OpenRouter returned invalid tool arguments: " & e.msg)
      result.content.add toolUse(call["id"].getStr, function["name"].getStr, input)

  if "usage" in data:
    parseUsage(data["usage"], result.usage)

  result.finishReason = finishFrom(
    data["choices"][0].getOrDefault("finish_reason").getStr)

type
  PendingTool = object
    id: string
    name: string
    args: string

method generateStream*(provider: OpenRouterProvider,
                       request: ProviderRequest,
                       onEvent: StreamCallback): ProviderResponse =
  # Sync HttpClient.request() buffers the whole SSE body before returning.
  # AsyncHttpClient starts parseBody without awaiting, so bodyStream.read()
  # yields chunks as they arrive. waitFor parks in kqueue until a chunk
  # exists — no timer while waiting.
  provider.ensureApiKey()
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = provider.makeHeaders())
  client.timeout = provider.timeoutSeconds * 1000
  defer:
    client.close()
    unregisterWakeWatch()
  let body = buildBody(request, stream = true)
  var response: AsyncResponse
  try:
    let reqFut = client.request(provider.endpoint, HttpPost, $body)
    if not awaitWithWake(reqFut, request.wakeFd, onEvent):
      result.finishReason = frStop
      return
    response = waitFor reqFut
  except CatchableError as e:
    raiseProviderError("OpenRouter stream failed: " & e.msg, retryable = true)
  if response.code.int >= 400:
    raiseApiError(response.code.int, drainBodyStream(response.bodyStream))

  var textAcc = ""
  var thinkAcc = ""
  var tools: seq[PendingTool] = @[]
  var cancelled = false
  var buf = ""
  block streamLoop:
    while true:
      let readFut = response.bodyStream.read()
      if not awaitWithWake(readFut, request.wakeFd, onEvent):
        cancelled = true
        break streamLoop
      let (more, chunk) = waitFor readFut
      if not more:
        break
      buf.add chunk
      while true:
        let (ok, line) = popLine(buf)
        if not ok: break
        if line.len == 0: continue
        if not line.startsWith("data:"): continue
        let payload = line[5 .. ^1].strip
        if payload == "[DONE]":
          break streamLoop
        var data: JsonNode
        try:
          data = parseJson(payload)
        except CatchableError:
          continue
        if result.model.len == 0:
          result.model = data.getOrDefault("model").getStr
        if "usage" in data and data["usage"].kind == JObject:
          parseUsage(data["usage"], result.usage)
        if "choices" notin data or data["choices"].len == 0:
          continue
        let choice = data["choices"][0]
        let fr = choice.getOrDefault("finish_reason")
        if fr.kind == JString and fr.getStr.len > 0:
          result.finishReason = finishFrom(fr.getStr)
        let delta = choice.getOrDefault("delta")
        if delta.kind != JObject:
          continue
        if "content" in delta and delta["content"].kind == JString:
          let piece = delta["content"].getStr
          if piece.len > 0:
            textAcc.add piece
            if not onEvent(StreamEvent(kind: seTextDelta, text: piece)):
              cancelled = true
              break streamLoop
        var reason = ""
        if "reasoning" in delta:
          let r = delta["reasoning"]
          if r.kind == JString: reason = r.getStr
          elif r.kind == JObject: reason = r.getOrDefault("content").getStr
        if reason.len == 0 and "reasoning_content" in delta:
          reason = delta["reasoning_content"].getStr
        if reason.len > 0:
          thinkAcc.add reason
          if not onEvent(StreamEvent(kind: seThinkingDelta, text: reason)):
            cancelled = true
            break streamLoop
        if "tool_calls" in delta:
          for tc in delta["tool_calls"]:
            let idx = tc.getOrDefault("index").getInt
            while tools.len <= idx:
              tools.add PendingTool()
            if "id" in tc and tc["id"].kind == JString:
              tools[idx].id = tc["id"].getStr
            let fn = tc.getOrDefault("function")
            if fn.kind == JObject:
              if "name" in fn and fn["name"].kind == JString:
                tools[idx].name = fn["name"].getStr
              if "arguments" in fn and fn["arguments"].kind == JString:
                tools[idx].args.add fn["arguments"].getStr

  if thinkAcc.len > 0:
    result.content.add ContentBlock(kind: ckThinking, thinking: thinkAcc)
  if textAcc.len > 0:
    result.content.add text(textAcc)
  for t in tools:
    if t.name.len == 0: continue
    var input: JsonNode
    try:
      input = if t.args.len > 0: parseJson(t.args) else: newJObject()
    except CatchableError as e:
      raiseProviderError("OpenRouter returned invalid tool arguments: " & e.msg)
    let id = if t.id.len > 0: t.id else: "call_" & t.name
    result.content.add toolUse(id, t.name, input)
    if result.finishReason == frUnknown:
      result.finishReason = frToolUse

  if not cancelled:
    discard onEvent(StreamEvent(kind: seFinished))
  elif result.finishReason == frUnknown:
    result.finishReason = frStop
