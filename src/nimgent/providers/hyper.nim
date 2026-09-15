## Hyper adapter using its OpenAI-compatible chat completions API.

import std/[json, options]
import nimgent/providers/provider
import nimgent/providers/openai
export openai except openAI, openRouter,
  defaultOpenAiEndpoint, defaultOpenAiChatEndpoint

type HyperOptions* = object
  ## Hyper-specific controls for its OpenAI-compatible endpoint.
  user*: Option[string]
  parallelToolCalls*: Option[bool]
  includeUsage*: Option[bool] ## Include usage in streamed responses.

proc toProviderJson*(value: HyperOptions): JsonNode =
  result = newJObject()
  if value.user.isSome: result["user"] = %value.user.get
  if value.parallelToolCalls.isSome:
    result["parallel_tool_calls"] = %value.parallelToolCalls.get
  if value.includeUsage.isSome:
    result["stream_options"] = %*{"include_usage": value.includeUsage.get}

proc buildBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## Hyper chat body: `max_tokens`, no session_id or Anthropic cache breakpoints.
  buildChatBody(request, stream, maxTokensField = "max_tokens")
