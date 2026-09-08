## Hyper adapter using its OpenAI-compatible chat completions API.

import std/json
import nimgent/providers/provider
import nimgent/providers/openai
export openai except openAI, openRouter,
  defaultOpenAiEndpoint, defaultOpenAiChatEndpoint

proc buildBody*(request: ProviderRequest, stream: bool): JsonNode =
  ## Hyper chat body: `max_tokens`, no session_id or Anthropic cache breakpoints.
  buildChatBody(request, stream, maxTokensField = "max_tokens")
