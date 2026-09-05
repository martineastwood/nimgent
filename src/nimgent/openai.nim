## OpenAI adapter.
##
## Native OpenAI uses the Responses API (`store: false`, reasoning replay).
## OpenRouter, Hyper, and any `*/chat/completions` URL keep Chat Completions,
## including `reasoning` / `reasoning_details` replay. Those extras (session_id,
## cache_control, HTTP-Referer) stay optional on this type.

import std/[asyncdispatch, asyncstreams, httpclient, json, net, streams, strutils]
import nimgent/provider

const
  defaultOpenAiEndpoint* = "https://api.openai.com/v1/responses"
  defaultOpenAiChatEndpoint* = "https://api.openai.com/v1/chat/completions"
  defaultHyperEndpoint* = "https://hyper.charm.land/v1/chat/completions"

type
  OpenAIProvider* = ref object of Provider
    apiKey*: string
    endpoint*: string
    timeoutSeconds*: int
    siteUrl*: string
    siteName*: string
    ## OpenRouter continuation hint; omitted for native OpenAI.
    includeSessionId*: bool
    ## Anthropic-style cache breakpoints; OpenAI caches stable prefixes itself.
    applyCache*: bool
    ## "max_tokens" (OpenRouter) or "max_completion_tokens" (Chat Completions).
    maxTokensField*: string
    displayName*: string
    ## True: POST /v1/responses. False: Chat Completions (OpenRouter / compat).
    useResponses*: bool

  OpenRouterProvider* = OpenAIProvider
  HyperProvider* = OpenAIProvider

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

proc keepChatReasoningDetail(item: JsonNode): bool =
  ## Unsigned Anthropic text details 400 on replay. Other types/formats are fine.
  if item.isNil or item.kind != JObject: return false
  if item.getOrDefault("type").getStr != "reasoning.text":
    return true
  if item.getOrDefault("format").getStr != "anthropic-claude-v1":
    return true
  let sig = item.getOrDefault("signature")
  not sig.isNil and sig.kind == JString and sig.getStr.len > 0

proc attachChatThinking(encoded: JsonNode, message: Message, hasToolCalls: bool) =
  ## Replay thinking the Chat Completions hosts expect (OpenRouter / compat).
  var think = ""
  var details = newJArray()
  var hadDetails = false
  for part in message.content:
    if part.kind != ckThinking: continue
    if part.thinking.len > 0:
      if think.len > 0: think.add "\n"
      think.add part.thinking
    if part.signature.len == 0: continue
    try:
      let j = parseJson(part.signature)
      if j.kind != JArray: continue
      hadDetails = true
      for item in j:
        if keepChatReasoningDetail(item):
          details.add item
    except CatchableError:
      discard
  if details.len > 0:
    if think.len > 0:
      encoded["reasoning"] = %think
    encoded["reasoning_details"] = details
  elif think.len > 0 and not hadDetails and not hasToolCalls:
    # ponytail: plaintext-only models. Tool turns without details stay omitted —
    # Claude-via-OpenRouter 400s unsigned thinking on tool follow-up.
    encoded["reasoning"] = %think

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
  attachChatThinking(encoded, message, calls.len > 0)
  result.add encoded

proc buildChatBody*(request: ProviderRequest, stream: bool,
                    includeSessionId = false, applyCache = false,
                    maxTokensField = "max_completion_tokens"): JsonNode =
  result = %*{
    "model": request.model,
    "messages": newJArray()
  }
  if stream:
    result["stream"] = %true
    result["stream_options"] = %*{"include_usage": true}
  if includeSessionId and request.sessionId.len > 0:
    result["session_id"] = %request.sessionId
  var messages = newJArray()
  if request.maxTokens > 0:
    let field = if maxTokensField.len > 0: maxTokensField else: "max_tokens"
    result[field] = %request.maxTokens
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
  if applyCache:
    applyCacheBreakpoints(result)

proc responsesImagePart(mimeType, data: string): JsonNode =
  %*{"type": "input_image", "image_url": "data:" & mimeType & ";base64," & data}

