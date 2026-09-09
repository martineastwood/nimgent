## OpenAI embeddings example — embed several values and compare similarity.
##
##   OPENAI_API_KEY=... nim c -r examples/embeddings.nim

import std/[os, strformat]
import nimgent
import nimgent/providers/openai

let model: EmbeddingModel = openAI(getEnv("OPENAI_API_KEY")).embeddingModel(
  "text-embedding-3-small")

let values = @[
  "sunny day at the beach",
  "warm afternoon by the ocean",
  "debugging a compiler error"
]

echo "creating embeddings..."
let result: EmbedManyResult = embedMany(model, values)

for i in 1 ..< values.len:
  let similarity = cosineSimilarity(result.embeddings[0], result.embeddings[i])
  echo &"similarity between item 0 and item {i}: {similarity:.3f}"

echo "input tokens: ", result.usage.tokens
