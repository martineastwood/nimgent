## JSON Schema derivation, extraction, and a small validator.
##
## ponytail: draft-07 subset used by generateObject — type, properties, required,
## items, enum, const, min/max, minLength/maxLength, minItems/maxItems,
## additionalProperties, anyOf/oneOf/allOf, non-cyclic local refs, patterns,
## and common bounds.
## `validateJsonSchema` rejects malformed keywords and unsupported constructs
## before a request is sent.

import std/[json, macros, math, re, strutils, unicode]

## Optional field annotations understood by `jsonSchema`.  They are declared
## as pragmas so they can be used directly on object fields without generating
## runtime code.
template jsonDescription*(value: static[string]) {.pragma.}
template jsonMinimum*(value: static[int]) {.pragma.}
template jsonMaximum*(value: static[int]) {.pragma.}
template jsonMinLength*(value: static[int]) {.pragma.}
template jsonMaxLength*(value: static[int]) {.pragma.}
template jsonMinItems*(value: static[int]) {.pragma.}
template jsonMaxItems*(value: static[int]) {.pragma.}
template jsonPattern*(value: static[string]) {.pragma.}
template jsonOptional*() {.pragma.}

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
      if c == '"':
        discard stack.pop()
        stack.add fsObjectAfterKey
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
    of fsObjectKey, fsObjectAfterKey, fsObjectAfterComma, fsObjectStart,
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

proc pathField(path, key: string): string =
  path & "." & key

proc pathIndex(path: string, i: int): string =
  path & "[" & $i & "]"

proc jsonKindName(n: JsonNode): string
proc resolvePointer(root: JsonNode, refPath: string): JsonNode

proc schemaValueKind(n: JsonNode): string =
  if n.isNil: return "missing"
  jsonKindName(n)

proc validSchemaType(name: string): bool =
  name in ["null", "boolean", "object", "array", "number", "integer", "string"]

proc validateSchemaNode(n: JsonNode, path: string, root: JsonNode): seq[string]

proc validateSchemaArray(n: JsonNode, key, path: string, root: JsonNode): seq[string] =
  if n.isNil or n.kind != JArray:
    return @[pathField(path, key) & ": expected array, got " & schemaValueKind(n)]
  if n.len == 0:
    result.add pathField(path, key) & ": expected a non-empty array"
  for i in 0 ..< n.len:
    result.add validateSchemaNode(n[i], pathIndex(pathField(path, key), i), root)

