## Wrap a provider with request/response hooks — inject a default system
## prompt, log usage, and redact output, all without touching the adapter.
##
##   OPENAI_API_KEY=... nim c -r examples/wrap_provider.nim

import std/[os, strutils]
import nimgent
import nimgent/openai

let inner: OpenAIProvider = openAI(getEnv("OPENAI_API_KEY"))

let model: LanguageModel = wrapProvider(
  inner,
  mapRequest = proc (req: ProviderRequest): ProviderRequest =
    var r: ProviderRequest = req  # return a copy; the tool loop reuses one request across turns
    if r.system.len == 0:
      r.system = @["Answer in five words or fewer."]
    r,
  mapResponse = proc (req: ProviderRequest, resp: var ProviderResponse) =
    echo "usage: " & $resp.usage.inputTokens & " in / " &
      $resp.usage.outputTokens & " out"
    for blk in resp.content.mitems:
      if blk.kind == ckText and blk.text.contains("secret"):
        blk.text = blk.text.replace("secret", "[redacted]")
).model("gpt-4o-mini")

echo "calling the model..."
let response: ProviderResponse = generateText(
  model,
  prompt = "Say the secret word in one sentence.")

echo response.text
