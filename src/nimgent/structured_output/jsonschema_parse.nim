## Loose JSON extraction and partial JSON repair used by structured output.

import std/[json, strutils]

proc skipJsonString(s: string, i: var int) =
  inc i
  while i < s.len:
    if s[i] == '\\':
      inc i, 2
    elif s[i] == '"':
      inc i
      return
    else:
      inc i

proc sliceJsonValue(s: string): string =
  var start = -1
  for i, c in s:
    if c in {'{', '['}:
      start = i
      break
  if start < 0: return ""
  var depth = 0
  var i = start
  while i < s.len:
    let c = s[i]
    if c == '"':
      skipJsonString(s, i)
      continue
    if c in {'{', '['}: inc depth
    elif c in {'}', ']'}:
      dec depth
      if depth == 0:
        return s[start .. i]
    inc i
  ""

proc stripFence(s: string): string =
  result = strutils.strip(s)
  if not result.startsWith("```"): return
  let nl = result.find('\n')
  if nl < 0: return
  result = result[nl + 1 .. ^1]
  if result.endsWith("```"):
    result = strutils.strip(result[0 .. ^4])

proc extractJson*(s: string): JsonNode =
  ## A complete JSON value, or the first object/array after leading prose.
  let fenced = stripFence(s)
  if fenced.len == 0: return nil
  try:
    let n = parseJson(fenced)
    return n
  except CatchableError:
    discard
  let slice = sliceJsonValue(fenced)
  if slice.len == 0: return nil
  try:
    let n = parseJson(slice)
    if n.kind in {JObject, JArray}: return n
  except CatchableError:
    discard
  result = nil

type
  PartialParse* = enum
    ppUndefined
    ppSuccess
    ppRepaired
    ppFailed

  FixState = enum
    fsRoot
    fsFinish
    fsString
    fsStringEscape
    fsStringUnicode
    fsLiteral
    fsNumber
    fsObjectStart
    fsObjectKey
    fsObjectKeyEscape
    fsObjectKeyUnicode
    fsObjectAfterKey
    fsObjectBeforeValue
    fsObjectAfterValue
    fsObjectAfterComma
    fsArrayStart
    fsArrayAfterValue
    fsArrayAfterComma