proc validateSchemaNode(n: JsonNode, path: string, root: JsonNode): seq[string] =
  if n.isNil:
    return @[path & ": expected schema object, got " & schemaValueKind(n)]
  if n.kind == JBool: return
  if n.kind != JObject:
    return @[path & ": expected schema object, got " & schemaValueKind(n)]

  if "$ref" in n:
    let refNode = n["$ref"]
    if refNode.isNil or refNode.kind != JString:
      result.add path & ".$ref: expected string, got " & schemaValueKind(refNode)
    elif not refNode.getStr.startsWith("#"):
      result.add path & ".$ref: external references are not supported"
    elif resolvePointer(root, refNode.getStr).isNil:
      result.add path & ".$ref: unresolved reference " & refNode.getStr
  for key in ["format", "dependencies", "prefixItems", "dependentRequired",
              "dependentSchemas", "unevaluatedProperties", "unevaluatedItems"]:
    if key in n:
      result.add path & "." & key & ": unsupported"

  for key in ["$defs", "definitions"]:
    if key in n:
      let defs = n[key]
      if defs.isNil or defs.kind != JObject:
        result.add path & "." & key & ": expected object, got " & schemaValueKind(defs)
      else:
        for name, sub in defs:
          result.add validateSchemaNode(sub, pathField(pathField(path, key), name), root)

  if "type" in n:
    let t = n["type"]
    if t.isNil:
      result.add path & ".type: expected string or array, got missing"
    else:
      case t.kind
      of JString:
        if not validSchemaType(t.getStr):
          result.add path & ".type: unknown type " & t.getStr
      of JArray:
        if t.len == 0:
          result.add path & ".type: expected a non-empty array"
        for item in t:
          if item.isNil or item.kind != JString:
            result.add path & ".type: expected strings, got " & schemaValueKind(item)
          elif not validSchemaType(item.getStr):
            result.add path & ".type: unknown type " & item.getStr
      else:
        result.add path & ".type: expected string or array, got " & jsonKindName(t)

  if "properties" in n:
    let props = n["properties"]
    if props.isNil or props.kind != JObject:
      result.add path & ".properties: expected object, got " & schemaValueKind(props)
    else:
      for key, sub in props:
        result.add validateSchemaNode(sub, pathField(pathField(path, "properties"), key), root)

  if "required" in n:
    let required = n["required"]
    if required.isNil or required.kind != JArray:
      result.add path & ".required: expected array, got " & schemaValueKind(required)
    else:
      if required.len == 0:
        result.add path & ".required: expected a non-empty array"
      var seen: seq[string] = @[]
      for item in required:
        if item.isNil or item.kind != JString:
          result.add path & ".required: expected strings, got " & schemaValueKind(item)
        elif item.getStr in seen:
          result.add path & ".required: duplicate property " & item.getStr
        else:
          seen.add item.getStr

  if "additionalProperties" in n:
    let extra = n["additionalProperties"]
    if not extra.isNil and extra.kind == JObject:
      result.add validateSchemaNode(extra, path & ".additionalProperties", root)
    elif extra.isNil or extra.kind != JBool:
      result.add path & ".additionalProperties: expected boolean or schema object, got " &
        schemaValueKind(extra)

  if "items" in n:
    let items = n["items"]
    if items.isNil or items.kind notin {JObject, JArray, JBool}:
      result.add path & ".items: expected schema or schema array, got " & schemaValueKind(items)
    elif items.kind == JArray:
      for i in 0 ..< items.len:
        result.add validateSchemaNode(items[i], pathIndex(path & ".items", i), root)
    elif items.kind == JObject:
      result.add validateSchemaNode(items, path & ".items", root)

  for key in ["anyOf", "oneOf", "allOf"]:
    if key in n:
      result.add validateSchemaArray(n[key], key, path, root)

  if "additionalItems" in n:
    let extra = n["additionalItems"]
    if extra.isNil or extra.kind notin {JObject, JBool}:
      result.add path & ".additionalItems: expected boolean or schema object, got " &
        schemaValueKind(extra)

  if "enum" in n:
    let enumerated = n["enum"]
    if enumerated.isNil or enumerated.kind != JArray:
      result.add path & ".enum: expected array, got " & schemaValueKind(enumerated)
    elif enumerated.len == 0:
      result.add path & ".enum: expected a non-empty array"

  for key in ["minimum", "maximum"]:
    if key in n and (n[key].isNil or n[key].kind notin {JInt, JFloat}):
      result.add path & "." & key & ": expected number, got " & schemaValueKind(n[key])

  for key in ["exclusiveMinimum", "exclusiveMaximum", "multipleOf"]:
    if key in n:
      if n[key].isNil or n[key].kind notin {JInt, JFloat}:
        result.add path & "." & key & ": expected number, got " & schemaValueKind(n[key])
      elif key == "multipleOf" and n[key].getFloat <= 0:
        result.add path & ".multipleOf: expected a positive number"

  for key in ["minLength", "maxLength", "minItems", "maxItems"]:
    if key in n:
      if n[key].isNil or n[key].kind != JInt:
        result.add path & "." & key & ": expected integer, got " & schemaValueKind(n[key])
      elif n[key].getInt < 0:
        result.add path & "." & key & ": expected non-negative integer"

  if "minProperties" in n or "maxProperties" in n:
    for key in ["minProperties", "maxProperties"]:
      if key in n:
        if n[key].isNil or n[key].kind != JInt:
          result.add path & "." & key & ": expected integer, got " & schemaValueKind(n[key])
        elif n[key].getInt < 0:
          result.add path & "." & key & ": expected non-negative integer"

  if "uniqueItems" in n and (n["uniqueItems"].isNil or n["uniqueItems"].kind != JBool):
    result.add path & ".uniqueItems: expected boolean, got " & schemaValueKind(n["uniqueItems"])

  if "pattern" in n:
    let pattern = n["pattern"]
    if pattern.isNil or pattern.kind != JString:
      result.add path & ".pattern: expected string, got " & schemaValueKind(pattern)
    else:
      try:
        discard re(pattern.getStr)
      except CatchableError as e:
        result.add path & ".pattern: invalid regular expression: " & e.msg

  for key in ["not", "if", "then", "else", "contains", "propertyNames"]:
    if key in n:
      result.add validateSchemaNode(n[key], path & "." & key, root)

  if "patternProperties" in n:
    let patterns = n["patternProperties"]
    if patterns.isNil or patterns.kind != JObject:
      result.add path & ".patternProperties: expected object, got " & schemaValueKind(patterns)
    else:
      for pattern, sub in patterns:
        try:
          discard re(pattern)
        except CatchableError as e:
          result.add path & ".patternProperties." & pattern & ": invalid regular expression: " & e.msg
        result.add validateSchemaNode(sub, pathField(pathField(path, "patternProperties"), pattern), root)

