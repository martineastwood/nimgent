---
title: Anthropic
description: Use Claude models with Anthropic's native API.
---

Connect to Anthropic with an API key, choose a Claude model, and use it with the usual nimgent generation APIs.

## Make a request

```nim
import std/os
import nimgent
import nimgent/providers/anthropic

let model = anthropic(getEnv("ANTHROPIC_API_KEY")).model("claude-sonnet-4-6")
echo generateText(model, prompt = "Say hello in one sentence.").text
```

Set `ANTHROPIC_API_KEY` before you run the program.

## Enable extended thinking

Use `AnthropicOptions` when you want to enable Anthropic thinking with a budget.

```nim
import std/options

let response = generateText(
  model,
  prompt = "Solve this carefully.",
  providerOptions = ProviderOptions(
    anthropic: AnthropicOptions(
      thinking: some(EnabledThinking),
      budgetTokens: some(1024)))
)
```

`EnabledThinking` requires `budgetTokens`, and the minimum budget is `1024`. Use `AdaptiveThinking` when you want Anthropic to choose the thinking budget.

You can also set a portable reasoning level through `GenerationOptions` instead
of Anthropic-specific options. See [Settings](/guides/providers/settings/).

## Prompt caching

Anthropic requests automatically include cache breakpoints on the last tool
definition, the last system block, and the last message content. You do not need
to call anything extra to enable this. Caching only helps when repeated requests
reuse the same prefix, such as a long system prompt or tool list across turns in
a conversation.

## Next steps

See [Settings](/guides/providers/settings/) for portable controls, or [Structured output](/guides/structured-output/) for typed results.