proc fixJson*(input: string): string =
  ## Close a prefix of JSON so `parseJson` can read it. Port of AI SDK `fixJson`.
  var stack: seq[FixState] = @[fsRoot]
  var lastValid = -1
  var literalStart = -1
  var unicodeDigits = 0

  proc afterObject(c: char, i: int) =
    case c
    of ',':
      discard stack.pop()
      stack.add fsObjectAfterComma
    of '}':
      lastValid = i
      discard stack.pop()
    else: discard

  proc afterArray(c: char, i: int) =
    case c
    of ',':
      discard stack.pop()
      stack.add fsArrayAfterComma
    of ']':
      lastValid = i
      discard stack.pop()
    else: discard

  proc valueStart(c: char, i: int, swap: FixState) =
    case c
    of '"':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsString
    of 'f', 't', 'n':
      lastValid = i
      literalStart = i
      discard stack.pop()
      stack.add swap
      stack.add fsLiteral
    of '-':
      discard stack.pop()
      stack.add swap
      stack.add fsNumber
    of '0'..'9':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsNumber
    of '{':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsObjectStart
    of '[':
      lastValid = i
      discard stack.pop()
      stack.add swap
      stack.add fsArrayStart
    else: discard

  for i, c in input:
    case stack[^1]
    of fsRoot:
      valueStart(c, i, fsFinish)
    of fsObjectStart:
      case c
      of '"':
        discard stack.pop()
        stack.add fsObjectKey
      of '}':
        lastValid = i
        discard stack.pop()
      else: discard
    of fsObjectAfterComma:
      if c == '"':
        discard stack.pop()
        stack.add fsObjectKey
    of fsObjectKey:
      case c
      of '"':
        discard stack.pop()
        stack.add fsObjectAfterKey
      of '\\':
        stack.add fsObjectKeyEscape
      else:
        discard
    of fsObjectKeyEscape:
      discard stack.pop()
      if c == 'u':
        unicodeDigits = 0
        stack.add fsObjectKeyUnicode
    of fsObjectKeyUnicode:
      if c in HexDigits:
        inc unicodeDigits
        if unicodeDigits == 4:
          discard stack.pop()
    of fsObjectAfterKey:
      if c == ':':
        discard stack.pop()
        stack.add fsObjectBeforeValue
    of fsObjectBeforeValue:
      valueStart(c, i, fsObjectAfterValue)
    of fsObjectAfterValue:
      afterObject(c, i)
    of fsString:
      case c
      of '"':
        discard stack.pop()
        lastValid = i
      of '\\':
        stack.add fsStringEscape
      else:
        lastValid = i
    of fsArrayStart:
      if c == ']':
        lastValid = i
        discard stack.pop()
      else:
        lastValid = i
        valueStart(c, i, fsArrayAfterValue)
    of fsArrayAfterValue:
      case c
      of ',':
        discard stack.pop()
        stack.add fsArrayAfterComma
      of ']':
        lastValid = i
        discard stack.pop()
      else:
        lastValid = i
    of fsArrayAfterComma:
      valueStart(c, i, fsArrayAfterValue)
    of fsStringEscape:
      discard stack.pop()
      if c == 'u':
        unicodeDigits = 0
        stack.add fsStringUnicode
      else:
        lastValid = i
    of fsStringUnicode:
      if c in HexDigits:
        inc unicodeDigits
        if unicodeDigits == 4:
          discard stack.pop()
          lastValid = i
    of fsNumber:
      case c
      of '0'..'9':
        lastValid = i
      of 'e', 'E', '-', '.':
        discard
      of ',':
        discard stack.pop()
        if stack[^1] == fsArrayAfterValue: afterArray(c, i)
        if stack[^1] == fsObjectAfterValue: afterObject(c, i)
      of '}':
        discard stack.pop()
        if stack[^1] == fsObjectAfterValue: afterObject(c, i)
      of ']':
        discard stack.pop()
        if stack[^1] == fsArrayAfterValue: afterArray(c, i)
      else:
        discard stack.pop()
    of fsLiteral:
      let partial = input[literalStart .. i]
      if not "false".startsWith(partial) and not "true".startsWith(partial) and
          not "null".startsWith(partial):
        discard stack.pop()
        if stack[^1] == fsObjectAfterValue: afterObject(c, i)
        elif stack[^1] == fsArrayAfterValue: afterArray(c, i)
      else:
        lastValid = i
    of fsFinish:
      discard

  result = if lastValid >= 0: input[0 .. lastValid] else: ""
  for i in countdown(stack.high, 0):
    case stack[i]
    of fsString:
      result.add '"'
    of fsObjectKey, fsObjectKeyEscape, fsObjectKeyUnicode,
        fsObjectAfterKey, fsObjectAfterComma, fsObjectStart,
        fsObjectBeforeValue, fsObjectAfterValue:
      result.add '}'
    of fsArrayStart, fsArrayAfterComma, fsArrayAfterValue:
      result.add ']'
    of fsLiteral:
      let partial = input[literalStart .. ^1]
      if "true".startsWith(partial):
        result.add "true"[partial.len .. ^1]
      elif "false".startsWith(partial):
        result.add "false"[partial.len .. ^1]
      elif "null".startsWith(partial):
        result.add "null"[partial.len .. ^1]
    else: discard

proc jsonLead(s: string): string =
  ## From the first `{` or `[` so fences and prose do not break `fixJson`.
  for i, c in s:
    if c in {'{', '['}: return s[i .. ^1]
  ""

proc parsePartialJson*(s: string): tuple[value: JsonNode, state: PartialParse] =
  ## Parse complete JSON, or a repaired prefix (AI SDK `parsePartialJson`).
  if s.len == 0:
    return (nil, ppUndefined)
  let fenced = stripFence(s)
  try:
    return (parseJson(fenced), ppSuccess)
  except CatchableError:
    discard
  let src = jsonLead(fenced)
  if src.len == 0:
    return (nil, ppUndefined)
  try:
    return (parseJson(src), ppSuccess)
  except CatchableError:
    discard
  try:
    return (parseJson(fixJson(src)), ppRepaired)
  except CatchableError:
    discard
  (nil, ppFailed)
