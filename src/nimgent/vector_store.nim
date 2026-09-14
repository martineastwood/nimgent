## Small in-memory vector store for local retrieval and examples.

import std/[algorithm, json, math]

const vectorStoreSchemaVersion = 1

type
  VectorRecord* = object
    id*: string
    embedding*: seq[float]
    metadata*: JsonNode

  VectorMatch* = object
    id*: string
    score*: float
    metadata*: JsonNode

  InMemoryVectorStore* = ref object
    records: seq[VectorRecord]
    dimension: int

proc cosineSimilarity*(a, b: openArray[float]): float =
  ## Cosine similarity in [-1, 1]. Both vectors must be non-empty and equal-sized.
  if a.len == 0 or a.len != b.len:
    raise newException(ValueError, "vectors must be non-empty and the same length")
  var dot, normA, normB: float
  for i in 0 ..< a.len:
    dot += a[i] * b[i]
    normA += a[i] * a[i]
    normB += b[i] * b[i]
  if normA == 0 or normB == 0:
    raise newException(ValueError, "cosine similarity is undefined for a zero vector")
  dot / sqrt(normA * normB)

proc newInMemoryVectorStore*(): InMemoryVectorStore =
  InMemoryVectorStore()

proc copyEmbedding(embedding: openArray[float]): seq[float] =
  result = newSeq[float](embedding.len)
  for i, value in embedding:
    result[i] = value

proc validateEmbedding(store: InMemoryVectorStore, embedding: openArray[float]) =
  discard cosineSimilarity(embedding, embedding)
  if store.dimension != 0 and embedding.len != store.dimension:
    raise newException(ValueError, "embedding dimension must be " & $store.dimension &
      ", got " & $embedding.len)

proc upsert*(store: InMemoryVectorStore, id: string,
             embedding: openArray[float], metadata: JsonNode = nil) =
  if store.isNil:
    raise newException(ValueError, "vector store must not be nil")
  if id.len == 0:
    raise newException(ValueError, "vector ID must not be empty")
  store.validateEmbedding(embedding)
  if store.dimension == 0:
    store.dimension = embedding.len
  let record = VectorRecord(id: id, embedding: copyEmbedding(embedding),
    metadata: metadata)
  for i, existing in store.records:
    if existing.id == id:
      store.records[i] = record
      return
  store.records.add record

proc delete*(store: InMemoryVectorStore, id: string): bool =
  if store.isNil:
    raise newException(ValueError, "vector store must not be nil")
  for i, record in store.records:
    if record.id == id:
      store.records.delete(i)
      return true
  false

proc search*(store: InMemoryVectorStore, embedding: openArray[float],
             limit = 10): seq[VectorMatch] =
  if store.isNil:
    raise newException(ValueError, "vector store must not be nil")
  if limit < 0:
    raise newException(ValueError, "search limit must not be negative")
  store.validateEmbedding(embedding)
  var scored: seq[tuple[match: VectorMatch, order: int]]
  for order, record in store.records:
    scored.add (VectorMatch(id: record.id,
      score: cosineSimilarity(embedding, record.embedding),
      metadata: record.metadata), order)
  sort(scored, proc (a, b: tuple[match: VectorMatch, order: int]): int =
    if a.match.score == b.match.score: cmp(a.order, b.order)
    elif a.match.score > b.match.score: -1
    else: 1)
  result = newSeqOfCap[VectorMatch](min(limit, scored.len))
  for i in 0 ..< min(limit, scored.len):
    result.add scored[i].match

proc storeJson(store: InMemoryVectorStore): JsonNode =
  if store.isNil:
    raise newException(ValueError, "vector store must not be nil")
  result = %*{"version": vectorStoreSchemaVersion,
    "dimension": store.dimension, "records": newJArray()}
  for record in store.records:
    let metadata = if record.metadata.isNil: newJNull() else: copy(record.metadata)
    result["records"].add %*{
      "id": record.id,
      "embedding": record.embedding,
      "metadata": metadata}

proc save*(store: InMemoryVectorStore, path: string) =
  ## Save the store as a readable, versioned JSON document.
  writeFile(path, $store.storeJson)

proc invalidStoreFile(message: string): ref ValueError =
  newException(ValueError, "invalid vector store file: " & message)

proc loadInMemoryVectorStore*(path: string): InMemoryVectorStore =
  ## Load a store saved by `save`.
  let raw = readFile(path)
  var document: JsonNode
  try:
    document = parseJson(raw)
  except CatchableError as e:
    raise invalidStoreFile(e.msg)
  if document.kind != JObject:
    raise invalidStoreFile("root must be an object")
  let version = document.getOrDefault("version")
  if version.isNil or version.kind != JInt or version.getInt != vectorStoreSchemaVersion:
    raise invalidStoreFile("unsupported version")
  let dimension = document.getOrDefault("dimension")
  if dimension.isNil or dimension.kind != JInt or dimension.getInt < 0:
    raise invalidStoreFile("dimension must be a non-negative integer")
  let records = document.getOrDefault("records")
  if records.isNil or records.kind != JArray:
    raise invalidStoreFile("records must be an array")

  result = newInMemoryVectorStore()
  result.dimension = dimension.getInt
  for item in records:
    if item.isNil or item.kind != JObject:
      raise invalidStoreFile("record must be an object")
    let id = item.getOrDefault("id")
    let values = item.getOrDefault("embedding")
    if id.isNil or id.kind != JString or id.getStr.len == 0:
      raise invalidStoreFile("record ID must be a non-empty string")
    if values.isNil or values.kind != JArray:
      raise invalidStoreFile("record embedding must be an array")
    var embedding: seq[float]
    for value in values:
      if value.kind notin {JInt, JFloat}:
        raise invalidStoreFile("record embedding values must be numbers")
      embedding.add value.getFloat
    let metadata = if "metadata" notin item or item["metadata"].kind == JNull:
      nil
    else:
      copy(item["metadata"])
    try:
      result.upsert(id.getStr, embedding, metadata)
    except ValueError as e:
      raise invalidStoreFile(e.msg)
  if result.dimension != dimension.getInt:
    raise invalidStoreFile("dimension does not match records")