proc validateJsonSchema*(schema: JsonNode, path = "$"): seq[string] =
  ## Validate the supported draft-07 subset before making a provider request.
  validateSchemaNode(schema, path, schema)

proc typeNames(schema: JsonNode): seq[string] =
  if schema.isNil or schema.kind != JObject or "type" notin schema:
    return
  let t = schema["type"]
  if t.kind == JString:
    result.add t.getStr
  elif t.kind == JArray:
    for x in t:
      if x.kind == JString: result.add x.getStr

proc jsonKindName(n: JsonNode): string =
  case n.kind
  of JNull: "null"
  of JBool: "boolean"
  of JInt: "integer"
  of JFloat: "number"
  of JString: "string"
  of JObject: "object"
  of JArray: "array"

proc isWholeFloat(n: JsonNode): bool =
  n.kind == JFloat and n.getFloat == n.getFloat.trunc and
    n.getFloat >= int64.low.float and n.getFloat <= int64.high.float

proc matchesType(value: JsonNode, names: openArray[string]): bool =
  if names.len == 0: return true
  let got = jsonKindName(value)
  for n in names:
    if n == got: return true
    if n == "number" and value.kind == JInt: return true
    if n == "integer" and isWholeFloat(value): return true
  false

proc jsonEqual*(a, b: JsonNode): bool =
  if a.isNil or b.isNil: return a.isNil and b.isNil
  if a.kind != b.kind:
    if a.kind == JInt and isWholeFloat(b): return a.getInt.float == b.getFloat
    if b.kind == JInt and isWholeFloat(a): return b.getInt.float == a.getFloat
    return false
  case a.kind
  of JNull: true
  of JBool: a.getBool == b.getBool
  of JInt: a.getInt == b.getInt
  of JFloat: a.getFloat == b.getFloat
  of JString: a.getStr == b.getStr
  of JArray:
    if a.len != b.len: return false
    for i in 0 ..< a.len:
      if not jsonEqual(a[i], b[i]): return false
    true
  of JObject:
    if a.len != b.len: return false
    for k, v in a:
      if k notin b or not jsonEqual(v, b[k]): return false
    true

proc pointerToken(s: string): string =
  result = s.replace("~1", "/").replace("~0", "~")

proc resolvePointer(root: JsonNode, refPath: string): JsonNode =
  if refPath == "#": return root
  if refPath.len < 3 or not refPath.startsWith("#/"): return nil
  result = root
  for token in refPath[2 .. ^1].split('/'):
    if result.isNil: return nil
    let key = pointerToken(token)
    case result.kind
    of JObject:
      if key notin result: return nil
      result = result[key]
    of JArray:
      try:
        let i = parseInt(key)
        if i < 0 or i >= result.len: return nil
        result = result[i]
      except ValueError:
        return nil
    else:
      return nil

proc numberValue(n: JsonNode): float =
  if n.kind == JInt: n.getInt.float else: n.getFloat

proc isMultiple(value, divisor: float): bool =
  if divisor <= 0: return false
  let quotient = value / divisor
  abs(quotient - quotient.round) <= 1e-9

proc matchesPattern(value, pattern: string): bool =
  value.find(re(pattern)) >= 0

proc schemaRef(schema, root: JsonNode, path: string,
               refs: seq[string]): tuple[target: JsonNode, issue: string,
                                          refs: seq[string]] =
  if "$ref" notin schema: return (schema, "", refs)
  let refNode = schema["$ref"]
  if refNode.isNil or refNode.kind != JString:
    return (nil, path & ".$ref: expected string, got " & schemaValueKind(refNode), refs)
  let refPath = refNode.getStr
  if not refPath.startsWith("#"):
    return (nil, path & ".$ref: external references are not supported", refs)
  if refPath in refs:
    return (nil, path & ".$ref: cyclic reference " & refPath, refs)
  let target = resolvePointer(root, refPath)
  if target.isNil:
    return (nil, path & ".$ref: unresolved reference " & refPath, refs)
  (target, "", refs & refPath)

