## Structured-output example — JSON in, typed object out.
##
##   OPENAI_API_KEY=... nim c -r examples/generate_object.nim

import std/[os, strutils]
import nimgent
import nimgent/openai

type Recipe = object
  name: string
  servings: int
  ingredients: seq[string]

let provider = makeOpenAIProvider(getEnv("OPENAI_API_KEY"))

echo "calling the model..."
let recipe = generateObject[Recipe](
  provider,
  model = "gpt-4o-mini",
  prompt = "A weeknight lasagna.")

echo "name: ", recipe.value.name
echo "servings: ", recipe.value.servings
echo "ingredients: ", recipe.value.ingredients.join(", ")
