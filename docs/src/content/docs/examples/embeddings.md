---
title: Embeddings
description: Create embeddings and compare the similarity of text values.
---

Create vectors for several values and compare them with cosine similarity.

`embedMany` preserves the input order, so each vector can be matched to its
original text. The example compares related beach and ocean phrases with an
unrelated compiler phrase and prints the provider's token usage.

```nim
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
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/embeddings.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/embeddings.nim)