proc validateSchemaAt(value, schema: JsonNode, path: string,
                      root: JsonNode, refs: seq[string]): seq[string] =
  ## Empty means `value` satisfies `schema`.
  if schema.isNil:
    return @[path & ": missing schema"]
  if schema.kind == JBool:
    if not schema.getBool:
      return @[path & ": schema is false"]
    return
  if schema.kind != JObject:
    return @[path & ": expected schema object, got " & jsonKindName(schema)]
  let resolved = schemaRef(schema, root, path, refs)
  if resolved.issue.len > 0:
    return @[resolved.issue]
  if "$ref" in schema:
    return validateSchemaAt(value, resolved.target, path, root, resolved.refs)
  if value.isNil:
    return @[path & ": missing value"]
  if "const" in schema and not jsonEqual(value, schema["const"]):
    result.add path & ": expected " & $schema["const"]
  if "enum" in schema and schema["enum"].kind == JArray:
    var found = false
    for item in schema["enum"]:
      if jsonEqual(value, item):
        found = true
        break
    if not found:
      result.add path & ": expected one of " & $schema["enum"]
  let types = typeNames(schema)
  if types.len > 0 and not matchesType(value, types):
    result.add path & ": expected " & types.join("|") & ", got " & jsonKindName(value)
    return
  if "allOf" in schema:
    for sub in schema["allOf"]:
      result.add validateSchemaAt(value, sub, path, root, refs)
  if "anyOf" in schema and schema["anyOf"].kind == JArray:
    var ok = false
    for sub in schema["anyOf"]:
      if validateSchemaAt(value, sub, path, root, refs).len == 0:
        ok = true
        break
    if not ok:
      result.add path & ": matched none of anyOf"
  if "oneOf" in schema and schema["oneOf"].kind == JArray:
    var hits = 0
    for sub in schema["oneOf"]:
      if validateSchemaAt(value, sub, path, root, refs).len == 0: inc hits
    if hits != 1:
      result.add path & ": expected exactly one of oneOf, got " & $hits
  if value.kind == JString:
    let n = value.getStr.runeLen
    if "minLength" in schema and n < schema["minLength"].getInt:
      result.add path & ": shorter than minLength " & $schema["minLength"].getInt
    if "maxLength" in schema and n > schema["maxLength"].getInt:
      result.add path & ": longer than maxLength " & $schema["maxLength"].getInt
    if "pattern" in schema:
      try:
        if not matchesPattern(value.getStr, schema["pattern"].getStr):
          result.add path & ": does not match pattern " & schema["pattern"].getStr
      except CatchableError:
        result.add path & ": invalid pattern"
  if value.kind in {JInt, JFloat}:
    let x = numberValue(value)
    if "minimum" in schema and x < schema["minimum"].getFloat:
      result.add path & ": below minimum " & $schema["minimum"]
    if "maximum" in schema and x > schema["maximum"].getFloat:
      result.add path & ": above maximum " & $schema["maximum"]
    if "exclusiveMinimum" in schema and x <= numberValue(schema["exclusiveMinimum"]):
      result.add path & ": not above exclusiveMinimum " & $schema["exclusiveMinimum"]
    if "exclusiveMaximum" in schema and x >= numberValue(schema["exclusiveMaximum"]):
      result.add path & ": not below exclusiveMaximum " & $schema["exclusiveMaximum"]
    if "multipleOf" in schema and not isMultiple(x, numberValue(schema["multipleOf"])):
      result.add path & ": not a multiple of " & $schema["multipleOf"]
  if value.kind == JArray:
    if "minItems" in schema and value.len < schema["minItems"].getInt:
      result.add path & ": fewer than minItems " & $schema["minItems"].getInt
    if "maxItems" in schema and value.len > schema["maxItems"].getInt:
      result.add path & ": more than maxItems " & $schema["maxItems"].getInt
    if "items" in schema:
      let items = schema["items"]
      if items.kind == JArray:
        for i in 0 ..< value.len:
          if i < items.len:
            result.add validateSchemaAt(value[i], items[i], pathIndex(path, i), root, refs)
          elif "additionalItems" in schema:
            let extra = schema["additionalItems"]
            if extra.kind == JBool and not extra.getBool:
              result.add pathIndex(path, i) & ": additional item not allowed"
            elif extra.kind == JObject:
              result.add validateSchemaAt(value[i], extra, pathIndex(path, i), root, refs)
      else:
        for i in 0 ..< value.len:
          result.add validateSchemaAt(value[i], items, pathIndex(path, i), root, refs)
    if "uniqueItems" in schema and schema["uniqueItems"].getBool:
      for i in 0 ..< value.len:
        for j in i + 1 ..< value.len:
          if jsonEqual(value[i], value[j]):
            result.add path & ": duplicate items at indexes " & $i & " and " & $j
  if value.kind == JObject:
    var props: JsonNode = nil
    if "properties" in schema: props = schema["properties"]
    if "required" in schema:
      for req in schema["required"]:
        if req.kind == JString and req.getStr notin value:
          result.add pathField(path, req.getStr) & ": required"
    if "minProperties" in schema and value.len < schema["minProperties"].getInt:
      result.add path & ": fewer than minProperties " & $schema["minProperties"].getInt
    if "maxProperties" in schema and value.len > schema["maxProperties"].getInt:
      result.add path & ": more than maxProperties " & $schema["maxProperties"].getInt
    for k, v in value:
      var matched = false
      if not props.isNil and props.kind == JObject and k in props:
        matched = true
        result.add validateSchemaAt(v, props[k], pathField(path, k), root, refs)
      if "patternProperties" in schema:
        for pattern, sub in schema["patternProperties"]:
          try:
            if matchesPattern(k, pattern):
              matched = true
              result.add validateSchemaAt(v, sub, pathField(path, k), root, refs)
          except CatchableError:
            discard
      if not matched and "additionalProperties" in schema:
        let extra = schema["additionalProperties"]
        if extra.kind == JBool and not extra.getBool:
          result.add pathField(path, k) & ": unexpected property"
        elif extra.kind == JObject:
          result.add validateSchemaAt(v, extra, pathField(path, k), root, refs)
      if "propertyNames" in schema:
        result.add validateSchemaAt(%k, schema["propertyNames"],
          pathField(path, k), root, refs)

  if "not" in schema and validateSchemaAt(value, schema["not"], path, root, refs).len == 0:
    result.add path & ": matched forbidden not schema"
  if value.kind == JArray and "contains" in schema:
    var found = false
    for item in value:
      if validateSchemaAt(item, schema["contains"], path, root, refs).len == 0:
        found = true
        break
    if not found:
      result.add path & ": contains no matching item"
  if "if" in schema:
    let condition = validateSchemaAt(value, schema["if"], path, root, refs).len == 0
    if condition and "then" in schema:
      result.add validateSchemaAt(value, schema["then"], path, root, refs)
    elif not condition and "else" in schema:
      result.add validateSchemaAt(value, schema["else"], path, root, refs)

