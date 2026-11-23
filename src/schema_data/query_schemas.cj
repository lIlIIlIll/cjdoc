package cjdoc.schema_data

import std.collection.*
import yjson.*

// One declarative source of the `cjdoc.query-request/3` contract: the field
// schemas plus, per operation, the fields that operation actually honours and
// the identity-specific narrowing `get_symbol` applies. The published request
// schema and every MCP tool input schema are generated from this table, so a
// field can never be admitted by one surface and rejected by the other, and an
// operation can never silently ignore a field it declares.
//
// Admissibility uses only draft 2020-12 keywords with linear-time semantics
// (`propertyNames`, `enum`, `not`); no lookaround pattern is involved.
private let QUERY_REQUEST_DECLARATION = """
{
  "properties":{
    "schemaVersion":{"const":"cjdoc.query-request/3"},
    "operation":{"enum":["resolve_docs","search","get_symbol"]},
    "query":{"type":"string","maxLength":4096},
    "snapshotId":{"type":"string","minLength":1,"maxLength":256},
    "contextSnapshotId":{"type":"string","minLength":1,"maxLength":256},
    "contextModuleId":{"type":"string","minLength":1,"maxLength":16384},
    "documentSetId":{"type":"string","minLength":1,"maxLength":16384},
    "moduleId":{"type":"string","minLength":1,"maxLength":16384},
    "packageName":{"type":"string","minLength":1,"maxLength":16384},
    "kind":{"type":"string","minLength":1,"maxLength":128},
    "language":{"type":"string","minLength":1,"maxLength":64},
    "languageFallback":{"type":"boolean"},
    "audience":{"enum":["external","package","all"]},
    "target":{"type":"string","minLength":1,"maxLength":1024},
    "cfg":{"type":"string","minLength":1,"maxLength":16384},
    "cfgProfile":{"type":"string","minLength":1,"maxLength":16384},
    "apiVersion":{"type":"string","minLength":1,"maxLength":1024},
    "dependencyInstanceId":{"type":"string","minLength":1,"maxLength":16384},
    "library":{"type":"string","minLength":1,"maxLength":16384},
    "symbolId":{"type":"string","minLength":1,"maxLength":16384},
    "symbolKey":{"type":"string","minLength":1,"maxLength":16384},
    "pageId":{"type":"string","minLength":1,"maxLength":16384},
    "name":{"type":"string","minLength":1,"maxLength":16384},
    "qualifiedName":{"type":"string","minLength":1,"maxLength":16384},
    "parameterTypes":{"type":"array","maxItems":1024,"items":{"type":"string","maxLength":16384}},
    "genericArity":{"type":"integer","minimum":0,"maximum":1024},
    "limit":{"type":"integer","minimum":0,"maximum":100},
    "cursor":{"type":"string","minLength":1,"maxLength":1024},
    "preset":{"enum":["summary","call","reference"]},
    "sections":{"type":"array","minItems":1,"maxItems":11,"uniqueItems":true,"items":{"enum":["signature","parameters","returns","contracts","examples","description","relations","source","diagnostics","validation","diff"]}},
    "maxBytes":{"type":"integer","minimum":1024,"maximum":67108864},
    "relatedSnapshotIds":{"type":"array","maxItems":64,"uniqueItems":true,"items":{"type":"string","minLength":1,"maxLength":256}},
    "relations":{"type":"object","additionalProperties":false,"properties":{
      "direction":{"enum":["outgoing","incoming","both"]},
      "kinds":{"type":"array","maxItems":32,"uniqueItems":true,"items":{"type":"string","minLength":1,"maxLength":128}},
      "depth":{"type":"integer","minimum":0,"maximum":4},
      "limit":{"type":"integer","minimum":0,"maximum":100}
    }},
    "latest":{"type":"boolean"},"compatible":{"type":"boolean"},
    "mode":{"enum":["precise","discovery"]},
    "profile":{"enum":["full-ir","bounded-static"]},
    "filters":{"type":"array","maxItems":64,"items":{"type":"object","additionalProperties":false,
      "required":["field","op","value"],"properties":{
        "field":{},
        "op":{},
        "value":{"type":"string","minLength":1,"maxLength":16384}}}},
    "tags":{"type":"array","minItems":1,"maxItems":64,
      "items":{"type":"string","pattern":"^[A-Za-z0-9_-]{1,64}$","minLength":1,"maxLength":64}}
  },
  "globalFields":["schemaVersion","operation","snapshotId","language","languageFallback","audience","cfgProfile"],
  "operations":{
    "resolve_docs":{"fields":["query","contextSnapshotId","contextModuleId","dependencyInstanceId",
      "documentSetId","moduleId","packageName","apiVersion","library","target","cfg",
      "latest","compatible","limit","cursor","maxBytes"]},
    "search":{"fields":["query","symbolId","symbolKey","name","qualifiedName","parameterTypes",
      "genericArity","kind","moduleId","packageName","documentSetId","apiVersion","library",
      "dependencyInstanceId","target","cfg","latest","limit","cursor",
      "mode","profile","filters","tags"]},
    "get_symbol":{"fields":["moduleId","packageName","kind","documentSetId","apiVersion",
      "dependencyInstanceId","library","target","cfg"],
      "identities":{
        "symbolId":{
          "fields":["preset","sections","maxBytes","relations","relatedSnapshotIds","cursor","limit"],
          "presets":["summary","call","reference"],
          "sections":["signature","parameters","returns","contracts","examples","description",
            "relations","source","diagnostics","validation","diff"],
          "requiresRelationsSection":true},
        "symbolKey":{
          "fields":["preset","sections","maxBytes","relations","relatedSnapshotIds","cursor","limit"],
          "presets":["summary","call","reference"],
          "sections":["signature","parameters","returns","contracts","examples","description",
            "relations","source","diagnostics","validation","diff"],
          "requiresRelationsSection":true},
        "pageId":{"fields":["preset","sections","maxBytes"],
          "presets":["summary","reference"],
          "sections":["description","source","validation","diff"]}
      }}
  }
}
"""

