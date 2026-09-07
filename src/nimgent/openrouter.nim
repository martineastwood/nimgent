## OpenRouter adapter using its OpenAI-compatible chat completions API.

import std/[json, options]
import nimgent/provider
import nimgent/openai
export openai except openAI, hyper, defaultOpenAiEndpoint

proc buildBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## OpenRouter body: max_tokens, session_id, and cache_control breakpoints.
  buildChatBody(request, stream, includeSessionId = true, applyCache = true,
                maxTokensField = "max_tokens")


type
  OpenRouterRouting* = object
    order*: Option[seq[string]]
    only*: Option[seq[string]]
    ignore*: Option[seq[string]]
    allowFallbacks*: Option[bool]
    requireParameters*: Option[bool]
    sort*: Option[string]
  OpenRouterOptions* = object
    routing*: Option[OpenRouterRouting]
    extra*: JsonNode ## Native API fields; typed fields take precedence.

proc toProviderJson*(value: OpenRouterOptions): JsonNode =
  result = newJObject()
  mergeRequestOptions(result, value.extra)
  if value.routing.isSome:
    let routing = value.routing.get
    var node = newJObject()
    if routing.order.isSome: node["order"] = %routing.order.get
    if routing.only.isSome: node["only"] = %routing.only.get
    if routing.ignore.isSome: node["ignore"] = %routing.ignore.get
    if routing.allowFallbacks.isSome: node["allow_fallbacks"] = %routing.allowFallbacks.get
    if routing.requireParameters.isSome: node["require_parameters"] = %routing.requireParameters.get
    if routing.sort.isSome: node["sort"] = %routing.sort.get
    result["provider"] = node