proc validateSchema*(value, schema: JsonNode, path = "$"): seq[string] =
  validateSchemaAt(value, schema, path, schema, @[])

proc prepareWireSchema*(schema: JsonNode): JsonNode =
  ## Copy. Objects without additionalProperties get false (OpenAI/Anthropic strict).
  proc walk(n: JsonNode) =
    if n.isNil or n.kind != JObject: return
    if n.getOrDefault("type").getStr == "object" or "properties" in n:
      if "additionalProperties" notin n:
        n["additionalProperties"] = %false
    if "properties" in n and n["properties"].kind == JObject:
      for _, v in n["properties"]: walk(v)
    if "items" in n:
      if n["items"].kind == JObject:
        walk(n["items"])
      elif n["items"].kind == JArray:
        for v in n["items"]: walk(v)
    if "additionalProperties" in n and not n["additionalProperties"].isNil and
        n["additionalProperties"].kind == JObject:
      walk(n["additionalProperties"])
    for key in ["$defs", "definitions"]:
      if key in n and not n[key].isNil and n[key].kind == JObject:
        for _, v in n[key]: walk(v)
    for key in ["not", "if", "then", "else", "contains", "propertyNames"]:
      if key in n: walk(n[key])
    if "patternProperties" in n and not n["patternProperties"].isNil and
        n["patternProperties"].kind == JObject:
      for _, v in n["patternProperties"]: walk(v)
    for key in ["anyOf", "oneOf", "allOf"]:
      if key in n and n[key].kind == JArray:
        for v in n[key]: walk(v)
  result = copy(schema)
  walk(result)

proc schemaName*(s: string): string =
  ## OpenAI structured-output names: `[a-zA-Z0-9_-]+`.
  if s.len == 0: return "object"
  for c in s:
    if c.isAlphaNumeric or c in {'_', '-'}: result.add c
    else: result.add '_'
  if result[0] notin {'A'..'Z', 'a'..'z'}:
    result = "n" & result