proc reasoningReplay(part: ContentBlock): JsonNode =
  ## Replay a stored Responses reasoning item. Anthropic signatures are ignored.
  if part.signature.len == 0: return nil
  try:
    let j = parseJson(part.signature)
    if j.kind != JObject or "id" notin j: return nil
    result = %*{"type": "reasoning", "id": j["id"]}
    if "encrypted_content" in j:
      result["encrypted_content"] = j["encrypted_content"]
    if part.thinking.len > 0:
      result["summary"] = %*[{"type": "summary_text", "text": part.thinking}]
  except CatchableError:
    result = nil

proc flushResponsesUser(input: var JsonNode, parts: var seq[JsonNode]) =
  if parts.len == 0: return
  var arr = newJArray()
  for p in parts: arr.add p
  input.add %*{"role": "user", "content": arr}
  parts.setLen(0)

proc addResponsesItems(input: var JsonNode, message: Message) =
  if message.role == roleUser:
    var parts: seq[JsonNode] = @[]
    for part in message.content:
      case part.kind
      of ckText:
        parts.add %*{"type": "input_text", "text": part.text}
      of ckImage:
        parts.add responsesImagePart(part.mimeType, part.data)
      of ckToolResult:
        flushResponsesUser(input, parts)
        input.add %*{"type": "function_call_output", "call_id": part.toolUseId,
          "output": part.output}
        if part.images.len > 0:
          var imgParts = newJArray()
          imgParts.add %*{"type": "input_text", "text": "(image from tool)"}
          for img in part.images:
            imgParts.add responsesImagePart(img.mimeType, img.data)
          input.add %*{"role": "user", "content": imgParts}
      else:
        discard
    if parts.len > 0:
      flushResponsesUser(input, parts)
    elif message.content.len == 0:
      input.add %*{"role": "user", "content": [{"type": "input_text", "text": ""}]}
    return

  for part in message.content:
    case part.kind
    of ckThinking:
      let item = reasoningReplay(part)
      if not item.isNil: input.add item
    of ckText:
      if part.text.len > 0:
        input.add %*{"role": "assistant",
          "content": [{"type": "output_text", "text": part.text}]}
    of ckToolUse:
      let args = if part.input.isNil: "{}" else: part.input.pretty(0)
      input.add %*{"type": "function_call", "call_id": part.id,
        "name": part.name, "arguments": args}
    else:
      discard

proc buildResponsesBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## Native OpenAI Responses body. Stateless: store=false, full input each turn.
  result = %*{
    "model": request.model,
    "input": newJArray(),
    "store": false
  }
  if stream:
    result["stream"] = %true
  if request.maxTokens > 0:
    result["max_output_tokens"] = %request.maxTokens
  if request.system.len > 0:
    result["instructions"] = %request.system.join("\n\n")
  var input = newJArray()
  for message in request.messages:
    addResponsesItems(input, message)
  result["input"] = input
  if request.tools.len > 0:
    result["tools"] = newJArray()
    for tool in request.tools:
      result["tools"].add %*{
        "type": "function",
        "name": tool.name,
        "description": tool.description,
        "parameters": tool.inputSchema
      }
  if not request.options.isNil and request.options.kind != JNull:
    for key, value in request.options:
      result[key] = value
  if "reasoning_effort" in result:
    if "reasoning" notin result:
      result["reasoning"] = %*{"effort": result["reasoning_effort"]}
    delete(result, "reasoning_effort")
  if "reasoning" in result:
    result["include"] = %*["reasoning.encrypted_content"]

proc buildOpenAiBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## Native OpenAI Responses body.
  buildResponsesBody(request, stream)

proc initChatProvider(name, displayName, apiKey, endpoint: string,
                      timeoutSeconds: int, siteUrl = "", siteName = "",
                      includeSessionId = false, applyCache = false,
                      maxTokensField = "max_completion_tokens",
                      useResponses = false): OpenAIProvider =
  OpenAIProvider(name: name, displayName: displayName, apiKey: apiKey,
                 endpoint: endpoint, timeoutSeconds: timeoutSeconds,
                 siteUrl: siteUrl, siteName: siteName,
                 includeSessionId: includeSessionId, applyCache: applyCache,
                 maxTokensField: maxTokensField, useResponses: useResponses)

