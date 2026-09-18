---
title: Structured output
description: Ask a model for validated Nim values instead of parsing free-form text.
---

Use structured output when your program needs data it can rely on, such as a
recipe, search filters, or a classification result. Define a Nim type, ask the
model for that type, and use the validated value directly.

## Generate a typed value

Define the shape you need, then call `generateObject` with that type:

```nim
import std/os
import nimgent
import nimgent/providers/openai

type Recipe = object
  name: string
  servings: int
  ingredients: seq[string]

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")
let result = generateObject[Recipe](
  model,
  prompt = "Create a weeknight lasagna recipe for four people.")

echo result.value.name
echo result.value.servings
for ingredient in result.value.ingredients:
  echo ingredient
```

Save the example as `recipe.nim`, then run it with:

```sh
OPENAI_API_KEY=... nim c -r -d:ssl recipe.nim
```

`result.value` is a `Recipe`, not a JSON string. nimgent validates the model's
JSON against the type before returning it.

`ObjectResult` also exposes recovery metadata when you need it:

| Field | Meaning |
| --- | --- |
| `repairs` | How many repair turns nimgent requested after validation failures. |
| `attempts` | Total provider attempts, including retries and repairs. |
| `locallyRepaired` | Whether the value was recovered from truncated JSON. |
| `source` | Whether the value came from native output, extracted text, or the submit tool. |
| `response` | The underlying `ProviderResponse`, including usage and finish reason. |

## Shape the result

Use ordinary Nim objects, sequences, enums, and nested types to describe the
data you need:

```nim
type Difficulty = enum easy, medium, hard

type Ingredient = object
  name: string
  quantity: string

type Recipe = object
  name: string
  difficulty: Difficulty
  ingredients: seq[Ingredient]
```

The model must choose one of the enum values and return each nested ingredient
with its declared fields.

Use `Option[T]` for data that may be absent:

```nim
import std/options

type Recipe = object
  name: string
  notes: Option[string]
```

When `notes` has no value, the model returns `null` and you receive `none`.
This form works with strict native structured output. Use `jsonOptional` only
when a field must be omitted entirely, because native mode may reject schemas
with omitted fields.

## Add constraints and descriptions

Field pragmas help the model produce useful values and reject invalid ones:

```nim
type Review = object
  headline {.jsonDescription: "A short, neutral headline.",
             jsonMinLength: 3, jsonMaxLength: 80.}: string
  score {.jsonMinimum: 1, jsonMaximum: 5.}: int
  sourceUrl {.jsonPattern: "^https?://".}: string
```

You can combine pragmas on one field:

| Pragma | Effect |
| --- | --- |
| `jsonDescription` | Adds guidance for the model about what the field should contain. |
| `jsonMinimum` / `jsonMaximum` | Sets inclusive numeric bounds. |
| `jsonMinLength` / `jsonMaxLength` | Sets the minimum or maximum number of characters in a string. |
| `jsonPattern` | Requires a string to match a regular expression. |
| `jsonMinItems` / `jsonMaxItems` | Sets the minimum or maximum number of items in a sequence. |
| `jsonOptional` | Allows the model to omit the field entirely. Use `Option[T]` when `null` is acceptable and native structured output matters. |

Use descriptions for requirements that are easier to express in words than with
a type.

## Use a runtime schema

If the schema comes from configuration or another service, pass a `JsonNode`
instead of a Nim type:

```nim
import std/json

let schema = %*{
  "type": "object",
  "properties": {"answer": {"type": "string"}},
  "required": ["answer"]}

let result = generateObject(
  model,
  schema = schema,
  prompt = "Give a one-word answer.")

echo result.value["answer"].getStr
```

The returned value is a `JsonNode`. If you have a matching Nim type later, use
`result.toObject[YourType]` to decode the validated value.

## Choose an output mode

Leave `mode` at its default, `omAuto`, unless you have a specific requirement:

| Mode | Use it when |
| --- | --- |
| `omAuto` | You want native structured output where available, with JSON text as a fallback. This is the default. |
| `omNative` | The provider must enforce the schema natively. It fails before a request if the provider or schema is incompatible. |
| `omJson` | You need JSON text output rather than a provider-native format. |
| `omTool` | Your model works best when it submits the result through a tool call. The schema root must be an object. |

For example, require native structured output with:

```nim
let result = generateObject[Recipe](
  model,
  prompt = "Create a weeknight lasagna recipe.",
  mode = omNative)
```

## Repair invalid output

If a response is not valid for your schema, `maxRepairs` gives the model extra
attempts to correct it:

```nim
let result = generateObject[Recipe](
  model,
  prompt = "Create a weeknight lasagna recipe.",
  maxRepairs = 1)
```

Each repair is another model call. The default is `0`, so use repairs when a
strict schema is more important than the additional latency and cost.

## Handle truncated output

When a response hits `maxTokens` before the JSON is complete, nimgent can try
to repair the partial value locally. By default it rejects that result:

```nim
let result = generateObject[Recipe](
  model,
  prompt = "Create a detailed lasagna recipe.",
  maxTokens = 256,
  truncation = otReject)  # default
```

Set `truncation = otRepair` when a best-effort value is better than failing
the whole request:

```nim
let result = generateObject[Recipe](
  model,
  prompt = "Create a detailed lasagna recipe.",
  maxTokens = 256,
  truncation = otRepair)

if result.locallyRepaired:
  echo "Used a repaired partial result."
```

Check `result.locallyRepaired` when you need to warn the user that the value
may be incomplete. Increasing `maxTokens` is still the better fix when you
expect large objects.

If no attempt succeeds, `generateObject` raises `ObjectError`:

```nim
try:
  discard generateObject[Recipe](model, prompt = "Create a recipe.")
except ObjectError as error:
  for issue in error.issueDetails:
    echo issue.path, ": ", issue.message
```

## Stream a partial object

Use `streamObject` when your interface should show fields while the model is
still building the object:

```nim
import std/[json, os]

let result = streamObject[Recipe](
  model,
  prompt = "Create a weeknight lasagna recipe.",
  onPartial = proc (partial: JsonNode): bool =
    if "name" in partial:
      stdout.write "\rRecipe: " & partial["name"].getStr
      flushFile(stdout)
    true)

echo ""
echo result.value.name
```

`onPartial` receives best-effort JSON as it arrives. It may be incomplete or
not yet valid, so use `result.value` after `streamObject` returns for the final
validated value. Return `false` from `onPartial` to cancel the stream.

## Troubleshooting

- **Native mode rejects the schema:** use `omAuto`, or remove schema features
  that the provider's native format cannot express. `jsonOptional` is one
  common cause.
- **The model returns an invalid value:** add field descriptions or constraints,
  then consider `maxRepairs` for important responses.
- **The response is cut off:** increase `maxTokens`. By default, a response
  truncated at the token limit is rejected rather than treated as a complete
  object. Use `truncation = otRepair` when a best-effort partial value is
  acceptable.
- **You need an omitted field instead of `null`:** use `jsonOptional`, keeping
  in mind that it may not work with `omNative`.

## Next steps

- [Streaming](/guides/streaming/) to show text and tool activity as it arrives.
- [Tools and agents](/guides/tools-and-agents/) to use the same typed inputs for tools.
- [Providers](/guides/providers/) to choose a provider and its options.