proc typeLeafName(n: NimNode): string =
  case n.kind
  of nnkDotExpr: $n[^1]
  of nnkSym, nnkIdent: n.strVal
  else: $n

type FieldMeta = object
  optional: bool
  constraints: JsonNode

type GenericBinding = object
  name: string
  value: NimNode

proc schemaFromType(t: NimNode, bindings: seq[GenericBinding]): JsonNode
proc schemaFromType(t: NimNode): JsonNode = schemaFromType(t, @[])

proc genericParamName(n: NimNode): string =
  var param = n
  if param.kind == nnkIdentDefs and param.len > 0:
    param = param[0]
  if param.kind == nnkPragmaExpr and param.len > 0:
    param = param[0]
  if param.kind == nnkPostfix and param.len > 1:
    param = param[1]
  if param.kind in {nnkSym, nnkIdent}:
    return param.strVal
  typeLeafName(param)

proc genericParamNames(params: NimNode): seq[string] =
  for param in params:
    if param.kind == nnkIdentDefs:
      for i in 0 ..< param.len - 2:
        result.add genericParamName(param[i])
    else:
      result.add genericParamName(param)

proc substituteType(n: NimNode, bindings: seq[GenericBinding]): NimNode =
  if n.isNil: return n
  if n.kind in {nnkSym, nnkIdent}:
    for binding in bindings:
      if n.strVal == binding.name:
        return binding.value
  result = copyNimNode(n)
  for child in n:
    result.add substituteType(child, bindings)

proc pragmaNumber(n: NimNode): JsonNode =
  case n.kind
  of nnkIntLit, nnkUIntLit:
    %n.intVal
  of nnkFloatLit:
    %n.floatVal
  else:
    nil

proc fieldMeta(n: NimNode): FieldMeta =
  result.constraints = newJObject()
  if n.kind != nnkPragmaExpr or n.len < 2: return
  let pragmas = n[1]
  for pragma in pragmas:
    var name = ""
    var arg: NimNode = nil
    if pragma.kind == nnkCall:
      name = typeLeafName(pragma[0])
      if pragma.len > 1: arg = pragma[1]
    else:
      name = typeLeafName(pragma)
    case name
    of "jsonOptional":
      result.optional = true
    of "jsonDescription", "jsonPattern":
      if not arg.isNil and arg.kind in {nnkStrLit, nnkRStrLit, nnkTripleStrLit}:
        let key = if name == "jsonDescription": "description" else: "pattern"
        result.constraints[key] = %arg.strVal
    of "jsonMinimum", "jsonMaximum", "jsonMinLength", "jsonMaxLength",
       "jsonMinItems", "jsonMaxItems":
      if not arg.isNil:
        let value = pragmaNumber(arg)
        if not value.isNil:
          let key = case name
            of "jsonMinimum": "minimum"
            of "jsonMaximum": "maximum"
            of "jsonMinLength": "minLength"
            of "jsonMaxLength": "maxLength"
            of "jsonMinItems": "minItems"
            else: "maxItems"
          result.constraints[key] = value

proc mergeObjectSchema(dest, base: JsonNode) =
  if base.isNil or base.kind != JObject: return
  if "properties" in base and base["properties"].kind == JObject:
    for key, value in base["properties"]:
      dest["properties"][key] = copy(value)
  if "required" in base and base["required"].kind == JArray:
    for key in base["required"]:
      var present = false
      for existing in dest["required"]:
        if jsonEqual(existing, key):
          present = true
          break
      if not present:
        dest["required"].add copy(key)

proc addRequired(schema: JsonNode, key: string) =
  for existing in schema["required"]:
    if existing.kind == JString and existing.getStr == key:
      return
  schema["required"].add %key

proc addRecordFields(schema: JsonNode, rec: NimNode, requireFields = true,
                     bindings: seq[GenericBinding] = @[])

proc addField(schema: JsonNode, identDef: NimNode, requireField = true,
              bindings: seq[GenericBinding] = @[]) =
  if identDef.kind != nnkIdentDefs or identDef.len < 3: return
  let ftype = identDef[^2]
  for i in 0 ..< identDef.len - 2:
    let original = identDef[i]
    var fname = original
    if fname.kind == nnkPragmaExpr: fname = fname[0]
    if fname.kind == nnkPostfix: fname = fname[1]
    let key = $fname
    var fieldSchema = schemaFromType(substituteType(ftype, bindings))
    let meta = fieldMeta(original)
    for constraint, value in meta.constraints:
      fieldSchema[constraint] = value
    schema["properties"][key] = fieldSchema
    if requireField and not meta.optional:
      addRequired(schema, key)

