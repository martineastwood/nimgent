## Anthropic Messages API adapter.

import std/[options, asyncdispatch, base64, httpclient, json, net, strutils]
import nimgent/[provider, stream, http_metadata]

const defaultAnthropicEndpoint* = "https://api.anthropic.com/v1/messages"

proc anthropicEfforts*(model: string): seq[string] =
  ## Explicit known families; unknown models retain manual thinking support.
  let m = model.toLowerAscii
  for family in ["claude-sonnet-4-6", "claude-opus-4-6"]:
    if m == family or m.startsWith(family & "-"):
      return @["low", "medium", "high", "max"]
  for family in ["claude-opus-4-7", "claude-opus-4-8", "claude-opus-5",
                 "claude-sonnet-5", "claude-fable-5"]:
    if m == family or m.startsWith(family & "-"):
      return @["low", "medium", "high", "xhigh", "max"]

proc anthropicThinkingOptions*(model, level: string): JsonNode =
  let efforts = anthropicEfforts(model)
  if efforts.len == 0: return thinkingOptions("anthropic", level)
  if level.len == 0: return newJObject()
  if level == "none":
    if model.toLowerAscii.startsWith("claude-fable-5"):
      raise newException(ValueError, "this model requires thinking; choose low or higher")
    return %*{"thinking": {"type": "disabled"}}
  let effort = case level
    of "minimal": "low"
    of "xhigh": (if "xhigh" in efforts: "xhigh" else: "max")
    else: level
  %*{"thinking": {"type": "adaptive", "display": "summarized"},
    "output_config": {"effort": effort}}

type
  AnthropicProvider* = ref object of Provider
    apiKey: string
    endpoint: string
    timeoutSeconds: int

proc anthropicImageBlock*(mimeType, data: string): JsonNode =
  %*{"type": "image", "source": {
    "type": "base64", "media_type": mimeType, "data": data}}

proc anthropicDocument*(f: FileContent): JsonNode =
  let title = fileLabel(f)
  let textDoc = f.mimeType.startsWith("text/") or f.mimeType == "application/json"
  var src: JsonNode
  if textDoc:
    var payload = f.data
    try:
      payload = decode(f.data)
    except CatchableError:
      discard
    src = %*{"type": "text", "media_type": f.mimeType, "data": payload}
  else:
    src = %*{"type": "base64", "media_type": f.mimeType, "data": f.data}
  %*{"type": "document", "source": src, "title": title,
    "citations": {"enabled": true}}

proc encodeHostedTool(tool: ToolDefinition): JsonNode =
  let typ = if tool.hosted == "web_search": "web_search_20250305" else: tool.hosted
  result = %*{"type": typ, "name": tool.hosted}
  if tool.description.len > 0:
    result["description"] = %tool.description
  mergeRequestOptions(result, tool.hostedOptions)

proc encodeBlock(part: ContentBlock): JsonNode =
  case part.kind
  of ckText:
    %*{"type": "text", "text": part.text}
  of ckThinking:
    # Responses/OpenRouter store JSON metadata here; only native opaque
    # Anthropic signatures can be replayed through the Messages API.
    if part.signature.len == 0 or part.signature.strip.startsWith("[") or
        part.signature.strip.startsWith("{"): return nil
    %*{"type": "thinking", "thinking": part.thinking, "signature": part.signature}
  of ckToolUse:
    if part.hosted.len > 0:
      %*{"type": "server_tool_use", "id": part.id, "name": part.name,
        "input": part.input}
    else:
      %*{"type": "tool_use", "id": part.id, "name": part.name, "input": part.input}
  of ckImage:
    anthropicImageBlock(part.mimeType, part.data)
  of ckFile:
    anthropicDocument(part.file)
  of ckSource:
    nil
  of ckToolResult:
    if part.hosted.len > 0:
      var content: JsonNode
      try:
        content = parseJson(part.output)
      except CatchableError:
        content = %part.output
      return %*{"type": part.hosted & "_tool_result",
        "tool_use_id": part.toolUseId, "content": content}
    if part.images.len == 0:
      %*{"type": "tool_result", "tool_use_id": part.toolUseId,
        "content": part.output, "is_error": part.isError}
    else:
      var content = newJArray()
      if part.output.len > 0:
        content.add %*{"type": "text", "text": part.output}
      for img in part.images:
        content.add anthropicImageBlock(img.mimeType, img.data)
      %*{"type": "tool_result", "tool_use_id": part.toolUseId,
        "content": content, "is_error": part.isError}

