## JSON Schema shape validation, value validation, local references, and wire
## preparation for strict structured-output providers.

import std/[json, math, re, strutils, unicode]

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

proc validateSchemaNode(n: JsonNode, path: string, root: JsonNode,
                        refs: seq[string] = @[]): seq[string]

type SchemaChild = object
  node: JsonNode
  path: string

proc schemaChildPaths(n: JsonNode, path: string): seq[SchemaChild] =
  if n.isNil or n.kind != JObject: return
  for key in ["$defs", "definitions"]:
    if key in n and not n[key].isNil and n[key].kind == JObject:
      for name, child in n[key]:
        result.add SchemaChild(node: child,
          path: pathField(pathField(path, key), name))
  if "properties" in n and n["properties"].kind == JObject:
    for name, child in n["properties"]:
      result.add SchemaChild(node: child,
        path: pathField(pathField(path, "properties"), name))
  if "additionalProperties" in n and not n["additionalProperties"].isNil and
      n["additionalProperties"].kind == JObject:
    result.add SchemaChild(node: n["additionalProperties"],
      path: path & ".additionalProperties")
  if "items" in n:
    if n["items"].kind == JObject:
      result.add SchemaChild(node: n["items"], path: path & ".items")
    elif n["items"].kind == JArray:
      for i in 0 ..< n["items"].len:
        result.add SchemaChild(node: n["items"][i],
          path: pathIndex(path & ".items", i))
  if "additionalItems" in n and not n["additionalItems"].isNil and
      n["additionalItems"].kind == JObject:
    result.add SchemaChild(node: n["additionalItems"],
      path: path & ".additionalItems")
  for key in ["anyOf", "oneOf", "allOf"]:
    if key in n and n[key].kind == JArray:
      for i in 0 ..< n[key].len:
        result.add SchemaChild(node: n[key][i],
          path: pathIndex(pathField(path, key), i))
  for key in ["not", "if", "then", "else", "contains", "propertyNames"]:
    if key in n:
      result.add SchemaChild(node: n[key], path: path & "." & key)
  if "patternProperties" in n and not n["patternProperties"].isNil and
      n["patternProperties"].kind == JObject:
    for pattern, child in n["patternProperties"]:
      result.add SchemaChild(node: child,
        path: pathField(pathField(path, "patternProperties"), pattern))

proc validateSchemaArray(n: JsonNode, key, path: string): seq[string] =
  if n.isNil or n.kind != JArray:
    return @[pathField(path, key) & ": expected array, got " & schemaValueKind(n)]
  if n.len == 0:
    result.add pathField(path, key) & ": expected a non-empty array"

proc validateSchemaNode(n: JsonNode, path: string, root: JsonNode,
                        refs: seq[string]): seq[string] =
  if n.isNil:
    return @[path & ": expected schema object, got " & schemaValueKind(n)]
  if n.kind == JBool: return
  if n.kind != JObject:
    return @[path & ": expected schema object, got " & schemaValueKind(n)]

  if "$ref" in n:
    let refNode = n["$ref"]
    if refNode.isNil or refNode.kind != JString:
      result.add path & ".$ref: expected string, got " & schemaValueKind(refNode)
    else:
      let refPath = refNode.getStr
      if not refPath.startsWith("#"):
        result.add path & ".$ref: external references are not supported"
      else:
        let target = resolvePointer(root, refPath)
        if target.isNil:
          result.add path & ".$ref: unresolved reference " & refPath
        elif refPath in refs:
          result.add path & ".$ref: cyclic reference " & refPath
        else:
          ## Follow local references during preflight as well as checking that
          ## they resolve. This keeps cyclic references from reaching a
          ## provider that cannot represent them.
          result.add validateSchemaNode(target, path & ".$ref", root,
            refs & refPath)

  for key in ["format", "dependencies", "prefixItems", "dependentRequired",
              "dependentSchemas", "unevaluatedProperties", "unevaluatedItems"]:
    if key in n:
      result.add path & "." & key & ": unsupported"

  for key in ["$defs", "definitions"]:
    if key in n:
      let defs = n[key]
      if defs.isNil or defs.kind != JObject:
        result.add path & "." & key & ": expected object, got " & schemaValueKind(defs)

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
    if extra.isNil or extra.kind notin {JBool, JObject}:
      result.add path & ".additionalProperties: expected boolean or schema object, got " &
        schemaValueKind(extra)

  if "items" in n:
    let items = n["items"]
    if items.isNil or items.kind notin {JObject, JArray, JBool}:
      result.add path & ".items: expected schema or schema array, got " & schemaValueKind(items)

  for key in ["anyOf", "oneOf", "allOf"]:
    if key in n:
      result.add validateSchemaArray(n[key], key, path)

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

  if "patternProperties" in n:
    let patterns = n["patternProperties"]
    if patterns.isNil or patterns.kind != JObject:
      result.add path & ".patternProperties: expected object, got " & schemaValueKind(patterns)
    else:
      for pattern, sub in patterns:
        try:
          discard re(pattern)
        except CatchableError as e:
          result.add path & ".patternProperties." & pattern &
            ": invalid regular expression: " & e.msg
        discard sub

  for child in schemaChildPaths(n, path):
    result.add validateSchemaNode(child.node, child.path, root, refs)

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

proc validateOpenAiStrictSchema*(schema: JsonNode): seq[string] =
  ## Restrictions imposed by OpenAI's strict structured-output dialect.
  if schema.isNil or schema.kind != JObject:
    return @["$: native structured output requires a root object schema"]
  var issues: seq[string]
  if schema.getOrDefault("type").kind != JString or
      schema.getOrDefault("type").getStr != "object":
    issues.add "$: native structured output requires type object at the root"

  proc walk(n: JsonNode, path: string) =
    if n.isNil or n.kind != JObject: return
    for key in ["oneOf", "allOf", "not", "if", "then", "else", "contains",
                "propertyNames"]:
      if key in n:
        issues.add pathField(path, key) &
          ": unsupported by native strict structured output"
    let objectLike = n.getOrDefault("type").getStr == "object" or
      "properties" in n
    if objectLike:
      let extra = n.getOrDefault("additionalProperties")
      if extra.isNil or extra.kind != JBool or extra.getBool:
        issues.add path & ".additionalProperties: native strict objects require false"
      let props = n.getOrDefault("properties")
      if props.kind == JObject:
        var required: seq[string]
        let requiredNode = n.getOrDefault("required")
        if requiredNode.kind == JArray:
          for item in requiredNode:
            if item.kind == JString: required.add item.getStr
        for key, _ in props:
          if key notin required:
            issues.add pathField(pathField(path, "properties"), key) &
              ": native strict output requires every property to be required"
    for child in schemaChildPaths(n, path):
      walk(child.node, child.path)

  walk(schema, "$")
  result = issues

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

proc isMultiple(value, divisor: JsonNode): bool =
  if value.kind == JInt and divisor.kind == JInt:
    return divisor.getInt > 0 and value.getInt mod divisor.getInt == 0
  let d = numberValue(divisor)
  if d <= 0: return false
  let quotient = numberValue(value) / d
  let tolerance = min(1e-9,
    8 * 2.220446049250313e-16 * max(1.0, abs(quotient)))
  abs(quotient - quotient.round) <= tolerance

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
    if "multipleOf" in schema and not isMultiple(value, schema["multipleOf"]):
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
    for child in schemaChildPaths(n, ""):
      walk(child.node)
  result = copy(schema)
  walk(result)