proc branchLabel(n: NimNode): JsonNode =
  case n.kind
  of nnkIntLit, nnkUIntLit:
    %n.intVal
  of nnkStrLit, nnkRStrLit, nnkTripleStrLit:
    %n.strVal
  else:
    %($n)

proc addRecordFields(schema: JsonNode, rec: NimNode, requireFields = true,
                     bindings: seq[GenericBinding] = @[]) =
  case rec.kind
  of nnkRecList:
    for field in rec:
      if field.kind == nnkIdentDefs:
        addField(schema, field, requireFields, bindings)
      elif field.kind == nnkRecCase:
        addRecordFields(schema, field, requireFields, bindings)
  of nnkRecCase:
    var discriminator = ""
    if rec.len > 0 and rec[0].kind == nnkIdentDefs:
      addField(schema, rec[0], requireFields, bindings)
      if rec[0].len >= 3:
        var discriminatorNode = rec[0][0]
        if discriminatorNode.kind == nnkPragmaExpr:
          discriminatorNode = discriminatorNode[0]
        if discriminatorNode.kind == nnkPostfix:
          discriminatorNode = discriminatorNode[1]
        discriminator = $discriminatorNode
    var variants = newJArray()
    for i in 1 ..< rec.len:
      let branch = rec[i]
      if branch.kind notin {nnkOfBranch, nnkElifBranch, nnkElse} or
          branch.len == 0:
        continue
      let branchRec = branch[^1]
      ## Keep branch fields in the parent property set, but make their
      ## conditional requirement explicit in a oneOf branch.
      addRecordFields(schema, branchRec, false, bindings)
      if discriminator.len == 0:
        continue
      var variant = %*{
        "type": "object",
        "additionalProperties": false,
        "properties": newJObject(),
        "required": newJArray()
      }
      if branch.kind != nnkElse:
        var labels = newJArray()
        for labelIndex in 0 ..< branch.len - 1:
          labels.add branchLabel(branch[labelIndex])
        if labels.len == 1:
          variant["properties"][discriminator] = %*{"const": labels[0]}
        else:
          variant["properties"][discriminator] = %*{"enum": labels}
        addRequired(variant, discriminator)
      addRecordFields(variant, branchRec, true, bindings)
      if variant["required"].len == 0:
        variant.delete("required")
      variants.add variant
    if requireFields and variants.len > 0:
      schema["oneOf"] = variants
  of nnkOfBranch, nnkElifBranch, nnkElse:
    if rec.len > 0:
      addRecordFields(schema, rec[^1], requireFields, bindings)
  else:
    discard

proc unwrapType(t: NimNode): NimNode =
  result = t
  var impl = getTypeImpl(result)
  if impl.kind == nnkRefTy:
    result = impl[0]
    impl = getTypeImpl(result)
  if impl.kind == nnkDistinctTy:
    result = impl[0]