proc makeOpenAIProvider*(apiKey: string, endpoint = "",
                         timeoutSeconds = 300): OpenAIProvider =
  ## Responses API by default. A `*/chat/completions` URL stays on that wire format.
  let url = if endpoint.len > 0: endpoint else: defaultOpenAiEndpoint
  let responses = "/chat/completions" notin url
  initChatProvider("openai", "OpenAI", apiKey, url, timeoutSeconds,
    maxTokensField = "max_completion_tokens", useResponses = responses)

proc makeOpenRouterProvider*(apiKey, endpoint: string,
                             timeoutSeconds = 300, siteUrl = "",
                             siteName = ""): OpenRouterProvider =
  initChatProvider("openrouter", "OpenRouter", apiKey, endpoint,
    timeoutSeconds, siteUrl, siteName, includeSessionId = true,
    applyCache = true, maxTokensField = "max_tokens")

proc makeHyperProvider*(apiKey: string, endpoint = "",
                        timeoutSeconds = 300): HyperProvider =
  ## Hyper's documented agent API is Chat Completions. Their /v1/responses
  ## pass-through 400s OpenAI input items, so this stays on chat.
  let url = if endpoint.len > 0: endpoint else: defaultHyperEndpoint
  initChatProvider("hyper", "Hyper", apiKey, url, timeoutSeconds,
    maxTokensField = "max_tokens")

proc label(provider: OpenAIProvider): string =
  if provider.displayName.len > 0: provider.displayName else: provider.name

proc makeHeaders(provider: OpenAIProvider): HttpHeaders =
  result = {
    "Authorization": "Bearer " & provider.apiKey,
    "Content-Type": "application/json"
  }.newHttpHeaders
  if provider.siteUrl.len > 0:
    result["HTTP-Referer"] = provider.siteUrl
  if provider.siteName.len > 0:
    result["X-Title"] = provider.siteName

proc parseUsage(usage: JsonNode, result: var Usage) =
  if usage.isNil or usage.kind != JObject: return
  result.inputTokens = usage.getOrDefault("prompt_tokens").getInt
  if result.inputTokens == 0:
    result.inputTokens = usage.getOrDefault("input_tokens").getInt
  result.outputTokens = usage.getOrDefault("completion_tokens").getInt
  if result.outputTokens == 0:
    result.outputTokens = usage.getOrDefault("output_tokens").getInt
  var details = usage.getOrDefault("prompt_tokens_details")
  if details.isNil or details.kind != JObject:
    details = usage.getOrDefault("input_tokens_details")
  if details.isNil or details.kind != JObject:
    return
  result.cacheReadTokens = details.getOrDefault("cached_tokens").getInt
  result.cacheWriteTokens = details.getOrDefault("cache_write_tokens").getInt
  result.cacheReported = ("cached_tokens" in details) or
    ("cache_write_tokens" in details)

proc outputTextFrom(item: JsonNode): string =
  let c = item.getOrDefault("content")
  if c.kind == JString: return c.getStr
  if c.kind != JArray: return
  for part in c:
    if part.getOrDefault("type").getStr in ["output_text", "text"]:
      if result.len > 0: result.add "\n"
      result.add part.getOrDefault("text").getStr

proc thinkingFromReasoningItem(item: JsonNode): ContentBlock =
  var summary = ""
  let s = item.getOrDefault("summary")
  if s.kind == JArray:
    for part in s:
      if part.getOrDefault("type").getStr == "summary_text":
        if summary.len > 0: summary.add "\n"
        summary.add part.getOrDefault("text").getStr
  var sig = newJObject()
  if "id" in item: sig["id"] = item["id"]
  if "encrypted_content" in item: sig["encrypted_content"] = item["encrypted_content"]
  ContentBlock(kind: ckThinking, thinking: summary,
    signature: if sig.len > 0: $sig else: "")

