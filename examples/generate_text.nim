## Basic generateText example (AI SDK "generate text" recipe).
##
##   OPENAI_API_KEY=... nim c -r examples/generate_text.nim

import std/os
import nimgent
import nimgent/openai

let provider = makeOpenAIProvider(getEnv("OPENAI_API_KEY"))

echo "calling the LLM..."
let response = generateText(
  provider,
  model = "gpt-4o-mini",
  system = @["You are a helpful assistant. Answer concisely and without using markdown."],
  prompt = "Explain why the sky is blue in 10 or fewer words.")

echo response.textContent
