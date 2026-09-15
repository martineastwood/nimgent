---
title: Structured output
description: Decode a model response directly into a typed Nim object.
---

Ask for structured data and receive it as a typed Nim value with
`generateObject`.

The `Recipe` type supplies the JSON Schema automatically. nimgent validates the
model response, converts it to `Recipe`, and exposes the result through
`recipe.value`.

```nim
import std/[os, strutils]
import nimgent
import nimgent/providers/openai

type Recipe = object
  name: string
  servings: int
  ingredients: seq[string]

let model = openAI(getEnv("OPENAI_API_KEY")).model("gpt-4o-mini")

echo "calling the model..."
let recipe = generateObject[Recipe](
  model,
  prompt = "A weeknight lasagna.")

echo "name: ", recipe.value.name
echo "servings: ", recipe.value.servings
echo "ingredients: ", recipe.value.ingredients.join(", ")
```

Run it from the repository root:

```sh
OPENAI_API_KEY=... nim c -r examples/structured_output.nim
```

[View the source example](https://github.com/martineastwood/nimgent/blob/main/examples/structured_output.nim)