proc parseResponsesOutput(data: JsonNode, failPrefix: string): ProviderResponse =
  if data.isNil or data.kind != JObject:
    raiseProviderError(failPrefix & " returned an empty response")
  let status = data.getOrDefault("status").getStr
  if status == "failed":
    let err = data.getOrDefault("error")
    let detail = if err.kind == JObject: err.getOrDefault("message").getStr
                 else: $data
    raiseProviderError(failPrefix & " response failed: " & detail, retryable = true)
  result.model = data.getOrDefault("model").getStr
  let output = data.getOrDefault("output")
  var hasTool = false
  if output.kind == JArray:
    for item in output:
      case item.getOrDefault("type").getStr
      of "reasoning":
        result.content.add thinkingFromReasoningItem(item)
      of "message":
        let t = outputTextFrom(item)
        if t.len > 0: result.content.add text(t)
      of "function_call":
        hasTool = true
        let args = item.getOrDefault("arguments").getStr
        let id = item.getOrDefault("call_id").getStr
        let name = item.getOrDefault("name").getStr
        result.content.add toolUseFromArgs(
          if id.len > 0: id else: "call_" & name, name, args)
      else:
        discard
  if "usage" in data and data["usage"].kind == JObject:
    parseUsage(data["usage"], result.usage)
  if hasTool:
    result.finishReason = frToolUse
  elif status == "incomplete":
    let reason = data.getOrDefault("incomplete_details").getOrDefault("reason").getStr
    result.finishReason = if reason == "max_output_tokens": frMaxTokens else: frUnknown
  elif status == "completed" or status.len == 0:
    result.finishReason = frStop
  else:
    result.finishReason = frUnknown

proc finishFrom(reason: string): FinishReason =
  case reason
  of "tool_calls": frToolUse
  of "stop": frStop
  of "length": frMaxTokens
  else: frUnknown

proc reasoningFrom(node: JsonNode): string =
  if node.isNil or node.kind != JObject: return
  if "reasoning" in node:
    let r = node["reasoning"]
    if r.kind == JString: result = r.getStr
    elif r.kind == JObject: result = r.getOrDefault("content").getStr
  if result.len == 0 and "reasoning_content" in node and
      node["reasoning_content"].kind == JString:
    result = node["reasoning_content"].getStr

proc reasoningTextFromDetails(details: JsonNode): string =
  if details.isNil or details.kind != JArray: return
  for item in details:
    if item.isNil or item.kind != JObject: continue
    let t = item.getOrDefault("text")
    if not t.isNil and t.kind == JString and t.getStr.len > 0:
      result.add t.getStr
    else:
      let s = item.getOrDefault("summary")
      if not s.isNil and s.kind == JString: result.add s.getStr

proc thinkingFromChat(node: JsonNode): ContentBlock =
  result = ContentBlock(kind: ckThinking, thinking: reasoningFrom(node))
  if node.isNil: return
  let d = node.getOrDefault("reasoning_details")
  if not d.isNil and d.kind == JArray and d.len > 0:
    result.signature = $d
    if result.thinking.len == 0:
      result.thinking = reasoningTextFromDetails(d)

proc mergeChatReasoningDetails(acc: JsonNode, incoming: JsonNode) =
  ## Stream fragments with the same type+index concatenate; later metadata wins.
  if acc.isNil or incoming.isNil or incoming.kind != JArray: return
  for item in incoming:
    if item.isNil or item.kind != JObject: continue
    let idxNode = item.getOrDefault("index")
    let typ = item.getOrDefault("type").getStr
    var merged = false
    if not idxNode.isNil and idxNode.kind == JInt:
      for slot in acc:
        let slotIdx = slot.getOrDefault("index")
        if not slotIdx.isNil and slotIdx.kind == JInt and
            slotIdx.getInt == idxNode.getInt and
            slot.getOrDefault("type").getStr == typ:
          for key, val in item:
            if key in ["text", "summary", "data"] and val.kind == JString:
              let prev = slot.getOrDefault(key)
              if not prev.isNil and prev.kind == JString:
                slot[key] = %(prev.getStr & val.getStr)
              else:
                slot[key] = val
            elif key != "index":
              slot[key] = val
          merged = true
          break
    if not merged:
      acc.add copy(item)

proc ensureApiKey(provider: OpenAIProvider) =
  if provider.apiKey.len == 0:
    raiseProviderError(provider.label.toUpperAscii & " API key is not configured")

proc newClient(provider: OpenAIProvider): HttpClient =
  newHttpClient(timeout = provider.timeoutSeconds * 1000,
                sslContext = newContext(verifyMode = CVerifyPeer))