proc encodeMessage(message: Message): JsonNode =
  result = %*{"role": $message.role, "content": newJArray()}
  var i = 0
  while i < message.content.len:
    let part = message.content[i]
    if part.kind == ckText:
      var textBlock = %*{"type": "text", "text": part.text}
      let cites = takeFollowingSources(message.content, i)
      if cites.len > 0:
        var arr = newJArray()
        for s in cites:
          if not s.source.raw.isNil and s.source.raw.kind == JObject:
            arr.add s.source.raw
        if arr.len > 0:
          textBlock["citations"] = arr
      result["content"].add textBlock
    elif part.kind != ckSource:
      let encoded = encodeBlock(part)
      if not encoded.isNil:
        result["content"].add encoded
    inc i

proc parseAnthropicOutput*(data: JsonNode): ProviderResponse =
  if data.isNil or data.kind != JObject:
    raiseProviderError("Anthropic returned an empty response")
  let content = data.getOrDefault("content")
  if not content.isNil and content.kind == JArray:
    for part in content:
      let typ = part.getOrDefault("type").getStr
      case typ
      of "text":
        result.content.add text(part.getOrDefault("text").getStr)
        let cites = part.getOrDefault("citations")
        if not cites.isNil and cites.kind == JArray:
          for c in cites:
            result.content.add source(
              c.getOrDefault("url").getStr,
              c.getOrDefault("title").getStr,
              citedText = c.getOrDefault("cited_text").getStr,
              raw = copy(c))
      of "tool_use":
        result.content.add toolUse(part["id"].getStr, part["name"].getStr,
          part["input"])
      of "server_tool_use":
        let name = part.getOrDefault("name").getStr
        result.content.add toolUse(part["id"].getStr, name,
          part.getOrDefault("input"), hosted = name)
      of "thinking":
        result.content.add ContentBlock(kind: ckThinking,
          thinking: part.getOrDefault("thinking").getStr,
          signature: part.getOrDefault("signature").getStr)
      else:
        if typ.endsWith("_tool_result"):
          result.content.add toolResult(
            part.getOrDefault("tool_use_id").getStr,
            $part.getOrDefault("content"),
            hosted = typ[0 ..< typ.len - "_tool_result".len])
  if "usage" in data:
    let usage = data["usage"]
    result.usage.inputTokens = usage.getOrDefault("input_tokens").getInt
    result.usage.outputTokens = usage.getOrDefault("output_tokens").getInt
    result.usage.cacheReadTokens = usage.getOrDefault("cache_read_input_tokens").getInt
    result.usage.cacheWriteTokens = usage.getOrDefault("cache_creation_input_tokens").getInt
    result.usage.cacheReported = ("cache_read_input_tokens" in usage) or
      ("cache_creation_input_tokens" in usage)
  result.model = data.getOrDefault("model").getStr
  result.finishReason = case data.getOrDefault("stop_reason").getStr
    of "tool_use": frToolUse
    of "max_tokens": frMaxTokens
    of "end_turn": frEndTurn
    else: frUnknown

proc anthropic*(apiKey: string, endpoint = "",
                timeoutSeconds = 300): AnthropicProvider =
  let url = if endpoint.len > 0: endpoint else: defaultAnthropicEndpoint
  AnthropicProvider(name: "anthropic",
                    capabilities: {pcTools, pcStructuredOutput, pcImages,
                      pcFiles, pcHostedTools, pcStreaming},
                    apiKey: apiKey, endpoint: url,
                    timeoutSeconds: timeoutSeconds)

method nativeObjectOptions*(provider: AnthropicProvider, name, description: string,
                            schema: JsonNode): JsonNode =
  %*{"output_config": {"format": {"type": "json_schema", "schema": schema}}}

method forceToolOptions*(provider: AnthropicProvider, toolName: string): JsonNode =
  %*{"tool_choice": {"type": "tool", "name": toolName}}

