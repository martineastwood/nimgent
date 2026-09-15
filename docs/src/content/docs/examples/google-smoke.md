---
title: Google smoke test
description: Try Gemini hosted tools, URL context, and citations.
---

Ask Gemini to use hosted search and URL context, then print the returned source
citations.

`hostedTool` describes tools that Google runs on your behalf. The response can
contain `ckSource` blocks alongside text, so the example prints each citation's
title and URL after printing the answer.

```nim
import std/os
import nimgent
import nimgent/providers/google

let model = google(getEnv("GEMINI_API_KEY")).model("gemini-3.5-flash-lite")
let response = generateText(model,
  prompt = "Use web search to find the Nim language homepage and read https://nim-lang.org.",
  tools = @[hostedTool("web_search"), hostedTool("url_context")])

echo response.text
for part in response.content:
  if part.kind == ckSource:
    echo "source: ", part.source.title, " ", part.source.url
```

Run it from the repository root:

```sh
GEMINI_API_KEY=... nim c -r examples/google_smoke.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/google_smoke.nim)
