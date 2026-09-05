## Anthropic Messages API adapter.

import std/[httpclient, json, net, streams]
import nimgent/provider

type
  AnthropicProvider* = ref object of Provider
    apiKey: string
    endpoint: string
    timeoutSeconds: int

proc roleName(role: Role): string =
  if role == roleUser: "user" else: "assistant"

proc anthropicImageBlock*(mimeType, data: string): JsonNode =
  %*{"type": "image", "source": {
    "type": "base64", "media_type": mimeType, "data": data}}

proc encodeBlock(part: ContentBlock): JsonNode =
  case part.kind
  of ckText:
    %*{"type": "text", "text": part.text}
  of ckThinking:
    %*{"type": "thinking", "thinking": part.thinking, "signature": part.signature}
  of ckToolUse:
    %*{"type": "tool_use", "id": part.id, "name": part.name, "input": part.input}
  of ckImage:
    anthropicImageBlock(part.mimeType, part.data)
  of ckToolResult:
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
  result = %*{"role": roleName(message.role), "content": newJArray()}
  for part in message.content:
    result["content"].add encodeBlock(part)

proc makeAnthropicProvider*(apiKey, model, endpoint: string,
                            timeoutSeconds = 300): AnthropicProvider =
  AnthropicProvider(name: "anthropic", apiKey: apiKey, endpoint: endpoint,
                    timeoutSeconds: timeoutSeconds)

method generate*(provider: AnthropicProvider,
                 request: ProviderRequest): ProviderResponse =
  if provider.apiKey.len == 0:
    raiseProviderError("ANTHROPIC API key is not configured")

  var body = %*{
    "model": request.model,
    "max_tokens": request.maxTokens,
    "messages": newJArray()
  }
  if request.system.len > 0:
    var chunks = newJArray()
    for s in request.system:
      chunks.add %*{"type": "text", "text": s}
    body["system"] = chunks
  for message in request.messages:
    body["messages"].add encodeMessage(message)
  if request.tools.len > 0:
    body["tools"] = newJArray()
    for tool in request.tools:
      body["tools"].add %*{
        "name": tool.name,
        "description": tool.description,
        "input_schema": tool.inputSchema
      }
  applyCacheBreakpoints(body)
  if not request.options.isNil and request.options.kind != JNull:
    for key, value in request.options:
      body[key] = value

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
    let detail = try:
      parseJson(raw).getOrDefault("error").getOrDefault("message").getStr
    except CatchableError:
      raw
    let code = response.code.int
    let overflow = code == 400 and isContextOverflow(detail)
    raiseProviderError("Anthropic API error (" & $code & "): " & detail,
                       overflow = overflow, retryable = isRetryableStatus(code),
                       status = code,
                       retryAfterMs = parseRetryAfter(
                         response.headers.getOrDefault("Retry-After")))

  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError as e:
    raiseProviderError("Anthropic returned invalid JSON: " & e.msg)

  for part in data["content"]:
    case part["type"].getStr
    of "text":
      result.content.add text(part["text"].getStr)
    of "tool_use":
      result.content.add toolUse(part["id"].getStr, part["name"].getStr,
        part["input"])
    of "thinking":
      result.content.add ContentBlock(kind: ckThinking,
        thinking: part["thinking"].getStr,
        signature: if "signature" in part: part["signature"].getStr else: "")
    else:
      discard

  if "usage" in data:
    let usage = data["usage"]
    result.usage.inputTokens = usage.getOrDefault("input_tokens").getInt
    result.usage.outputTokens = usage.getOrDefault("output_tokens").getInt
    result.usage.cacheReadTokens = usage.getOrDefault("cache_read_input_tokens").getInt
    result.usage.cacheWriteTokens = usage.getOrDefault("cache_creation_input_tokens").getInt
    result.usage.cacheReported = ("cache_read_input_tokens" in usage) or
      ("cache_creation_input_tokens" in usage)

  result.model = data.getOrDefault("model").getStr
  let stopReason = data.getOrDefault("stop_reason").getStr
  result.finishReason = case stopReason
    of "tool_use": frToolUse
    of "max_tokens": frMaxTokens
    of "end_turn": frEndTurn
    else: frUnknown
