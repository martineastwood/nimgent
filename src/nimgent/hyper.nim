## Hyper adapter using its OpenAI-compatible chat completions API.

import std/json
import nimgent/provider
import nimgent/openai
export openai except makeOpenAIProvider, makeOpenRouterProvider,
  defaultOpenAiEndpoint, defaultOpenAiChatEndpoint

proc buildBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## Hyper chat body: `max_tokens`, no session_id or Anthropic cache breakpoints.
  buildChatBody(request, stream, maxTokensField = "max_tokens")
