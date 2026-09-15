---
title: Errors and retries
description: What nimgent retries, what it raises, and how to tell them apart.
---

Model calls fail for mundane reasons: a rate limit, a flaky connection, a
context window you overshot. nimgent's policy is to absorb the failures that are
worth absorbing and to surface the rest with enough detail to act on — no
silent retry loops, no swallowed errors.

The useful split is between three things that look alike in a stack trace:

- **Transport and API failures** — raise `ProviderError`.
- **Failures the model should see** — tool errors, which are values, not
  exceptions.
- **Your own mistakes** — bad arguments, which raise immediately and locally.

## What gets retried

`generateText`, `streamText`, `generateObject`, and the embedding helpers retry
by default. An attempt is retried when **all** of these hold:

- the error is marked `retryable` — HTTP 429, any 5xx, or a transport failure;
- no response content has started arriving yet (a stream that has emitted a
  delta is never restarted);
- the error is not context overflow and not a cancellation;
- attempts remain under `maxRetries`, which defaults to `2`.

Everything else fails on the first attempt. A 400 from a bad request will fail
the same way the second time, and a context overflow needs a smaller prompt, not
another call.

### Backoff

Between attempts nimgent waits, using the server's `Retry-After` when it sent
one (capped at 30 seconds, so a wild header cannot park your process) and
otherwise a full-jitter exponential backoff based on 250 ms, capped at 8
seconds:

```nim
let response = generateText(model, prompt = "…", maxRetries = 5)
```

Sleeps are abort-aware — they check your `abort` callback every 50 ms — so a
cancellation during backoff returns promptly instead of waiting out the delay.
`retryDelayMs(attempt, retryAfterMs)` is exported if you want to reason about
the schedule yourself.

## Watching retries happen

Rather than guessing from logs, observe them:

```nim
let response = generateText(model, prompt = "…",
  callbacks = RunCallbacks(
    onRetry: proc (attempt: int, delayMs: int, error: ref ProviderError) =
      echo "attempt ", attempt, " failed (", error.status, "), retrying in ", delayMs, "ms"))
```

`attempt` is 1-based. A `TraceSink` records the same thing as separate model
spans, each carrying `http_status`, `retryable`, `will_retry`, `retry_delay_ms`,
and `request_id`.

## Reading a `ProviderError`

```nim
try:
  discard generateText(model, prompt = "…")
except ProviderError as e:
  echo e.msg          # human-readable message
  echo e.status       # HTTP status, or 0 when there was no response
  echo e.retryable    # 429 / 5xx / transport
  echo e.overflow     # context window exceeded
  echo e.aborted      # your abort() returned true
  echo e.requestId    # provider request id, for support
  echo e.retryAfterMs # server-supplied delay, 0 if none
```

The fields exist so that application-level policy does not have to parse
strings. `overflow` is detected from the provider's own wording rather than a
generic "token" match, which is why it is reliable enough to branch on:
shrink the prompt, drop history, or compact — do not retry. `requestId` is
forwarded from the provider, so a user-facing "contact support" flow can quote
something the provider will recognise.

## Cancellation

Cancelling is not an error condition in the same sense, but it does raise:
`CancelledError`, which is a `ProviderError` subtype with `aborted` set. Catch it
before the general case when the difference matters:

```nim
try:
  let response = generateText(model, prompt = "…",
    abort = proc (): bool = stopRequested)
except CancelledError:
  echo "stopped by the caller"
except ProviderError as e:
  echo "failed: ", e.msg
```

There are three places cancellation is checked, and each covers a different
kind of wait:

| Trigger | Where it is noticed |
| --- | --- |
| `abort = proc (): bool` | Before each attempt, during backoff, and before each tool call |
| Streaming callback returns `false` | Immediately, mid-stream |
| `ToolContext.abort()` inside a tool | Wherever your tool checks it |

A tool that ignores `context.abort()` will finish its work regardless — the
check is cooperative, because nimgent cannot safely interrupt your code. Check
it between chunks of work in anything long-running.

## Failures the model handles

Tool problems are deliberately not exceptions. Invalid arguments, a raised
exception inside your handler, an explicit `toolFailure(...)`, and a denied
approval all become structured tool results the model reads on the next turn:

```nim
proc lookup(ctx: ToolContext, input: LookupInput): ToolResult =
  if input.id notin knownIds:
    return toolFailure("not_found", "No record exists", %*{"id": input.id},
      retryable = false)
  ToolResult(output: describe(record(input.id)), value: %*record(input.id))
```

The code and message are for the model — it can retry with different arguments
when `retryable` is true, or explain the problem. The run itself succeeded: that
is the point. A tool failure never aborts the loop, so a flaky dependency
becomes a turn the model can reason about instead of a dead run. See
[Tools and agents](/guides/tools-and-agents/) for shaping those failures.

Structured output is the in-between case. `generateObject` raises an
`ObjectError` (also a `ProviderError`) once every attempt and repair has failed:

```nim
try:
  let recipe = generateObject[Recipe](model, prompt = "A weeknight lasagna.")
except ObjectError as e:
  for issue in e.issueDetails:
    echo issue.path, ": ", issue.message   # "$.servings: expected integer"
  echo e.raw                               # exactly what the model produced
```

`ObjectError` is also raised **before** any request for problems no retry can
fix: an invalid schema, a schema that `omNative` cannot express, or `omNative`
against a provider with no native structured output. Those messages name the
keyword or the provider, so the fix is in your code rather than in a prompt.

## Errors that mean "fix your code"

Some arguments are validated up front, on the caller's thread, before anything
is sent:

- `maxRetries < 0`, `maxSteps < 1`, `maxRepairs < 0` — `ProviderError` with a
  message naming the argument.
- Empty or duplicate tool names, or a tool without a JSON Schema object — same.
- `toolChoiceSpecific` naming a tool you did not pass — `ProviderError`.
- Empty `values` for `embedMany`, or an empty/duplicate schema problem —
  `ProviderError`.
- Vector store misuse (empty id, mismatched embedding dimension, unreadable
  store file) — `ValueError`.
- Typed provider options that contradict each other, such as Anthropic
  `budgetTokens` without `EnabledThinking` — `ProviderError`, raised locally
  instead of arriving as a 400.

Treating these as bugs rather than conditions to handle is the intended
reading: they are all decidable at the call site.

## A workable handler

```nim
proc ask(model: LanguageModel, prompt: string): string =
  var attempt = 0
  while true:
    inc attempt
    try:
      return generateText(model, prompt = prompt, maxRetries = 2).text
    except CancelledError:
      raise                                  # the caller asked to stop
    except ProviderError as e:
      if e.overflow and attempt < 3:
        continue                             # caller should shrink context here
      echo "giving up: ", e.msg, " (", e.status, ", req ", e.requestId, ")"
      raise
```

The shape worth copying: separate cancellation first, branch on `overflow`
rather than on message text, and re-raise once the retries are spent so the
failure is visible instead of becoming an empty string.

Related: [Tools and agents](/guides/tools-and-agents/) for model-facing
failures, [Structured output](/guides/structured-output/) for repair turns, and
[Core API](/reference/core-api/) for the cancellation and retry parameters.