proc buildAnthropicBody*(request: ProviderRequest): JsonNode =
  result = %*{
    "model": request.model,
    "max_tokens": request.maxTokens,
    "messages": newJArray()
  }
  if request.system.len > 0:
    var chunks = newJArray()
    for s in request.system:
      chunks.add %*{"type": "text", "text": s}
    result["system"] = chunks
  for message in request.messages:
    let encoded = encodeMessage(message)
    if encoded["content"].len > 0: result["messages"].add encoded
  if request.tools.len > 0:
    result["tools"] = newJArray()
    for tool in request.tools:
      if tool.hosted.len > 0:
        result["tools"].add encodeHostedTool(tool)
      else:
        result["tools"].add %*{
          "name": tool.name,
          "description": tool.description,
          "input_schema": tool.inputSchema
        }
  applyCacheBreakpoints(result)
  mergeRequestOptions(result, request.options)
  let thinking = result.getOrDefault("thinking")
  if not thinking.isNil and thinking.getOrDefault("type").getStr == "enabled":
    result["max_tokens"] = %max(result["max_tokens"].getInt,
      thinking.getOrDefault("budget_tokens").getInt + request.maxTokens)

method generateAsync*(provider: AnthropicProvider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
  if provider.apiKey.len == 0:
    raiseProviderError("ANTHROPIC API key is not configured")

  let body = buildAnthropicBody(request)

  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer))
  client.timeout = provider.timeoutSeconds * 1000
  defer: client.close()
  let headers = newHttpHeaders({
    "x-api-key": provider.apiKey,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json"
  })

  var response: AsyncResponse
  try:
    response = await client.request(provider.endpoint, HttpPost, $body, headers)
  except CatchableError as e:
    raiseProviderError("Anthropic request failed: " & e.msg, retryable = true)
  let raw = await response.body
  if response.code.int >= 400:
    let detail = apiErrorMessage(raw)
    let code = response.code.int
    let overflow = code == 400 and isContextOverflow(detail)
    raiseProviderError("Anthropic API error (" & $code & "): " & detail,
                       overflow = overflow, status = code,
                       retryAfterMs = parseRetryAfter(
                         response.headers.getOrDefault("Retry-After")),
                       requestId = requestIdFromHeaders(response.headers))

  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError as e:
    raiseProviderError("Anthropic returned invalid JSON: " & e.msg)
  result = parseAnthropicOutput(data)
  result.requestId = requestIdFromHeaders(response.headers)

proc handleAnthropicEvent*(message: var JsonNode, args: var seq[string],
                          data: JsonNode, onEvent: StreamCallback): SseAction =
  case data.getOrDefault("type").getStr
  of "message_start":
    message = copy(data["message"])
  of "content_block_start":
    message["content"].add copy(data["content_block"])
    args.add ""
  of "content_block_delta":
    let i = data["index"].getInt
    let delta = data["delta"]
    let part = message["content"][i]
    case delta["type"].getStr
    of "text_delta", "thinking_delta", "signature_delta":
      let field = case delta["type"].getStr
        of "text_delta": "text"
        of "thinking_delta": "thinking"
        else: "signature"
      let chunk = delta[field].getStr
      part[field] = %(part.getOrDefault(field).getStr & chunk)
      if field != "signature":
        let ev = if field == "text": StreamEvent(kind: seTextDelta, text: chunk)
                 else: StreamEvent(kind: seThinkingDelta, text: chunk)
        if not onEvent(ev): return sseCancel
    of "input_json_delta":
      let chunk = delta["partial_json"].getStr
      args[i].add chunk
      if not onEvent(StreamEvent(kind: seToolCallDelta,
          toolCallId: part["id"].getStr, toolName: part["name"].getStr,
          toolArgs: chunk)): return sseCancel
    of "citations_delta":
      if not part.hasKey("citations"): part["citations"] = newJArray()
      part["citations"].add copy(delta["citation"])
    else: discard
  of "content_block_stop":
    let i = data["index"].getInt
    if args[i].len > 0:
      try: message["content"][i]["input"] = parseJson(args[i])
      except CatchableError:
        raiseProviderError("Anthropic returned invalid tool JSON")
  of "message_delta":
    for key, value in data["delta"]: message[key] = copy(value)
    let usage = data.getOrDefault("usage")
    if not usage.isNil:
      for key, value in usage: message["usage"][key] = copy(value)
  of "message_stop": return sseStop
  of "error":
    raiseProviderError("Anthropic stream error: " & apiErrorMessage($data),
      retryable = data{"error", "type"}.getStr in ["overloaded_error", "api_error"])
  else: discard
  sseContinue

