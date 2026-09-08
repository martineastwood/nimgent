## Small shared helpers for HTTP metadata exposed by provider adapters.

import std/[httpclient, strutils]

proc requestIdFromHeaders*(headers: HttpHeaders): string =
  ## Provider request IDs use different conventional header names.
  if headers.isNil:
    return
  for name in ["x-request-id", "request-id", "anthropic-request-id",
               "x-goog-request-id"]:
    let values = headers.getOrDefault(name)
    let value = ($values).strip
    if value.len > 0:
      return value
