## Streaming structured output — JSON object streamed, then decoded.
##
##   OPENAI_API_KEY=... nim c -r examples/stream_object.nim

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
