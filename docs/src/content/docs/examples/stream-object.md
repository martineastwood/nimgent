---
title: Stream object
description: Receive partial structured output while a model generates it.
---

Stream a structured response and display fields as soon as they appear with
`streamObject`.

The final response is decoded into `Recipe`, while `onPartial` receives the
growing JSON tree. Partial values are useful for progress displays, but use the
final `recipe.value` for validated application data.

```nim
import std/[json, os, strutils]
import nimgent
import nimgent/providers/openai

type Recipe = object
  name: string
  servings: int
  ingredients: seq[string]

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

echo "calling the model..."
let recipe = streamObject[Recipe](
  model,
  prompt = "A weeknight lasagna.",
  onPartial = proc (partial: JsonNode): bool =
    if "name" in partial:
      stdout.write "\rname: " & partial["name"].getStr
      flushFile(stdout)
    true)

echo ""
echo "name: ", recipe.value.name
echo "servings: ", recipe.value.servings
echo "ingredients: ", recipe.value.ingredients.join(", ")
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/stream_object.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/stream_object.nim)
