## Structured-output example — JSON in, typed object out.
##
##   OPENAI_API_KEY=... nim c -r examples/generate_object.nim

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
