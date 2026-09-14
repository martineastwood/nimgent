## OpenAI-family HTTP provider.
##
## Native OpenAI uses the Responses API (`store: false`, reasoning replay).
## OpenRouter, Hyper, Mistral, OpenCode's Chat protocol, and any
## `*/chat/completions` URL use Chat Completions.
## Session_id, cache_control, and HTTP-Referer stay optional on this type.

import std/[options, asyncdispatch, httpclient, json, net, strutils]
import nimgent/providers/[anthropic, google_transport, provider, stream,
  http_metadata, openai_chat, openai_responses]
import nimgent/structured_output/jsonschema_validate
export popLine, buildChatBody, openAiImagePart, buildResponsesBody,
  parseResponsesOutput, chatObjectOptions, responsesObjectOptions

const
  defaultOpenAiEndpoint* = "https://api.openai.com/v1/responses"
  defaultOpenAiChatEndpoint* = "https://api.openai.com/v1/chat/completions"
  defaultOpenRouterEndpoint* = "https://openrouter.ai/api/v1/chat/completions"
  defaultHyperEndpoint* = "https://hyper.charm.land/v1/chat/completions"
  defaultMistralEndpoint* = "https://api.mistral.ai/v1/chat/completions"
  defaultOpenCodeEndpoint* = "https://opencode.ai/zen/go/v1/chat/completions"
  defaultOpenCodeZenEndpoint* = "https://opencode.ai/zen/v1/chat/completions"

proc gatewayBase*(url: string): string =
  ## The gateway root the protocol paths hang off, or "" when `url` is not a
  ## recognized endpoint. `https://host/v1/chat/completions` → `https://host/v1`,
  ## which is also where Gemini's `/models/<id>:generateContent` lives.
  for suffix in ["/chat/completions", "/responses", "/messages"]:
    if url.endsWith(suffix):
      return url[0 ..< url.len - suffix.len]

proc siblingEndpoint*(url, sibling: string): string =
  ## A gateway endpoint's sibling path, or "" when no known path is present.
  let base = gatewayBase(url)
  if base.len > 0: base & "/" & sibling else: ""

proc protocolEndpoint(url, path: string): string =
  if url.endsWith(path): return url
  let sibling = siblingEndpoint(url, path[1 .. ^1])
  if sibling.len > 0: sibling else: url

type
  ## Per-model surface override for gateways that serve a few models on a
  ## different wire format. Returns the endpoint for that model, or "" for the
  ## provider default. `useResponses` follows from the returned URL.
  OpenAiRoute* = proc (model: string): string {.closure.}

  OpenCodeProtocol* = enum
    ocChat
    ocResponses
    ocMessages
    ocGoogle

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
    ## Mistral prompt caching key derived from the request session ID.
    promptCacheKey*: bool
    ## "max_tokens" (OpenRouter/Mistral) or "max_completion_tokens" (Chat Completions).
    maxTokensField*: string
    displayName*: string
    ## True: POST /v1/responses. False: Chat Completions (OpenRouter / compat).
    useResponses*: bool
    embeddingsEndpoint*: string
    ## Header carrying a stable conversation id. Empty: the id stays in the body
    ## (`includeSessionId`) or is not sent. OpenCode Zen wants `x-opencode-session`.
    sessionHeader*: string
    ## Gateway-facing client identity; empty keeps the HTTP library default.
    userAgent*: string
    ## Models this gateway only serves on another surface.
    route*: OpenAiRoute

  OpenRouterProvider* = OpenAIProvider
  HyperProvider* = OpenAIProvider
  MistralProvider* = OpenAIProvider
  OpenCodeProvider* = OpenAIProvider

