## OpenAI-family HTTP provider.
##
## Native OpenAI uses the Responses API (`store: false`, reasoning replay).
## OpenRouter, Hyper, and any `*/chat/completions` URL keep Chat Completions.
## Session_id, cache_control, and HTTP-Referer stay optional on this type.

import std/[options, asyncdispatch, httpclient, json, net, strutils]
import nimgent/providers/[provider, stream, http_metadata, openai_chat, openai_responses]
export popLine, buildChatBody, openAiImagePart, buildResponsesBody,
  parseResponsesOutput, chatObjectOptions, chatForceToolOptions,
  responsesObjectOptions, responsesForceToolOptions

const
  defaultOpenAiEndpoint* = "https://api.openai.com/v1/responses"
  defaultOpenAiChatEndpoint* = "https://api.openai.com/v1/chat/completions"
  defaultOpenRouterEndpoint* = "https://openrouter.ai/api/v1/chat/completions"
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
    embeddingsEndpoint*: string

  OpenRouterProvider* = OpenAIProvider
  HyperProvider* = OpenAIProvider

proc initOpenAIProvider(name, displayName, apiKey, endpoint: string,
                      timeoutSeconds: int, siteUrl = "", siteName = "",
                      includeSessionId = false, applyCache = false,
                      maxTokensField = "max_completion_tokens",
                      useResponses = false, embeddingsEndpoint = ""): OpenAIProvider =
  let capabilities = {pcStreaming, pcTools, pcStructuredOutput, pcImages, pcFiles}
  result = OpenAIProvider(name: name, capabilities:
                   if useResponses: capabilities + {pcHostedTools}
                   else: capabilities,
                 displayName: displayName, apiKey: apiKey,
                 endpoint: endpoint, timeoutSeconds: timeoutSeconds,
                 siteUrl: siteUrl, siteName: siteName,
                 includeSessionId: includeSessionId, applyCache: applyCache,
                 maxTokensField: maxTokensField, useResponses: useResponses)
  result.embeddingsEndpoint = if embeddingsEndpoint.len > 0: embeddingsEndpoint
    elif endpoint.endsWith("/responses"): endpoint[0 ..< endpoint.len - "/responses".len] & "/embeddings"
    elif endpoint.endsWith("/chat/completions"): endpoint[0 ..< endpoint.len - "/chat/completions".len] & "/embeddings"
    else: endpoint & "/embeddings"
  if name != "hyper": result.capabilities.incl pcEmbeddings

proc openAI*(apiKey: string, endpoint = "",
             timeoutSeconds = 300): OpenAIProvider =
  ## Responses API by default. A `*/chat/completions` URL stays on that wire format.
  let url = if endpoint.len > 0: endpoint else: defaultOpenAiEndpoint
  let responses = "/chat/completions" notin url
  initOpenAIProvider("openai", "OpenAI", apiKey, url, timeoutSeconds,
    maxTokensField = "max_completion_tokens", useResponses = responses)

proc openRouter*(apiKey: string, endpoint = "", timeoutSeconds = 300,
                 siteUrl = "", siteName = ""): OpenRouterProvider =
  let url = if endpoint.len > 0: endpoint else: defaultOpenRouterEndpoint
  initOpenAIProvider("openrouter", "OpenRouter", apiKey, url,
    timeoutSeconds, siteUrl, siteName, includeSessionId = true,
    applyCache = true, maxTokensField = "max_tokens")

proc hyper*(apiKey: string, endpoint = "",
            timeoutSeconds = 300): HyperProvider =
  ## Hyper's documented agent API is Chat Completions. Their /v1/responses
  ## pass-through 400s OpenAI input items, so this stays on chat.
  let url = if endpoint.len > 0: endpoint else: defaultHyperEndpoint
  initOpenAIProvider("hyper", "Hyper", apiKey, url, timeoutSeconds,
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

proc ensureApiKey(provider: OpenAIProvider) =
  if provider.apiKey.len == 0:
    raiseProviderError(provider.label.toUpperAscii & " API key is not configured")

proc raiseApiError(provider: OpenAIProvider, code: int, raw: string,
                   headers: HttpHeaders = nil) =
  let detail = apiErrorMessage(raw)
  let ra = if headers.isNil: 0
           else: parseRetryAfter(headers.getOrDefault("Retry-After"))
  raiseProviderError(provider.label & " API error (" & $code & "): " & detail,
    overflow = isContextOverflow(detail), status = code, retryAfterMs = ra,
    requestId = requestIdFromHeaders(headers))

proc requestBody(provider: OpenAIProvider, request: ProviderRequest,
                 stream: bool): JsonNode =
  if provider.useResponses:
    return buildResponsesBody(request, stream)
  buildChatBody(request, stream,
    includeSessionId = provider.includeSessionId,
    applyCache = provider.applyCache,
    maxTokensField = provider.maxTokensField)

method nativeObjectOptions*(provider: OpenAIProvider, name, description: string,
                            schema: JsonNode): JsonNode =
  if provider.useResponses:
    responsesObjectOptions(name, description, schema)
  else:
    chatObjectOptions(name, description, schema)

method forceToolOptions*(provider: OpenAIProvider, toolName: string): JsonNode =
  if provider.useResponses:
    responsesForceToolOptions(toolName)
  else:
    chatForceToolOptions(toolName)

method generateAsync*(provider: OpenAIProvider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
  provider.ensureApiKey()
  let body = provider.requestBody(request, stream = false)
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = provider.makeHeaders())
  client.timeout = provider.timeoutSeconds * 1000
  defer: client.close()
  var response: AsyncResponse
  try:
    response = await client.request(provider.endpoint, HttpPost, $body)
  except CatchableError as e:
    raiseProviderError(provider.label & " request failed: " & e.msg,
      retryable = true)
  let raw = await drainBodyStreamAsync(response.bodyStream)
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int, raw, response.headers)
  var data: JsonNode
  try:
    data = parseJson(raw)
  except CatchableError as e:
    raiseProviderError(provider.label & " returned invalid JSON: " & e.msg)
  if provider.useResponses:
    result = parseResponsesOutput(data, provider.label)
  else:
    result = parseChatOutput(data, provider.label)
  result.requestId = requestIdFromHeaders(response.headers)