private func querySearchFilterField(field: String, property: JsonNode,
    context: String): JsonObject {
    let row = JsonObject()
    row.put("field", JsonNode.string(field))
    row.put("property", property)
    row.put("context", JsonNode.string(context))
    row
}

internal func querySearchFilterFields(): JsonArray {
    let fields = JsonArray()
    fields.add(querySearchFilterField("name", JsonNode.string("name"), "canonical-or-exposure"))
    fields.add(querySearchFilterField("qualifiedName", JsonNode.string("qualifiedName"),
        "canonical-or-exposure"))
    fields.add(querySearchFilterField("owner", queryStringArray(["ownerName", "ownerQualifiedName"]),
        "entry"))
    fields.add(querySearchFilterField("param", JsonNode.string("parameterTypes"), "entry"))
    fields.add(querySearchFilterField("return", queryStringArray(["returnType", "returnCanonical"]),
        "entry"))
    fields.add(querySearchFilterField("package", JsonNode.string("packageName"), "canonical-or-exposure"))
    fields.add(querySearchFilterField("kind", JsonNode.string("kind"), "entry"))
    fields
}

internal func querySearchFilterOps(): JsonArray {
    let ops = JsonArray()
    let equality = JsonObject()
    equality.put("op", JsonNode.string("eq"))
    equality.put("primitive", JsonNode.string("exact_string_equal"))
    ops.add(equality)
    let contains = JsonObject()
    contains.put("op", JsonNode.string("contains"))
    contains.put("primitive", JsonNode.string("ascii_fold_contains"))
    ops.add(contains)
    ops
}