proc initOpenAIProvider(name, displayName, apiKey, endpoint: string,
                      timeoutSeconds: int, siteUrl = "", siteName = "",
                      includeSessionId = false, applyCache = false,
                      maxTokensField = "max_completion_tokens",
                      useResponses = false, embeddingsEndpoint = "",
                      promptCacheKey = false, sessionHeader = "",
                      userAgent = "", route: OpenAiRoute = nil): OpenAIProvider =
  let capabilities = {pcStreaming, pcTools, pcStructuredOutput, pcImages, pcFiles}
  result = OpenAIProvider(name: name, capabilities:
                   if useResponses: capabilities + {pcHostedTools}
                   else: capabilities,
                 displayName: displayName, apiKey: apiKey,
                 endpoint: endpoint, timeoutSeconds: timeoutSeconds,
                 siteUrl: siteUrl, siteName: siteName,
                 includeSessionId: includeSessionId, applyCache: applyCache,
                 promptCacheKey: promptCacheKey, sessionHeader: sessionHeader,
                 userAgent: userAgent, route: route,
                 maxTokensField: maxTokensField, useResponses: useResponses)
  let base = gatewayBase(endpoint)
  result.embeddingsEndpoint = if embeddingsEndpoint.len > 0: embeddingsEndpoint
    elif base.len > 0: base & "/embeddings"
    else: endpoint & "/embeddings"
  if name notin ["hyper", "opencode"]: result.capabilities.incl pcEmbeddings

proc openAI*(apiKey: string, endpoint = "", timeoutSeconds = 300,
             userAgent = ""): OpenAIProvider =
  ## Responses API by default. A `*/chat/completions` URL stays on that wire format.
  let url = if endpoint.len > 0: endpoint else: defaultOpenAiEndpoint
  let responses = "/chat/completions" notin url
  initOpenAIProvider("openai", "OpenAI", apiKey, url, timeoutSeconds,
    maxTokensField = "max_completion_tokens", useResponses = responses,
    userAgent = userAgent)

proc openRouter*(apiKey: string, endpoint = "", timeoutSeconds = 300,
                 siteUrl = "", siteName = "", userAgent = ""): OpenRouterProvider =
  let url = if endpoint.len > 0: endpoint else: defaultOpenRouterEndpoint
  initOpenAIProvider("openrouter", "OpenRouter", apiKey, url,
    timeoutSeconds, siteUrl, siteName, includeSessionId = true,
    applyCache = true, maxTokensField = "max_tokens", userAgent = userAgent)

proc hyper*(apiKey: string, endpoint = "",
            timeoutSeconds = 300, userAgent = ""): HyperProvider =
  ## Hyper's documented agent API is Chat Completions. Their /v1/responses
  ## pass-through 400s OpenAI input items, so this stays on chat.
  let url = if endpoint.len > 0: endpoint else: defaultHyperEndpoint
  initOpenAIProvider("hyper", "Hyper", apiKey, url, timeoutSeconds,
    maxTokensField = "max_tokens", userAgent = userAgent)

proc openCodeBase(endpoint: string): string =
  if endpoint.len > 0: endpoint else: defaultOpenCodeEndpoint

proc openCodeChat*(apiKey: string, endpoint = "", timeoutSeconds = 300,
                   userAgent = "nimgent"): OpenCodeProvider =
  let url = protocolEndpoint(openCodeBase(endpoint), "/chat/completions")
  initOpenAIProvider("opencode", "OpenCode", apiKey, url, timeoutSeconds,
    maxTokensField = "max_tokens", sessionHeader = "x-opencode-session",
    userAgent = userAgent)

proc openCodeResponses*(apiKey: string, endpoint = "", timeoutSeconds = 300,
                        userAgent = "nimgent"): OpenCodeProvider =
  let url = protocolEndpoint(openCodeBase(endpoint), "/responses")
  initOpenAIProvider("opencode", "OpenCode", apiKey, url, timeoutSeconds,
    maxTokensField = "max_tokens", useResponses = true,
    sessionHeader = "x-opencode-session", userAgent = userAgent)

proc openCodeMessages*(apiKey: string, endpoint = "", timeoutSeconds = 300,
                       userAgent = "nimgent"): AnthropicProvider =
  let url = protocolEndpoint(openCodeBase(endpoint), "/messages")
  anthropic(apiKey, url, timeoutSeconds,
    sessionHeader = "x-opencode-session", userAgent = userAgent)