proc raiseApiError(provider: OpenAIProvider, code: int, raw: string,
                   headers: HttpHeaders = nil) =
  var detail = raw
  try:
    detail = parseJson(raw).getOrDefault("error").getOrDefault("message").getStr
  except CatchableError:
    discard
  let ra = if headers.isNil: 0
           else: parseRetryAfter(headers.getOrDefault("Retry-After"))
  raiseProviderError(provider.label & " API error (" & $code & "): " & detail,
    overflow = isContextOverflow(detail), retryable = isRetryableStatus(code),
    status = code, retryAfterMs = ra)

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

proc requestBody(provider: OpenAIProvider, request: ProviderRequest,
                 stream: bool): JsonNode =
  if provider.useResponses:
    return buildResponsesBody(request, stream)
  buildChatBody(request, stream,
    includeSessionId = provider.includeSessionId,
    applyCache = provider.applyCache,
    maxTokensField = provider.maxTokensField)

proc postChat(provider: OpenAIProvider, body: JsonNode,
              failPrefix: string): tuple[client: HttpClient, response: Response] =
  provider.ensureApiKey()
  result.client = provider.newClient()
  let headers = provider.makeHeaders()
  try:
    result.response = result.client.request(provider.endpoint, HttpPost, $body, headers)
  except CatchableError as e:
    result.client.close()
    raiseProviderError(failPrefix & e.msg, retryable = true)

method generate*(provider: OpenAIProvider,
                 request: ProviderRequest): ProviderResponse =
  let body = provider.requestBody(request, stream = false)
  let (client, response) = provider.postChat(body, provider.label & " request failed: ")
  defer: client.close()
  let raw = response.bodyStream.readAll()
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int, raw, response.headers)

  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError as e:
    raiseProviderError(provider.label & " returned invalid JSON: " & e.msg)

  if provider.useResponses:
    return parseResponsesOutput(data, provider.label)
  if "choices" notin data or data["choices"].len == 0:
    raiseProviderError(provider.label & " response contained no choices")
  result.model = data.getOrDefault("model").getStr
  let message = data["choices"][0]["message"]
  let think = thinkingFromChat(message)
  if think.thinking.len > 0 or think.signature.len > 0:
    result.content.add think
  if "content" in message and message["content"].kind == JString:
    result.content.add text(message["content"].getStr)
  if "tool_calls" in message:
    for call in message["tool_calls"]:
      let function = call["function"]
      result.content.add toolUseFromArgs(call["id"].getStr,
        function["name"].getStr, function["arguments"].getStr)

  if "usage" in data:
    parseUsage(data["usage"], result.usage)

  result.finishReason = finishFrom(
    data["choices"][0].getOrDefault("finish_reason").getStr)

type
  PendingTool = object
    id: string
    name: string
    args: string
    itemId: string

proc eventDelta(data: JsonNode): string =
  let d = data.getOrDefault("delta")
  if d.kind == JString: return d.getStr
  data.getOrDefault("text").getStr

proc toolSlot(tools: var seq[PendingTool], data: JsonNode): int =
  let itemId = data.getOrDefault("item_id").getStr
  if itemId.len > 0:
    for i, t in tools:
      if t.itemId == itemId: return i
  result = data.getOrDefault("output_index").getInt
  while tools.len <= result:
    tools.add PendingTool()
  if itemId.len > 0:
    tools[result].itemId = itemId

