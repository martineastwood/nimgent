## Anthropic Messages API adapter.

import std/[base64, httpclient, json, net, streams, strutils]
import nimgent/provider

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
  if content.kind == JArray:
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

proc makeAnthropicProvider*(apiKey, endpoint: string,
                            timeoutSeconds = 300): AnthropicProvider =
  AnthropicProvider(name: "anthropic", apiKey: apiKey, endpoint: endpoint,
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
    result["messages"].add encodeMessage(message)
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

method generate*(provider: AnthropicProvider,
                 request: ProviderRequest): ProviderResponse =
  if provider.apiKey.len == 0:
    raiseProviderError("ANTHROPIC API key is not configured")

  let body = buildAnthropicBody(request)

  let client = newHttpClient(timeout = provider.timeoutSeconds * 1000,
                              sslContext = newContext(verifyMode = CVerifyPeer))
  defer: client.close()
  let headers = newHttpHeaders({
    "x-api-key": provider.apiKey,
    "anthropic-version": "2023-06-01",
    "content-type": "application/json"
  })

  var response: Response
  try:
    response = client.request(provider.endpoint, HttpPost, $body, headers)
  except CatchableError as e:
    raiseProviderError("Anthropic request failed: " & e.msg, retryable = true)
  let raw = response.bodyStream.readAll()
  if response.code.int >= 400:
    let detail = apiErrorMessage(raw)
    let code = response.code.int
    let overflow = code == 400 and isContextOverflow(detail)
    raiseProviderError("Anthropic API error (" & $code & "): " & detail,
                       overflow = overflow, status = code,
                       retryAfterMs = parseRetryAfter(
                         response.headers.getOrDefault("Retry-After")))

  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError as e:
    raiseProviderError("Anthropic returned invalid JSON: " & e.msg)
  parseAnthropicOutput(data)
