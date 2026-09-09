---
title: Structured output
description: Validate model output against JSON Schema and decode it into Nim.
---

Define the result type, then let nimgent derive its schema and decode the
validated response:

```nim
type Recipe = object
  name: string
  servings: int
  ingredients: seq[string]

let recipe = generateObject[Recipe](
  model,
  prompt = "A weeknight lasagna.")

echo recipe.value.name
echo recipe.value.servings
```

The result includes the decoded value, the original `ProviderResponse`, usage,
repair counts, and the source mode used by the provider.

## Schema-first output

For a runtime schema, pass a `JsonNode` directly:

```nim
let schema = %*{
  "type": "object",
  "properties": {"answer": {"type": "string"}},
  "required": ["answer"]}

let result = generateObject(
  model,
  schema = schema,
  prompt = "Give a one-word answer.")
```

Schemas are checked before the provider is called. Depending on the selected
`ObjectMode`, nimgent uses native structured output, JSON text extraction, or a
forced submit tool. `omAuto` prefers native output and falls back when the
provider cannot support the schema.

## Repairs and truncation

Set `maxRepairs` when a model turn may need to be corrected:

```nim
let result = generateObject[Recipe](
  model,
  prompt = "A weeknight lasagna.",
  maxRepairs = 2)
```

Malformed JSON can be locally repaired while parsing. Max-token truncation is
rejected by default; opt into accepting a repaired truncated value with
`truncation = otRepair`.
