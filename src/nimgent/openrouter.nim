## OpenRouter adapter using its OpenAI-compatible chat completions API.

import std/json
import nimgent/provider
import nimgent/openai
export openai except openAI, hyper, defaultOpenAiEndpoint

proc buildBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## OpenRouter body: max_tokens, session_id, and cache_control breakpoints.
  buildChatBody(request, stream, includeSessionId = true, applyCache = true,
                maxTokensField = "max_tokens")