method embedAsync*(provider: OpenAIProvider,
                   request: EmbeddingRequest): Future[EmbeddingResponse] {.async.} =
  provider.ensureApiKey()
  var body = if request.options.isNil: newJObject() else: copy(request.options)
  if body.kind != JObject:
    raiseProviderError("embedding options must be a JSON object")
  body["model"] = %request.model
  body["input"] = %request.values
  body["encoding_format"] = %"float"
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = provider.makeHeaders())
  client.timeout = provider.timeoutSeconds * 1000
  defer: client.close()
  var response: AsyncResponse
  try:
    response = await client.request(provider.embeddingsEndpoint, HttpPost, $body)
  except CatchableError as e:
    raiseProviderError(provider.label & " embedding request failed: " & e.msg,
      retryable = true)
  let raw = await drainBodyStreamAsync(response.bodyStream)
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int, raw, response.headers)
  var data: JsonNode
  try:
    data = parseJson(raw)
    result.model = data{"model"}.getStr(request.model)
    result.embeddings.setLen(request.values.len)
    for item in data["data"]:
      let index = item["index"].getInt
      if index < 0 or index >= result.embeddings.len:
        raise newException(ValueError, "embedding index is out of range")
      for value in item["embedding"]:
        result.embeddings[index].add value.getFloat
    result.usage.tokens = data{"usage", "prompt_tokens"}.getInt(
      data{"usage", "total_tokens"}.getInt)
  except CatchableError as e:
    raiseProviderError(provider.label & " returned invalid embedding JSON: " & e.msg)
  result.requestId = requestIdFromHeaders(response.headers)

method generateStreamAsync*(provider: OpenAIProvider,
                            request: ProviderRequest,
                            onEvent: StreamCallback): Future[ProviderResponse] {.async.} =
  # Sync HttpClient.request() buffers the whole SSE body before returning.
  # AsyncHttpClient starts parseBody without awaiting, so bodyStream.read()
  # yields chunks as they arrive.
  provider.ensureApiKey()
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = provider.makeHeaders())
  client.timeout = provider.timeoutSeconds * 1000
  var watch = WakeWatch()
  defer:
    client.close()
    watch.unregister()
  let body = provider.requestBody(request, stream = true)
  var response: AsyncResponse
  try:
    let reqFut = client.request(provider.endpoint, HttpPost, $body)
    if not await awaitWithWakeAsync(reqFut, addr watch, request.wakeFd, onEvent):
      result.finishReason = frStop
      return
    response = await reqFut
  except CatchableError as e:
    raiseProviderError(provider.label & " stream failed: " & e.msg, retryable = true)
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int,
      await drainBodyStreamAsync(response.bodyStream),
      response.headers)

  var acc = initStreamAcc()
  var resp = ProviderResponse()
  let requestId = requestIdFromHeaders(response.headers)
  let handle =
    if provider.useResponses:
      proc (data: JsonNode): SseAction =
        handleResponsesEvent(acc, resp, data, onEvent, provider.label)
    else:
      proc (data: JsonNode): SseAction =
        handleChatEvent(acc, resp, data, onEvent)
  let drive = await forEachSseAsync(response.bodyStream, addr watch,
    request.wakeFd, onEvent, handle)
  if drive == sdCancelled:
    assembleStream(acc, resp)
    result = resp
    result.requestId = requestId
    if result.finishReason == frUnknown:
      result.finishReason = frStop
    return
  if drive == sdClosed and resp.finishReason == frUnknown:
    raiseProviderError(provider.label &
      " stream failed: connection closed mid-response", retryable = true)
  assembleStream(acc, resp)
  result = resp
  result.requestId = requestId
  discard onEvent(StreamEvent(kind: seFinished))


type OpenAIOptions* = object
  ## Optional request settings. `extra` uses native API field names.
  reasoningEffort*: Option[string]
  parallelToolCalls*: Option[bool]
  store*: Option[bool]
  user*: Option[string]
  dimensions*: Option[int] ## Embedding requests only.
  extra*: JsonNode

proc toProviderJson*(value: OpenAIOptions): JsonNode =
  result = newJObject()
  mergeRequestOptions(result, value.extra)
  if value.reasoningEffort.isSome: result["reasoning_effort"] = %value.reasoningEffort.get
  if value.parallelToolCalls.isSome: result["parallel_tool_calls"] = %value.parallelToolCalls.get
  if value.store.isSome: result["store"] = %value.store.get
  if value.user.isSome: result["user"] = %value.user.get
  if value.dimensions.isSome: result["dimensions"] = %value.dimensions.get
