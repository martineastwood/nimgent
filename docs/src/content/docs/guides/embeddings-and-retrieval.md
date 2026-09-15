---
title: Embeddings and retrieval
description: Search your own notes and use the relevant passages in a model answer.
---

Embeddings let you find the parts of your own content that are most relevant to a question. You can embed your documents once, search them for each question, then give the best matches to a model as context.

## Build a small retrieval flow

This complete example stores three notes in memory, finds the notes closest to a question, and answers using only those notes.

```nim title="answer_from_notes.nim"
import std/[json, os, strutils]
import nimgent
import nimgent/providers/openai
import nimgent/vector_store

let provider = openAI(getEnv("OPENAI_API_KEY"))
let embeddings = provider.embeddingModel("text-embedding-3-small")
let model = provider.model("gpt-4.1-mini")

let documents = @[
  "Nim destructors run deterministically when a value leaves its scope.",
  "Nim can compile to C, C++, JavaScript, or Objective-C.",
  "Nim uses indentation to define blocks."
]

let store = newInMemoryVectorStore()
let indexed = embedMany(embeddings, documents)
for i, document in documents:
  store.upsert($i, indexed.embeddings[i], %*{"text": document})

let question = "When does a Nim destructor run?"
let query = embed(embeddings, question)

var notes: seq[string]
for match in store.search(query.embedding, limit = 2):
  notes.add match.metadata["text"].getStr

let answer = generateText(
  model,
  system = "Answer only from these notes. If they do not answer the question, say so.\n\n" &
    notes.join("\n\n"),
  prompt = question
)

echo answer.text
```

Run it with an API key:

```sh
OPENAI_API_KEY=... nim c -r answer_from_notes.nim
```

The answer is based on the retrieved notes, not on the model's general knowledge.

## How retrieval works

`embedMany` turns each document into a sequence of numbers called an embedding. The result keeps the same order as the input, so `indexed.embeddings[i]` belongs to `documents[i]`.

`upsert` stores each embedding with an ID and metadata. In this example, the metadata holds the original text so it is available after a search.

For each question, `embed` creates one query embedding. `search` returns the closest records, with the best match first. The example joins those records into context and asks the model to answer from that context only.

Use a clear instruction like this whenever you retrieve context. Retrieval makes relevant material available, but the instruction tells the model when it should rely on it and what to do when the material is incomplete.

## Add, update, and save documents

Give each document a stable ID. Calling `upsert` again with the same ID replaces its embedding and metadata, which is useful when a document changes.

```nim
let updated = embed(embeddings, "The updated note text.")
store.upsert("handbook-intro", updated.embedding, %*{
  "text": updated.value,
  "source": "handbook.md"
})
```

You can save the in-memory store and restore it later:

```nim
store.save("notes.json")

let restored = loadInMemoryVectorStore("notes.json")
let matches = restored.search(query.embedding, limit = 2)
```

The saved store includes the vectors and metadata. Keep the original documents separately if you need to rebuild the index.

## Choose a useful document size

Embed passages that are small enough to be useful as answer context. A whole handbook chapter can match a question but still be too broad for a good answer. Split longer content into sections or paragraphs, then store each passage with metadata such as its document title, URL, and section name.

Start with a small search limit, such as `2` or `3`. More matches give the model more context, but they also make the prompt larger and can add unrelated material.

## Troubleshooting and limits

- **A search result is irrelevant:** Split your documents into smaller passages, store better metadata, or try fewer matches.
- **Search fails after changing embedding models:** Every vector in a store must have the same dimensions. Create a new store and re-embed the full corpus when you change models or embedding dimensions.
- **The provider rejects an embedding request:** Embedding availability varies by model and provider. Handle the provider error if the model you choose does not offer embeddings.
- **Your corpus is large:** `InMemoryVectorStore` searches records in memory. It is a good fit for local content and small applications. Use an external vector index when your corpus outgrows memory or needs shared, persistent search.

## Next steps

See the [Core API](/reference/core-api/) for embedding options, or use [Structured output](/guides/structured-output/) when the answer should match a typed schema.