internal func queryDeclaration(): JsonObject {
    let declaration = JsonNode.parse(QUERY_REQUEST_DECLARATION).asObject()
    let properties = declaration.get("properties").getOrThrow().asObject()
    let filterProperties = properties.get("filters").getOrThrow().asObject()
        .get("items").getOrThrow().asObject().get("properties").getOrThrow().asObject()
    let filterFields = querySearchFilterFields()
    let fieldNames = ArrayList<String>()
    for (index in 0..filterFields.size()) {
        fieldNames.add(filterFields[index].asObject().get("field").getOrThrow().asString())
    }
    filterProperties.get("field").getOrThrow().asObject()
        .put("enum", queryStringArray(fieldNames.toArray()))
    let filterOps = querySearchFilterOps()
    let opNames = ArrayList<String>()
    for (index in 0..filterOps.size()) {
        opNames.add(filterOps[index].asObject().get("op").getOrThrow().asString())
    }
    filterProperties.get("op").getOrThrow().asObject()
        .put("enum", queryStringArray(opNames.toArray()))
    declaration
}

private func queryFieldArray(value: JsonObject, key: String): ArrayList<String> {
    let result = ArrayList<String>()
    match (value.get(key)) {
        case Some(node) =>
            let items = node.asArray()
            for (index in 0..items.size()) { result.add(items[index].asString()) }
        case None => ()
    }
    result
}

private func queryAddFields(target: ArrayList<String>, values: ArrayList<String>): Unit {
    for (value in values) { if (!target.contains(value)) { target.add(value) } }
}

private func queryEnumSchema(values: ArrayList<String>): JsonObject {
    let node = JsonObject()
    let array = JsonArray()
    for (value in values) { array.add(JsonNode.string(value)) }
    node.put("enum", array)
    node
}

/** `oneOf` entries that require exactly one named property. */
private func queryRequiredOneOf(values: ArrayList<String>): JsonArray {
    let array = JsonArray()
    for (value in values) {
        let entry = JsonObject()
        entry.put("required", queryStringArray([value]))
        array.add(entry)
    }
    array
}

private func queryStringArray(values: Array<String>): JsonArray {
    let array = JsonArray()
    for (value in values) { array.add(JsonNode.string(value)) }
    array
}

private func queryOperationSpec(declaration: JsonObject, operation: String): JsonObject {
    let operations = declaration.get("operations").getOrThrow().asObject()
    match (operations.get(operation)) {
        case Some(value) => value.asObject()
        case None => throw IllegalArgumentException("unknown documentation query operation")
    }
}

private func queryIdentityTable(spec: JsonObject): ?JsonObject {
    match (spec.get("identities")) {
        case Some(value) => Some(value.asObject())
        case None => Option<JsonObject>.None
    }
}

private func queryIdentityNames(spec: JsonObject): ArrayList<String> {
    let result = ArrayList<String>()
    match (queryIdentityTable(spec)) {
        case Some(table) => for (index in 0..table.size()) { result.add(table.nameAt(index)) }
        case None => ()
    }
    result
}

/**
 * Fields admitted under one immediate context: the global fields, the operation
 * fields, and then either every identity (operation level) or exactly one
 * identity with its own sections, presets and continuation fields.
 */
private func queryAdmittedFields(declaration: JsonObject, spec: JsonObject,
    identity!: String = ""): ArrayList<String> {
    let allowed = queryFieldArray(declaration, "globalFields")
    queryAddFields(allowed, queryFieldArray(spec, "fields"))
    match (queryIdentityTable(spec)) {
        case Some(table) =>
            if (identity.isEmpty()) {
                for (index in 0..table.size()) {
                    let name = table.nameAt(index)
                    allowed.add(name)
                    queryAddFields(allowed, queryFieldArray(table.valueAt(index).asObject(), "fields"))
                }
            } else {
                allowed.add(identity)
                queryAddFields(allowed, queryFieldArray(table.get(identity).getOrThrow().asObject(),
                    "fields"))
            }
        case None => ()
    }
    allowed
}