proc schemaFromType(t: NimNode, bindings: seq[GenericBinding]): JsonNode =
  let inst = getTypeInst(t)
  if inst.kind == nnkBracketExpr:
    let ctor = typeLeafName(inst[0])
    if ctor in ["seq", "openArray"]:
      return %*{"type": "array", "items": schemaFromType(inst[1])}
    if ctor == "array" and inst.len >= 3:
      result = %*{"type": "array", "items": schemaFromType(inst[^1])}
      let bound = inst[1]
      if bound.kind == nnkIntLit:
        result["minItems"] = %bound.intVal
        result["maxItems"] = %bound.intVal
      elif bound.kind == nnkInfix and $bound[0] == ".." and bound.len >= 3 and
          bound[1].kind == nnkIntLit and bound[2].kind == nnkIntLit:
        let count = bound[2].intVal - bound[1].intVal + 1
        result["minItems"] = %count
        result["maxItems"] = %count
      return
    if ctor in ["set", "HashSet", "OrderedSet"] and inst.len >= 2:
      return %*{"type": "array", "items": schemaFromType(inst[1]),
        "uniqueItems": true}
    if ctor in ["Table", "OrderedTable", "CountTable"] and inst.len >= 3:
      return %*{"type": "object", "additionalProperties": schemaFromType(inst[2])}
    if ctor == "Option":
      result = schemaFromType(inst[1])
      var types = newJArray()
      if "type" in result and result["type"].kind == JString:
        types.add result["type"]
        types.add %"null"
        result["type"] = types
      return
  let core = unwrapType(t)
  let impl = getTypeImpl(core)
  if impl.kind == nnkBracketExpr and impl.len >= 3:
    let ctor = typeLeafName(impl[0])
    if ctor == "array":
      result = %*{"type": "array", "items": schemaFromType(impl[^1])}
      let bound = impl[1]
      if bound.kind == nnkInfix and $bound[0] == ".." and bound.len >= 3 and
          bound[1].kind == nnkIntLit and bound[2].kind == nnkIntLit:
        let count = bound[2].intVal - bound[1].intVal + 1
        result["minItems"] = %count
        result["maxItems"] = %count
      return
  case impl.kind
  of nnkObjectTy:
    result = %*{
      "type": "object",
      "additionalProperties": false,
      "properties": newJObject(),
      "required": newJArray()
    }
    var source = impl
    var activeBindings = bindings
    if activeBindings.len == 0 and inst.kind == nnkBracketExpr and inst.len > 1:
      try:
        let genericDef = getImpl(inst[0])
        if genericDef.kind == nnkTypeDef and genericDef.len > 1 and
            genericDef[1].kind == nnkGenericParams:
          let params = genericDef[1]
          let names = genericParamNames(params)
          for i in 0 ..< min(names.len, inst.len - 1):
            activeBindings.add GenericBinding(name: names[i], value: inst[i + 1])
      except CatchableError:
        discard
    try:
      let definition = getImpl(core)
      if definition.kind == nnkTypeDef and definition.len > 0:
        source = definition[^1]
    except CatchableError:
      discard
    if source.kind == nnkObjectTy and source.len > 1 and
        source[1].kind == nnkOfInherit and source[1].len > 0:
      let base = source[1][0]
      let baseName = if base.kind == nnkBracketExpr: typeLeafName(base[0])
                     else: typeLeafName(base)
      if baseName notin ["RootObj", "RootRef"]:
        var baseType = base
        var baseBindings: seq[GenericBinding] = activeBindings
        if base.kind == nnkBracketExpr and base.len > 1:
          baseType = base[0]
          try:
            let genericDef = getImpl(base[0])
            if genericDef.kind == nnkTypeDef and genericDef.len > 1 and
                genericDef[1].kind == nnkGenericParams:
              let params = genericDef[1]
              let names = genericParamNames(params)
              baseBindings = @[]
              for i in 0 ..< min(names.len, base.len - 1):
                baseBindings.add GenericBinding(name: names[i],
                  value: substituteType(base[i + 1], activeBindings))
          except CatchableError:
            discard
        mergeObjectSchema(result, schemaFromType(baseType, baseBindings))
    let rec = if source.kind == nnkObjectTy and source.len > 2: source[2] else: impl[2]
    if rec.kind != nnkEmpty:
      addRecordFields(result, rec, true, activeBindings)
    if result["required"].len == 0:
      result.delete("required")
  of nnkEnumTy:
    var vals = newJArray()
    for i in 1 ..< impl.len:
      let f = impl[i]
      case f.kind
      of nnkEnumFieldDef:
        if f[1].kind in {nnkStrLit, nnkRStrLit}:
          vals.add %f[1].strVal
        else:
          vals.add %($f[0])
      of nnkSym: vals.add %($f)
      else: discard
    result = %*{"type": "string", "enum": vals}
  else:
    let name = typeLeafName(getTypeInst(core))
    case name
    of "string", "cstring": result = %*{"type": "string"}
    of "bool": result = %*{"type": "boolean"}
    of "int", "int8", "int16", "int32", "int64",
       "uint", "uint8", "uint16", "uint32", "uint64", "byte", "BiggestInt":
      result = %*{"type": "integer"}
    of "float", "float32", "float64", "BiggestFloat":
      result = %*{"type": "number"}
    else:
      error("jsonSchema: unsupported type " & name, t)

macro jsonSchema*(T: typedesc): JsonNode =
  ## JSON Schema for Nim objects, variants, containers, generics, enums, and
  ## primitives. Field pragmas add constraints or make a property optional.
  ## Option fields stay in `required` as `[T, null]` (OpenAI strict).
  let impl = T.getType
  let t = if impl.kind == nnkBracketExpr and impl.len >= 2: impl[1] else: T
  let s = $schemaFromType(t)
  result = newCall(bindSym"parseJson", newLit(s))