proc openCodeGoogle*(apiKey: string, endpoint = "", timeoutSeconds = 300,
                     userAgent = "nimgent"): GoogleProvider =
  ## The gateway's Gemini models on the native Google surface: the same key and
  ## gateway root, `/models/<id>:generateContent` instead of an OpenAI path.
  ## Zen documents no embeddings endpoint, so the capability is dropped.
  let base = openCodeBase(endpoint)
  let root = gatewayBase(base)
  result = google(apiKey, if root.len > 0: root else: base, timeoutSeconds, userAgent)
  result.capabilities.excl pcEmbeddings

proc openCode*(apiKey: string, endpoint = "", timeoutSeconds = 300,
               userAgent = "nimgent", protocol = ocChat): Provider =
  ## OpenCode's gateways expose separate wire protocols. nimgent keeps that
  ## choice explicit; Nimlet may add catalog-aware routing above these adapters.
  case protocol
  of ocChat:
    openCodeChat(apiKey, endpoint, timeoutSeconds, userAgent)
  of ocResponses:
    openCodeResponses(apiKey, endpoint, timeoutSeconds, userAgent)
  of ocMessages:
    routeProvider(openCodeMessages(apiKey, endpoint, timeoutSeconds, userAgent),
      name = "opencode")
  of ocGoogle:
    routeProvider(openCodeGoogle(apiKey, endpoint, timeoutSeconds, userAgent),
      name = "opencode")

proc openCodeZen*(apiKey: string, endpoint = "", timeoutSeconds = 300,
                  userAgent = "nimgent", protocol = ocChat): Provider =
  ## OpenCode Zen's full catalog: the same protocols as the Go subscription,
  ## on the plain `/zen/v1` gateway.
  openCode(apiKey, if endpoint.len > 0: endpoint else: defaultOpenCodeZenEndpoint,
    timeoutSeconds, userAgent, protocol)

proc mistral*(apiKey: string, endpoint = "", timeoutSeconds = 300,
              userAgent = ""): MistralProvider =
  let url = if endpoint.len > 0: endpoint else: defaultMistralEndpoint
  initOpenAIProvider("mistral", "Mistral", apiKey, url, timeoutSeconds,
    maxTokensField = "max_tokens", promptCacheKey = true, userAgent = userAgent)

proc label(provider: OpenAIProvider): string =
  if provider.displayName.len > 0: provider.displayName else: provider.name

proc makeHeaders(provider: OpenAIProvider, sessionId = ""): HttpHeaders =
  result = {
    "Authorization": "Bearer " & provider.apiKey,
    "Content-Type": "application/json"
  }.newHttpHeaders
  if provider.siteUrl.len > 0:
    result["HTTP-Referer"] = provider.siteUrl
  if provider.siteName.len > 0:
    result["X-Title"] = provider.siteName
  if provider.userAgent.len > 0:
    result["User-Agent"] = provider.userAgent
  if provider.sessionHeader.len > 0 and sessionId.len > 0:
    result[provider.sessionHeader] = sessionId

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

proc endpointFor*(provider: OpenAIProvider, model: string): string =
  ## Endpoint this model goes to. A per-model route wins over `endpoint`.
  let routed = if provider.route.isNil: "" else: provider.route(model)
  if routed.len > 0: routed else: provider.endpoint

proc usesResponsesFor*(provider: OpenAIProvider, model: string): bool =
  ## Whether this model speaks the Responses wire format on that endpoint.
  let routed = if provider.route.isNil: "" else: provider.route(model)
  if routed.len > 0: "/chat/completions" notin routed else: provider.useResponses