private func queryDrop(allowed: ArrayList<String>, removed: Array<String>): ArrayList<String> {
    let result = ArrayList<String>()
    for (value in allowed) { if (!removed.contains(value)) { result.add(value) } }
    result
}

/** Conditional rules that keep a relation walk and its chapter selection together. */
private func queryRelationsSelectionRules(): JsonArray {
    let rules = JsonArray()
    // A named snapshot expansion only matters when the relation walk is reachable.
    let relatedThen = JsonObject()
    relatedThen.put("required", queryStringArray(["relations"]))
    let relatedRule = JsonObject()
    relatedRule.put("if", queryRequiredOnly("relatedSnapshotIds"))
    relatedRule.put("then", relatedThen)
    rules.add(relatedRule)
    // Only the reference preset selects the relations chapter; with another
    // preset a supplied relation walk would be silently ignored.
    let preset = JsonObject()
    preset.put("const", JsonNode.string("reference"))
    let presetProperties = JsonObject()
    presetProperties.put("preset", preset)
    let presetThen = JsonObject()
    presetThen.put("properties", presetProperties)
    let presetRule = JsonObject()
    presetRule.put("if", queryRequiredOnly(["relations", "preset"]))
    presetRule.put("then", presetThen)
    rules.add(presetRule)
    rules
}

/** `{"required":[...]}`; the trigger a conditional rule tests. */
private func queryRequiredOnly(names: Array<String>): JsonObject {
    let node = JsonObject()
    node.put("required", queryStringArray(names))
    node
}

private func queryRequiredOnly(name: String): JsonObject {
    queryRequiredOnly([name])
}

/**
 * Required fields for one property, expressed as a schema.
 */
private func queryOperationCondition(operation: String, identity!: String = ""): JsonObject {
    let condition = JsonObject()
    let required = ArrayList<String>(["operation"])
    if (!identity.isEmpty()) { required.add(identity) }
    condition.put("required", queryStringArray(required.toArray()))
    let properties = JsonObject()
    let selected = JsonObject()
    selected.put("const", JsonNode.string(operation))
    properties.put("operation", selected)
    condition.put("properties", properties)
    condition
}

private func queryPropertyNames(allowed: ArrayList<String>): JsonObject {
    let node = JsonObject()
    node.put("propertyNames", queryEnumSchema(allowed))
    node
}

private func queryOperationBlock(declaration: JsonObject, operation: String,
    spec: JsonObject): JsonObject {
    let block = JsonObject()
    block.put("if", queryOperationCondition(operation))
    let then = queryPropertyNames(queryAdmittedFields(declaration, spec))
    let identities = queryIdentityNames(spec)
    if (!identities.isEmpty()) { then.put("oneOf", queryRequiredOneOf(identities)) }
    block.put("then", then)
    block
}

private func queryIdentityBlock(declaration: JsonObject, operation: String,
    identity: String, spec: JsonObject): JsonObject {
    let block = JsonObject()
    block.put("if", queryOperationCondition(operation, identity: identity))
    let then = queryPropertyNames(queryAdmittedFields(declaration, spec, identity: identity))
    let identitySpec = queryIdentityTable(spec).getOrThrow()
        .get(identity).getOrThrow().asObject()
    let properties = JsonObject()
    properties.put("preset", queryEnumSchema(queryFieldArray(identitySpec, "presets")))
    let sections = JsonObject()
    sections.put("items", queryEnumSchema(queryFieldArray(identitySpec, "sections")))
    properties.put("sections", sections)
    then.put("properties", properties)
    if (queryBool(identitySpec, "requiresRelationsSection")) {
        then.put("allOf", queryRelationsSelectionRules())
    }
    block.put("then", then)
    block
}

private func queryBool(value: JsonObject, key: String): Bool {
    match (value.get(key)) {
        case Some(node) => node.asBool()
        case None => false
    }
}

