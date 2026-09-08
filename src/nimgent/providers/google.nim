## Google Gemini native API adapter and typed options.

import std/[json, options]
import nimgent/providers/provider
import nimgent/providers/google_transport
export google_transport


type GoogleOptions* = object
  ## Google Gemini native request settings.
  reasoningEffort*: Option[string] ## "minimal".."high", or "none"
  extra*: JsonNode                 ## Native API fields; typed fields take precedence.

proc toProviderJson*(value: GoogleOptions): JsonNode =
  result = newJObject()
  mergeRequestOptions(result, value.extra)
  if value.reasoningEffort.isSome:
    result["reasoning_effort"] = %value.reasoningEffort.get