proc requestBody(provider: OpenAIProvider, request: ProviderRequest,
                 stream: bool): JsonNode =
  if provider.usesResponsesFor(request.model):
    return buildResponsesBody(request, stream)
  let cacheKey = if provider.promptCacheKey and request.sessionId.len > 0:
                   "nimgent:" & request.sessionId
                 else: ""
  buildChatBody(request, stream,
    includeSessionId = provider.includeSessionId,
    applyCache = provider.applyCache,
    maxTokensField = provider.maxTokensField,
    promptCacheKey = cacheKey)

method nativeObjectOptions*(provider: OpenAIProvider, model, name,
                            description: string, schema: JsonNode): JsonNode =
  if provider.usesResponsesFor(model):
    responsesObjectOptions(name, description, schema)
  else:
    chatObjectOptions(name, description, schema)

method nativeObjectSchemaIssues*(provider: OpenAIProvider, model: string,
                                 schema: JsonNode): seq[string] =
  validateOpenAiStrictSchema(schema)

method generateAsync*(provider: OpenAIProvider,
                      request: ProviderRequest): Future[ProviderResponse] {.async.} =
  provider.ensureApiKey()
  let body = provider.requestBody(request, stream = false)
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = provider.makeHeaders(request.sessionId))
  client.timeout = provider.timeoutSeconds * 1000
  defer: client.close()
  var response: AsyncResponse
  try:
    response = await client.request(provider.endpointFor(request.model),
      HttpPost, $body)
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
  if provider.usesResponsesFor(request.model):
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

type StreamState = ref object
  acc: StreamAcc
  response: ProviderResponse

proc streamHandler(provider: OpenAIProvider, responses: bool, state: StreamState,
                   onEvent: StreamCallback): proc (data: JsonNode): SseAction =
  if responses:
    result = proc (data: JsonNode): SseAction =
      handleResponsesEvent(state.acc, state.response, data, onEvent, provider.label)
  else:
    result = proc (data: JsonNode): SseAction =
      handleChatEvent(state.acc, state.response, data, onEvent)

method generateStreamAsync*(provider: OpenAIProvider,
                            request: ProviderRequest,
                            onEvent: StreamCallback): Future[ProviderResponse] {.async.} =
  # Sync HttpClient.request() buffers the whole SSE body before returning.
  # AsyncHttpClient starts parseBody without awaiting, so bodyStream.read()
  # yields chunks as they arrive.
  provider.ensureApiKey()
  let client = newAsyncHttpClient(
    sslContext = newContext(verifyMode = CVerifyPeer),
    headers = provider.makeHeaders(request.sessionId))
  client.timeout = provider.timeoutSeconds * 1000
  var watch = WakeWatch()
  defer:
    client.close()
    watch.unregister()
  var payload = $provider.requestBody(request, stream = true)
  var response: AsyncResponse
  try:
    let reqFut = client.request(provider.endpointFor(request.model), HttpPost,
      payload)
    if not await awaitWithWakeAsync(reqFut, addr watch, request.wakeFd, onEvent):
      result.finishReason = frStop
      return
    response = await reqFut
    payload.setLen(0)
  except CatchableError as e:
    raiseProviderError(provider.label & " stream failed: " & e.msg, retryable = true)
  if response.code.int >= 400:
    provider.raiseApiError(response.code.int,
      await drainBodyStreamAsync(response.bodyStream),
      response.headers)

  let state = StreamState(acc: initStreamAcc())
  let requestId = requestIdFromHeaders(response.headers)
  let handle = provider.streamHandler(provider.usesResponsesFor(request.model),
    state, onEvent)
  let drive = await forEachSseAsync(response.bodyStream, addr watch,
    request.wakeFd, onEvent, handle)
  if drive == sdCancelled:
    assembleStream(state.acc, state.response)
    result = state.response
    result.requestId = requestId
    if result.finishReason == frUnknown:
      result.finishReason = frStop
    return
  if drive == sdClosed and state.response.finishReason == frUnknown:
    raiseProviderError(provider.label &
      " stream failed: connection closed mid-response", retryable = true)
  assembleStream(state.acc, state.response)
  result = state.response
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