private func queryRequestSchemaNode(): JsonObject {
    let declaration = queryDeclaration()
    let operations = declaration.get("operations").getOrThrow().asObject()
    let schema = JsonObject()
    schema.put("$schema", JsonNode.string("https://json-schema.org/draft/2020-12/schema"))
    schema.put("$id", JsonNode.string("https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/query-request.schema.json"))
    schema.put("title", JsonNode.string("cjdoc read-only documentation query v3"))
    schema.put("type", JsonNode.string("object"))
    schema.put("additionalProperties", JsonNode.boolean(false))
    schema.put("required", queryStringArray(["operation"]))
    schema.put("properties", declaration.get("properties").getOrThrow())
    let conditions = JsonArray()
    for (index in 0..operations.size()) {
        let name = operations.nameAt(index)
        let spec = operations.valueAt(index).asObject()
        conditions.add(queryOperationBlock(declaration, name, spec))
        for (identity in queryIdentityNames(spec)) {
            conditions.add(queryIdentityBlock(declaration, name, identity, spec))
        }
    }
    schema.put("allOf", conditions)
    schema.put("not", queryRequiredOnly(["sections", "preset"]))
    schema
}

/**
 * The published `cjdoc.query-request/3` schema: strict object, one required
 * discriminator, and per-operation admissibility generated from the single
 * declaration above.
 */
public let DOCUMENTATION_QUERY_REQUEST_SCHEMA: String = queryRequestSchemaNode().toJson()

/**
 * MCP tool input schema for one operation, generated from the same declaration.
 *
 * The operation is supplied by the tool name, so the discriminator and the
 * request schema version are absent here; every other rule (admissible fields,
 * identity selection, identity-specific sections and presets, and the relation
 * chapter requirements) is identical to the CLI contract.
 */
public func documentationQueryOperationSchema(operation: String): String {
    let declaration = queryDeclaration()
    let spec = queryOperationSpec(declaration, operation)
    let identities = queryIdentityNames(spec)
    let replaced: Array<String> = ["operation", "schemaVersion"]
    let allowed = queryDrop(queryAdmittedFields(declaration, spec), replaced)
    let declared = declaration.get("properties").getOrThrow().asObject()
    let schema = JsonObject()
    schema.put("$schema", JsonNode.string("https://json-schema.org/draft/2020-12/schema"))
    schema.put("title", JsonNode.string("cjdoc query tool input: " + operation))
    schema.put("type", JsonNode.string("object"))
    schema.put("additionalProperties", JsonNode.boolean(false))
    let properties = JsonObject()
    for (value in allowed) {
        if (let Some(field) <- declared.get(value)) { properties.put(value, field) }
    }
    schema.put("properties", properties)
    schema.put("required", JsonArray())
    schema.put("propertyNames", queryEnumSchema(allowed))
    if (!identities.isEmpty()) {
        schema.put("oneOf", queryRequiredOneOf(identities))
        let conditions = JsonArray()
        for (identity in identities) {
            let identitySpec = match (queryIdentityTable(spec)) {
                case Some(table) => table.get(identity).getOrThrow().asObject()
                case None => JsonObject()
            }
            let block = JsonObject()
            block.put("if", queryRequiredOnly(identity))
            let then = queryPropertyNames(queryDrop(
                queryAdmittedFields(declaration, spec, identity: identity), replaced))
            let narrowedProperties = JsonObject()
            narrowedProperties.put("preset", queryEnumSchema(queryFieldArray(identitySpec, "presets")))
            let sections = JsonObject()
            sections.put("items", queryEnumSchema(queryFieldArray(identitySpec, "sections")))
            narrowedProperties.put("sections", sections)
            then.put("properties", narrowedProperties)
            if (queryBool(identitySpec, "requiresRelationsSection")) {
                then.put("allOf", queryRelationsSelectionRules())
            }
            block.put("then", then)
            conditions.add(block)
        }
        schema.put("allOf", conditions)
    }
    schema.toJson()
}