method generateStream*(provider: OpenAIProvider,
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
  let body = provider.requestBody(request, stream = true)
  var response: AsyncResponse
  try:
    let reqFut = client.request(provider.endpoint, HttpPost, $body)
    if not awaitWithWake(reqFut, request.wakeFd, onEvent):
      result.finishReason = frStop
      return
    response = waitFor reqFut
  except CatchableError as e:
    raiseProviderError(provider.label & " stream failed: " & e.msg, retryable = true)
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int, drainBodyStream(response.bodyStream),
      response.headers)

  var textAcc = ""
  var thinkAcc = ""
  var detailsAcc = newJArray()
  var tools: seq[PendingTool] = @[]
  var cancelled = false
  var parsedFinal = false
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
        if provider.useResponses:
          let typ = data.getOrDefault("type").getStr
          case typ
          of "response.failed", "error":
            let err = data.getOrDefault("error")
            let detail = if err.kind == JObject: err.getOrDefault("message").getStr
                         else: payload
            raiseProviderError(provider.label & " stream failed: " & detail,
              retryable = true)
          of "response.output_text.delta", "response.text.delta":
            let piece = eventDelta(data)
            if piece.len > 0:
              textAcc.add piece
              if not onEvent(StreamEvent(kind: seTextDelta, text: piece)):
                cancelled = true
                break streamLoop
          of "response.reasoning_summary_text.delta":
            let piece = eventDelta(data)
            if piece.len > 0:
              thinkAcc.add piece
              if not onEvent(StreamEvent(kind: seThinkingDelta, text: piece)):
                cancelled = true
                break streamLoop
          of "response.output_item.added", "response.output_item.done":
            let item = data.getOrDefault("item")
            if item.getOrDefault("type").getStr == "function_call":
              let idx = toolSlot(tools, data)
              if "id" in item: tools[idx].itemId = item["id"].getStr
              if "call_id" in item: tools[idx].id = item["call_id"].getStr
              var nameNew = false
              if "name" in item and item["name"].kind == JString:
                if tools[idx].name.len == 0: nameNew = true
                tools[idx].name = item["name"].getStr
              if typ == "response.output_item.done":
                let args = item.getOrDefault("arguments").getStr
                if args.len > 0: tools[idx].args = args
              if tools[idx].name.len > 0 and nameNew:
                if not onEvent(StreamEvent(kind: seToolCallDelta,
                    toolCallId: tools[idx].id, toolName: tools[idx].name,
                    toolArgs: "")):
                  cancelled = true
                  break streamLoop
          of "response.function_call_arguments.delta":
            let idx = toolSlot(tools, data)
            let piece = eventDelta(data)
            if piece.len > 0:
              tools[idx].args.add piece
              if tools[idx].name.len > 0:
                if not onEvent(StreamEvent(kind: seToolCallDelta,
                    toolCallId: tools[idx].id, toolName: tools[idx].name,
                    toolArgs: piece)):
                  cancelled = true
                  break streamLoop
          of "response.completed", "response.incomplete":
            let resp = data.getOrDefault("response")
            if resp.kind == JObject:
              result = parseResponsesOutput(resp, provider.label)
              parsedFinal = true
            break streamLoop
          else:
            if result.model.len == 0:
              let resp = data.getOrDefault("response")
              if resp.kind == JObject:
                result.model = resp.getOrDefault("model").getStr
            if "usage" in data and data["usage"].kind == JObject:
              parseUsage(data["usage"], result.usage)
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
        mergeChatReasoningDetails(detailsAcc, delta.getOrDefault("reasoning_details"))
        var reason = reasoningFrom(delta)
        if reason.len == 0:
          reason = reasoningTextFromDetails(delta.getOrDefault("reasoning_details"))
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
            var nameNew = false
            var argsPiece = ""
            if fn.kind == JObject:
              if "name" in fn and fn["name"].kind == JString:
                if tools[idx].name.len == 0:
                  nameNew = true
                tools[idx].name = fn["name"].getStr
              if "arguments" in fn and fn["arguments"].kind == JString:
                argsPiece = fn["arguments"].getStr
                tools[idx].args.add argsPiece
            if tools[idx].name.len > 0 and (nameNew or argsPiece.len > 0):
              if not onEvent(StreamEvent(kind: seToolCallDelta,
                  toolCallId: tools[idx].id, toolName: tools[idx].name,
                  toolArgs: argsPiece)):
                cancelled = true
                break streamLoop

  if not parsedFinal:
    if thinkAcc.len > 0 or detailsAcc.len > 0:
      result.content.add ContentBlock(kind: ckThinking, thinking: thinkAcc,
        signature: if detailsAcc.len > 0: $detailsAcc else: "")
    if textAcc.len > 0:
      result.content.add text(textAcc)
    for t in tools:
      if t.name.len == 0: continue
      let id = if t.id.len > 0: t.id else: "call_" & t.name
      result.content.add toolUseFromArgs(id, t.name, t.args)
      if result.finishReason == frUnknown:
        result.finishReason = frToolUse

  if not cancelled:
    discard onEvent(StreamEvent(kind: seFinished))
  elif result.finishReason == frUnknown:
    result.finishReason = frStop