method generateStreamAsync*(provider: AnthropicProvider,
                            request: ProviderRequest,
                            onEvent: StreamCallback): Future[ProviderResponse] {.async.} =
  if provider.apiKey.len == 0:
    raiseProviderError("ANTHROPIC API key is not configured")
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = newHttpHeaders({"x-api-key": provider.apiKey,
      "anthropic-version": "2023-06-01", "content-type": "application/json"}))
  client.timeout = provider.timeoutSeconds * 1000
  var watch = WakeWatch()
  defer:
    client.close()
    watch.unregister()
  let body = buildAnthropicBody(request)
  body["stream"] = %true
  var response: AsyncResponse
  try:
    let pending = client.request(provider.endpoint, HttpPost, $body)
    if not await awaitWithWakeAsync(pending, addr watch, request.wakeFd, onEvent):
      result.finishReason = frStop
      return
    response = await pending
  except CatchableError as e:
    raiseProviderError("Anthropic stream failed: " & e.msg, retryable = true)
  if response.code.int >= 400:
    let detail = apiErrorMessage(await drainBodyStreamAsync(response.bodyStream))
    raiseProviderError("Anthropic API error (" & $response.code.int & "): " & detail,
      overflow = response.code.int == 400 and isContextOverflow(detail),
      status = response.code.int,
      retryAfterMs = parseRetryAfter(response.headers.getOrDefault("Retry-After")),
      requestId = requestIdFromHeaders(response.headers))
  var message = %*{"content": [], "usage": {}}
  var args: seq[string]
  var drive: SseDrive
  try:
    drive = await forEachSseAsync(response.bodyStream, addr watch,
      request.wakeFd, onEvent, proc (data: JsonNode): SseAction =
        handleAnthropicEvent(message, args, data, onEvent))
  except ProviderError:
    raise
  except CatchableError as e:
    raiseProviderError("Anthropic stream failed: " & e.msg, retryable = true)
  if drive == sdClosed:
    raiseProviderError("Anthropic stream failed: connection closed mid-response",
      retryable = true)
  if drive == sdCancelled:
    # A cancelled argument fragment is not an executable tool call.
    let content = message["content"]
    if content.len > 0 and content[content.len - 1]{"type"}.getStr in
        ["tool_use", "server_tool_use"]:
      content.elems.setLen(content.len - 1)
  result = parseAnthropicOutput(message)
  result.requestId = requestIdFromHeaders(response.headers)
  if drive == sdCancelled:
    result.finishReason = frStop
  else:
    discard onEvent(StreamEvent(kind: seFinished))


type
  AnthropicThinking* = enum
    DisabledThinking = "disabled"
    AdaptiveThinking = "adaptive"
    EnabledThinking = "enabled"
  AnthropicOptions* = object
    thinking*: Option[AnthropicThinking]
    budgetTokens*: Option[int] ## Required with EnabledThinking.
    effort*: Option[string]
    extra*: JsonNode ## Native API fields; typed fields take precedence.

proc toProviderJson*(value: AnthropicOptions): JsonNode =
  result = newJObject()
  mergeRequestOptions(result, value.extra)
  if value.budgetTokens.isSome and
      (value.thinking.isNone or value.thinking.get != EnabledThinking):
    raiseProviderError("budgetTokens requires EnabledThinking")
  if value.thinking.isSome:
    result["thinking"] = %*{"type": $value.thinking.get}
    if value.thinking.get == EnabledThinking:
      if value.budgetTokens.isNone or value.budgetTokens.get < 1024:
        raiseProviderError("EnabledThinking requires budgetTokens >= 1024")
      result["thinking"]["budget_tokens"] = %value.budgetTokens.get
  if value.effort.isSome: result["output_config"] = %*{"effort": value.effort.get}
