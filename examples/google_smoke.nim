## Live Gemini smoke test: hosted search, URL context, and citations.
##
##   AI_STUDIO_API_KEY=... nim c -r examples/google_smoke.nim

import std/os
import nimgent
import nimgent/providers/google

let model = google(getEnv("AI_STUDIO_API_KEY")).model("gemini-3.5-flash-lite")
let response = generateText(model,
  prompt = "Use web search to find the Nim language homepage and read https://nim-lang.org.",
  tools = @[hostedTool("web_search"), hostedTool("url_context")])

echo response.text
for part in response.content:
  if part.kind == ckSource:
    echo "source: ", part.source.title, " ", part.source.url
