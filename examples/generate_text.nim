## Basic generateText example (AI SDK "generate text" recipe).
##
##   OPENAI_API_KEY=... nim c -r examples/generate_text.nim

import std/os
import nimgent
import nimgent/openai

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

echo "calling the LLM..."
let response = generateText(
  model,
  system = "You are a helpful assistant. Answer concisely and without using markdown.",
  prompt = "Explain why the sky is blue in 10 or fewer words.")

echo response.text
