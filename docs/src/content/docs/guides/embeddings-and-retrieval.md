---
title: Embeddings and retrieval
description: Turn text into vectors, search them, and keep the store on disk.
---

An **embedding** is a model's opinion about what a piece of text means, rendered
as a list of floating-point numbers. Text that means similar things lands at
similar coordinates, so "closest vector" becomes a workable stand-in for
"most relevant document".

That is the whole trick behind retrieval: embed your corpus once, embed the
question, return the nearest neighbours, and put them in the prompt. The model
answers from text you chose rather than from memory.

nimgent covers both halves — embedding calls and a small vector store to search.

## Embed

Bind an embedding model the same way you bind a chat model, then call `embed` or
`embedMany`:

```nim
import std/[os, strformat]
import nimgent
import nimgent/providers/openai

let embeddings = openAI(getEnv("OPENAI_API_KEY")).embeddingModel(
  "text-embedding-3-small")

let batch = embedMany(embeddings, @[
  "sunny day at the beach",
  "warm afternoon by the ocean",
  "debugging a compiler error"])

echo batch.usage.tokens
echo &"similarity: {cosineSimilarity(batch.embeddings[0], batch.embeddings[1]):.3f}"
```

`embedMany` sends the whole batch in one provider call and preserves input
order, so `batch.embeddings[i]` is the vector for `batch.values[i]`. `embed`
is the single-string convenience:

```nim
let one = embed(embeddings, "warm beach weather")
echo one.value              # the string you passed
echo one.embedding          # seq[float]
echo one.usage.tokens
```

Both have async twins (`embedAsync`, `embedManyAsync`) and both retry transient
failures the same way generation does. `embedMany` rejects an empty list up
front rather than sending a pointless request.

## Compare and search

`cosineSimilarity(a, b)` is the standard comparison — `1.0` for identical
direction, `0.0` for unrelated, `-1.0` for opposite:

```nim
let score = cosineSimilarity(vectorA, vectorB)
```

It is exported from `nimgent` and is also what the vector store uses internally.
Both vectors must be non-empty and the same length; a zero vector has no
direction and raises rather than returning a plausible-looking number.

## The vector store

`nimgent/vector_store` is a small in-memory store: enough to build retrieval
into an application or a demo without adding a database dependency.

```nim
import std/os
import nimgent
import nimgent/vector_store
import nimgent/providers/openai

let embeddings = openAI(getEnv("OPENAI_API_KEY")).embeddingModel(
  "text-embedding-3-small")

let documents = @[
  "The compiler rejects implicit conversions.",
  "Nim compiles to C, C++, or JavaScript.",
  "Destructors run deterministically at scope exit."]

let store = newInMemoryVectorStore()
let vectors = embedMany(embeddings, documents)

for i, document in documents:
  store.upsert($i, vectors.embeddings[i], %*{"text": document})

let question = embed(embeddings, "When does a destructor run?")
for match in store.search(question.embedding, limit = 2):
  echo match.score, "  ", match.metadata["text"].getStr
```

The four operations are `upsert`, `search`, `delete`, and `save`/`load`:

| Call | Behaviour |
| --- | --- |
| `upsert(id, embedding, metadata)` | Insert, or replace the record with that id. Empty ids are rejected. |
| `search(embedding, limit)` | Nearest records, best score first, ties broken by insertion order. |
| `delete(id)` | Remove one record; returns whether it existed. |
| `save(path)` / `loadInMemoryVectorStore(path)` | Write or read a versioned JSON document. |

`metadata` is a free-form `JsonNode` — put the source text, a file path, a URL,
whatever you will need once you have a hit. `search` returns `VectorMatch`
values with `id`, `score`, and the `metadata` you stored.

The store is stricter than it looks, on purpose:

- **One dimension per store.** The first `upsert` fixes it, and any later vector
  of a different length is rejected. Mixing models in one store is an error, not
  a subtle ranking bug.
- **Deterministic order.** Equal scores fall back to insertion order, so tests
  and demos do not shuffle between runs.
- **Versioned files.** `save` writes a document carrying a schema version;
  `loadInMemoryVectorStore` refuses a file it does not understand, or one whose
  records disagree with the recorded dimension, instead of loading garbage.

## Retrieval into a prompt

A minimal retrieval-augmented turn is: embed the question, take the top matches,
put their text in the prompt.

```nim
var context = ""
for match in store.search(question.embedding, limit = 3):
  context.add "- " & match.metadata["text"].getStr & "\n"

let answer = generateText(
  model,
  system = "Answer only from the notes below. Say so if they do not cover it.\n\n" & context,
  prompt = "When does a destructor run?")
```

Keeping that instruction explicit is what stops retrieval from turning into
confident guesswork: retrieval gives the model material, not an obligation to
use it.

## Tracing

Both embedding helpers accept a `TraceSink`, so retrieval shows up in your spans
alongside generation:

```nim
var spans: seq[TraceSpan]
discard embedMany(embeddings, documents,
  trace = proc (span: TraceSpan) = spans.add span)
```

Embedding spans are `skEmbedding`, nested under their own operation span, and
retries appear as separate attempts — the same shape as model spans.

## Notes and limits

- **Provider support is capability-based.** Check
  `model.provider.supports(pcEmbeddings)` rather than assuming from the adapter
  name. `openAI` and `openRouter` expose embedding endpoints, native `google`
  does too, and `hyper` and `openCode` deliberately do not claim the capability.
  `mistral` inherits the flag from the shared OpenAI-compatible transport, but
  only the first three are exercised by the repository's fixtures — treat an
  unexercised combination as your own integration to verify.
- **Provider-specific knobs go in `providerOptions`.** OpenAI's reduced
  `dimensions` is the typed one:
  `providerOptions = ProviderOptions(openai: OpenAIOptions(dimensions: some(512)))`.
  Note that changing dimensions changes the vector space — re-embed the corpus.
- **This is not a database.** Search is a linear scan over every record in
  memory, and persistence is an explicit `save`. It is built for local retrieval
  and examples; a corpus that outgrows memory wants a real vector index behind
  the same three calls.

Related: [Core API](/reference/core-api/) for the embedding entry points, and
[Structured output](/guides/structured-output/) when the retrieved answer must
be typed rather than prose.
