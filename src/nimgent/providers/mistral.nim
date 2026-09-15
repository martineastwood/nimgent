## Mistral adapter using its OpenAI-compatible Chat Completions API.

import std/json
import nimgent/providers/provider
import nimgent/providers/openai
export openai except openAI, openRouter, hyper,
  defaultOpenAiEndpoint, defaultOpenAiChatEndpoint,
  defaultOpenRouterEndpoint, defaultHyperEndpoint

proc buildBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## Build a Mistral Chat Completions request body.
  let cacheKey = if request.sessionId.len > 0: "nimgent:" & request.sessionId else: ""
  buildChatBody(request, stream, maxTokensField = "max_tokens",
    promptCacheKey = cacheKey)
