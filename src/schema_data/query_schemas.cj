package cjdoc.schema_data

import std.collection.*
import yjson.*

// One declarative source of the `cjdoc.query-request/1` contract: the field
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
    "schemaVersion":{"const":"cjdoc.query-request/1"},
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
    "latest":{"type":"boolean"},"compatible":{"type":"boolean"}
  },
  "globalFields":["schemaVersion","operation","snapshotId","language","languageFallback","audience","cfgProfile"],
  "operations":{
    "resolve_docs":{"fields":["query","contextSnapshotId","contextModuleId","dependencyInstanceId",
      "documentSetId","moduleId","packageName","apiVersion","library","target","cfg",
      "latest","compatible","limit","cursor","maxBytes"]},
    "search":{"fields":["query","symbolId","symbolKey","name","qualifiedName","parameterTypes",
      "genericArity","kind","moduleId","packageName","documentSetId","apiVersion","library",
      "dependencyInstanceId","target","cfg","latest","limit","cursor"]},
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

private func queryDeclaration(): JsonObject {
    JsonNode.parse(QUERY_REQUEST_DECLARATION).asObject()
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
    schema.put("title", JsonNode.string("cjdoc read-only documentation query v1"))
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
 * The published `cjdoc.query-request/1` schema: strict object, one required
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

// Section values remain existing strict Doc IR data. The exported result schema
// is assembled with those frozen v16 definitions, rather than a parallel model.
//
// Every object here is a shape a current producer emits. The `allOf` block at
// the root states only outcome invariants a producer already guarantees:
// no-match and failure outcomes carry no fabricated item, an error object
// accompanies every failure status, a retry budget exists exactly when a
// required content unit did not fit, and a complete page has no continuation.
public let DOCUMENTATION_QUERY_RESULT_SCHEMA_TEMPLATE = """
{
  "$schema":"https://json-schema.org/draft/2020-12/schema",
  "$id":"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/query-result.schema.json",
  "title":"cjdoc documentation query result v1",
  "type":"object","additionalProperties":false,
  "required":["schemaVersion","status","operation","scope","selection","result","completeness","sources","text","error"],
  "properties":{
    "schemaVersion":{"const":"cjdoc.query-result/1"},
    "status":{"enum":["ok","ambiguous","not_found","source_incomplete","budget_exceeded","stale_cursor","invalid_request","scope_mismatch","resource_limit","unavailable"]},
    "operation":{"type":"string"},
    "scope":{"type":"object","additionalProperties":false,"required":["requested","catalogId","snapshots"],"properties":{
      "requested":{"type":"object"},"catalogId":{"type":["string","null"]},
      "snapshots":{"type":"array","maxItems":64,"items":{"$ref":"#/$defs/querySnapshot"}}
    }},
    "selection":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,"required":["strategy","selected","candidates"],"properties":{
      "strategy":{"enum":["captured-dependency-policy","explicit-latest-alias"]},
      "selected":{"type":"array","maxItems":1,"items":{"$ref":"#/$defs/queryCandidate"}},
      "candidates":{"type":"array","maxItems":100,"items":{"$ref":"#/$defs/queryCandidate"}}
    }}]},
    "result":{"type":"object","additionalProperties":false,"required":["items","relations","reports"],"properties":{
      "items":{"type":"array","maxItems":101,"items":{"$ref":"#/$defs/queryItem"}},
      "relations":{"type":"array","maxItems":100,"items":{"$ref":"#/$defs/queryRelation"}},
      "reports":{"type":"array","maxItems":64,"items":{"$ref":"#/$defs/queryReport"}}
    }},
    "completeness":{"type":"object","additionalProperties":false,"required":["apiCollection","query","content"],"properties":{
      "apiCollection":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["snapshotId","state"],"properties":{"snapshotId":{"type":"string"},"state":{"enum":["resolved","partial","unavailable"]}}}},
      "query":{"type":"object","additionalProperties":false,"required":["complete","scope","offset","returned","total","next","reason"],"properties":{
        "complete":{"type":"boolean"},
        "scope":{"enum":["catalog","declaration","page","relations","document_sets",""]},
        "offset":{"type":"integer","minimum":0},"returned":{"type":"integer","minimum":0},
        "total":{"type":["integer","null"],"minimum":0},"next":{"type":["string","null"]},
        "reason":{"type":"string"}
      },"allOf":[
        {"if":{"required":["complete"],"properties":{"complete":{"const":true}}},
         "then":{"properties":{"next":{"type":"null"}}}},
        {"if":{"required":["next"],"properties":{"next":{"type":"string"}}},
         "then":{"properties":{"complete":{"const":false}}}}
      ]},
      "content":{"type":"object","additionalProperties":false,"required":["complete","selectedSections","omittedSections","missingSections","retry"],"properties":{
        "complete":{"type":"boolean"},
        "selectedSections":{"type":"array","items":{"$ref":"#/$defs/querySectionName"}},
        "omittedSections":{"type":"array","items":{"$ref":"#/$defs/queryOmission"}},
        "missingSections":{"type":"array","items":{"$ref":"#/$defs/querySectionName"}},
        "retry":{"anyOf":[{"$ref":"#/$defs/queryRetry"},{"type":"null"}]}
      }}
    }},
    "sources":{"type":"array","maxItems":64,"items":{"$ref":"#/$defs/querySource"}},
    "text":{"type":"string"},
    "error":{"anyOf":[{"type":"null"},{"type":"object","additionalProperties":false,"required":["code","message","requiredBytes","maximumBytes"],"properties":{
      "code":{"type":"string","minLength":1},"message":{"type":"string","minLength":1},
      "requiredBytes":{"type":["integer","null"],"minimum":0},"maximumBytes":{"type":["integer","null"],"minimum":0}
    }}]}
  },
  "allOf":[
    {"if":{"required":["operation"],"properties":{"operation":{"const":"search"}}},
     "then":{"properties":{"result":{"properties":{"items":{"items":{"properties":{
       "sections":{"maxItems":2,"items":{"$ref":"#/$defs/queryDiscoverySection"}}
     }}}}}}}},
    {"if":{"required":["operation"],"properties":{"operation":{"const":"get_symbol"}}},
     "then":{"properties":{"result":{"properties":{"items":{"items":{"allOf":[
       {"if":{"properties":{"kind":{"const":"symbol"}}},"then":{"properties":{"sections":{"items":{"$ref":"#/$defs/querySymbolSection"}}}}},
       {"if":{"properties":{"kind":{"const":"concept"}}},"then":{"properties":{"sections":{"items":{"$ref":"#/$defs/queryPageSection"}}}}}
     ]}}}}}}},
    {"if":{"required":["operation","status"],"properties":{"operation":{"const":"get_symbol"},"status":{"const":"ok"}}},
     "then":{"properties":{"result":{"properties":{"items":{"minItems":1}}}}}},
    {"if":{"required":["operation"],"properties":{"operation":{"const":"resolve_docs"}}},
     "then":{"properties":{"result":{"properties":{"items":{"maxItems":0},"relations":{"maxItems":0},"reports":{"maxItems":0}}}}}},
    {"if":{"required":["status"],"properties":{"status":{"enum":["ok","ambiguous","not_found","source_incomplete"]}}},
     "then":{"properties":{"error":{"type":"null"}}}},
    {"if":{"required":["status"],"properties":{"status":{"enum":["invalid_request","scope_mismatch","stale_cursor","resource_limit","unavailable","budget_exceeded"]}}},
     "then":{"properties":{"error":{"not":{"type":"null"}}}}},
    {"if":{"required":["status"],"properties":{"status":{"enum":["not_found","source_incomplete","budget_exceeded","resource_limit","invalid_request","scope_mismatch","stale_cursor","unavailable"]}}},
     "then":{"properties":{"result":{"properties":{"items":{"maxItems":0}}}}}},
    {"if":{"required":["status"],"properties":{"status":{"enum":["invalid_request","scope_mismatch","stale_cursor","resource_limit","unavailable"]}}},
     "then":{"properties":{
       "selection":{"type":"null"},
       "sources":{"maxItems":0},
       "result":{"properties":{"relations":{"maxItems":0},"reports":{"maxItems":0}}}
     }}},
    {"if":{"required":["status"],"properties":{"status":{"const":"budget_exceeded"}}},
     "then":{"properties":{"completeness":{"properties":{"content":{"properties":{
       "retry":{"not":{"type":"null"}},"omittedSections":{"minItems":1}
     }}}}}}},
    {"if":{"required":["status"],"properties":{"status":{"not":{"const":"budget_exceeded"}}}},
     "then":{"properties":{"completeness":{"properties":{"content":{"properties":{"retry":{"type":"null"}}}}}}}}
  ],
  "$defs":{
    "querySectionName":{"enum":["signature","parameters","returns","contracts","examples","description","relations","source","diagnostics","validation","diff"]},
    "queryRetry":{"type":"object","additionalProperties":false,"required":["maxBytes","detail"],"properties":{
      "maxBytes":{"type":"integer","minimum":0},"detail":{"type":"string","minLength":1}
    }},
    "querySection":{"type":"object","additionalProperties":false,"required":["name","state","value"],"properties":{
      "name":{"$ref":"#/$defs/querySectionName"},
      "state":{"enum":["available","missing","not_selected","budget_omitted","unavailable"]},"value":{}
    },"allOf":[
      {"if":{"properties":{"state":{"enum":["not_selected","budget_omitted"]}}},"then":{"properties":{"value":{"type":"null"}}}},
      {"if":{"properties":{"state":{"const":"available"}}},"then":{"properties":{"value":{"not":{"type":"null"}}}}}
    ]},
    "queryDiscoverySection":{"allOf":[{"$ref":"#/$defs/querySection"},{"properties":{
      "name":{"enum":["signature","description"]},"state":{"enum":["available","missing"]},
      "value":{"type":["string","null"]}
    }}]},
    "queryConceptDiscoverySection":{"allOf":[{"$ref":"#/$defs/queryDiscoverySection"},
      {"properties":{"name":{"const":"description"}}}
    ]},
    "querySignatureValue":{"type":"object","additionalProperties":false,
      "required":["headerSpelling","sourceApiSignature","genericParameters","semantic"],"properties":{
        "headerSpelling":{"type":"string"},"sourceApiSignature":{"$ref":"#/$defs/sourceApiSignature"},
        "genericParameters":{"$ref":"#/$defs/stringArray"},"semantic":{"$ref":"#/$defs/semanticInfo"}
    }},
    "queryParametersValue":{"type":"object","additionalProperties":false,"required":["parameters","documentationTags"],"properties":{
      "parameters":{"type":"array","items":{"$ref":"#/$defs/parameter"}},
      "documentationTags":{"type":"array","items":{"$ref":"#/$defs/tag"}}
    }},
    "queryReturnsValue":{"type":"object","additionalProperties":false,"required":["returnType","documentationTags"],"properties":{
      "returnType":{"anyOf":[{"$ref":"#/$defs/typeRef"},{"type":"null"}]},
      "documentationTags":{"type":"array","items":{"$ref":"#/$defs/tag"}}
    }},
    "queryDescriptionValue":{"type":"object","additionalProperties":false,
      "required":["summary","description","markdown","defaultLanguage","localizedTexts"],"properties":{
        "summary":{"type":"string"},"description":{"type":"string"},"markdown":{"$ref":"#/$defs/markdownNode"},
        "defaultLanguage":{"enum":["zh-CN","en",null]},
        "localizedTexts":{"type":"array","items":{"allOf":[{"$ref":"#/$defs/documentationText"},
          {"properties":{"kind":{"enum":["summary","description"]}}}]}}
    }},
    "queryImportContext":{"type":"object","additionalProperties":false,
      "required":["moduleId","packageName","documentSet","reExport"],"properties":{
        "moduleId":{"$ref":"#/$defs/moduleId"},"packageName":{"type":"string"},
        "documentSet":{"anyOf":[{"$ref":"#/$defs/documentSetIdentity"},{"type":"null"}]},
        "reExport":{"$ref":"#/$defs/reExport"}
    }},
    "queryRelationsValue":{"type":"object","additionalProperties":false,
      "required":["ownerId","typeRelationships","symbolRelationships","packageImportContext","documentationReferences"],"properties":{
        "ownerId":{"$ref":"#/$defs/nullableSymbolId"},
        "typeRelationships":{"type":"array","items":{"$ref":"#/$defs/typeRelationship"}},
        "symbolRelationships":{"type":"array","items":{"$ref":"#/$defs/symbolRelationship"}},
        "packageImportContext":{"type":"array","items":{"$ref":"#/$defs/queryImportContext"}},
        "documentationReferences":{"type":"array","items":{"$ref":"#/$defs/tag"}}
    }},
    "querySymbolSection":{"allOf":[{"$ref":"#/$defs/querySection"},
      {"if":{"properties":{"name":{"const":"signature"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/querySignatureValue"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"const":"parameters"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/queryParametersValue"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"const":"returns"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/queryReturnsValue"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"enum":["contracts","examples"]}}},"then":{"properties":{"value":{"anyOf":[{"type":"array","items":{"$ref":"#/$defs/tag"}},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"const":"description"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/queryDescriptionValue"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"const":"relations"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/queryRelationsValue"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"const":"source"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/querySymbolSource"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"const":"diagnostics"}}},"then":{"properties":{"value":{"anyOf":[{"type":"array","items":{"$ref":"#/$defs/diagnostic"}},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"enum":["validation","diff"]}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/queryReport"},{"type":"null"}]}}}}
    ]},
    "queryPageSection":{"allOf":[{"$ref":"#/$defs/querySection"},
      {"properties":{"name":{"enum":["description","source","validation","diff"]}}},
      {"if":{"properties":{"name":{"const":"description"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/documentationPage"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"const":"source"}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/queryPageSource"},{"type":"null"}]}}}},
      {"if":{"properties":{"name":{"enum":["validation","diff"]}}},"then":{"properties":{"value":{"anyOf":[{"$ref":"#/$defs/queryReport"},{"type":"null"}]}}}}
    ]},
    "querySnapshot":{"type":"object","additionalProperties":false,"required":["snapshotId","sourceSnapshotId","sourceKind","language","audience","apiCollectionState","publicationRevision","packagedRepresentations"],"properties":{
      "snapshotId":{"type":"string"},"sourceSnapshotId":{"type":"string"},"sourceKind":{"enum":["doc-ir","machine-manifest","public-model"]},"language":{"type":"string"},"audience":{"enum":["external","package","all"]},"apiCollectionState":{"enum":["resolved","partial","unavailable"]},"publicationRevision":{"type":"string"},"packagedRepresentations":{"type":"boolean"}
    }},
    "queryCandidate":{"type":"object","additionalProperties":false,"required":["snapshotId","contextSnapshotId","documentSet","inventoryDocumentSet","dependency","matchLevel","reason","score","inventoryPinned","sourceBinding","admitted"],"properties":{
      "snapshotId":{"type":"string"},
      "contextSnapshotId":{"type":["string","null"]},
      "documentSet":{"$ref":"#/$defs/documentSetIdentity"},
      "inventoryDocumentSet":{"$ref":"#/$defs/documentSetIdentity"},
      "dependency":{"anyOf":[{"$ref":"#/$defs/dependencyInstance"},{"type":"null"}]},
      "matchLevel":{"enum":["exact","compatible","manual","none"]},"reason":{"type":"string"},"score":{"type":"integer"},"inventoryPinned":{"type":"boolean"},"sourceBinding":{"enum":["matched","mismatch","conflict","unavailable"]},"admitted":{"type":"boolean"}
    }},
    "queryItem":{"type":"object","additionalProperties":false,"required":["kind","identity","signature","summary","match","sections","representations","source","exposures"],"properties":{
      "kind":{"enum":["symbol","concept"]},"identity":{"$ref":"#/$defs/queryIdentity"},
      "signature":{"type":["string","null"]},"summary":{"type":["string","null"]},
      "match":{"type":"object","additionalProperties":false,"required":["score","reason"],"properties":{"score":{"type":"integer"},"reason":{"type":"string","minLength":1}}},
      "sections":{"type":"array","maxItems":11,"items":{"$ref":"#/$defs/querySection"}},
      "representations":{"type":"object","additionalProperties":false,"required":["html","markdown","json"],"properties":{
        "html":{"type":"string"},"markdown":{"type":"string"},"json":{"type":"string"}}},
      "source":{"anyOf":[{"$ref":"#/$defs/querySymbolSource"},{"$ref":"#/$defs/queryPageSource"},{"type":"null"}]},
      "exposures":{"type":"array","items":{"$ref":"#/$defs/queryExposure"}}
    },"allOf":[
      {"if":{"required":["kind"],"properties":{"kind":{"const":"symbol"}}},
       "then":{"properties":{
         "identity":{"properties":{"symbolId":{"type":"string"},"pageId":{"type":"null"}}},
         "source":{"anyOf":[{"$ref":"#/$defs/querySymbolSource"},{"type":"null"}]},
         "sections":{"items":{"anyOf":[{"$ref":"#/$defs/querySymbolSection"},{"$ref":"#/$defs/queryDiscoverySection"}]}}
       }}},
      {"if":{"required":["kind"],"properties":{"kind":{"const":"concept"}}},
       "then":{"properties":{
         "signature":{"type":"null"},
         "identity":{"properties":{"symbolId":{"type":"null"},"pageId":{"type":"string"}}},
         "source":{"anyOf":[{"$ref":"#/$defs/queryPageSource"},{"type":"null"}]},
         "sections":{"items":{"anyOf":[{"$ref":"#/$defs/queryPageSection"},{"$ref":"#/$defs/queryConceptDiscoverySection"}]}}
       }}}
    ]},
    "queryIdentity":{"type":"object","additionalProperties":false,"required":["snapshotId","sourceSnapshotId","documentSet","moduleId","dependencyInstance","dependencyInstanceState","symbolId","symbolKey","pageId","ownerId"],"properties":{
      "snapshotId":{"type":"string"},"sourceSnapshotId":{"type":"string"},
      "documentSet":{"anyOf":[{"$ref":"#/$defs/documentSetIdentity"},{"type":"null"}]},
      "moduleId":{"type":["string","null"]},
      "dependencyInstance":{"anyOf":[{"$ref":"#/$defs/dependencyInstance"},{"type":"null"}]},
      "dependencyInstanceState":{"enum":["recorded","not_applicable","unrecorded","ambiguous"]},
      "symbolId":{"type":["string","null"]},"symbolKey":{"type":["string","null"]},
      "pageId":{"type":["string","null"]},"ownerId":{"type":["string","null"]}
    }},
    "queryRelation":{"type":"object","additionalProperties":false,"required":["kind","direction","depth","from","to","state","reason","navigation","source"],"properties":{
      "kind":{"type":"string","minLength":1},"direction":{"enum":["outgoing","incoming"]},
      "depth":{"type":"integer","minimum":1,"maximum":4},
      "from":{"$ref":"#/$defs/queryIdentity"},
      "to":{"anyOf":[{"$ref":"#/$defs/queryIdentity"},{"type":"null"}]},
      "state":{"type":"string"},"reason":{"type":"string"},
      "navigation":{"anyOf":[{"$ref":"#/$defs/typeNavigation"},{"type":"null"}]},
      "source":{"anyOf":[{"$ref":"#/$defs/querySymbolSource"},{"type":"null"}]}
    }},
    "queryOmission":{"type":"object","additionalProperties":false,"required":["section","reason","next"],"properties":{
      "section":{"type":"string","minLength":1},
      "reason":{"enum":["not_selected","preset","budget","relation_depth","relation_limit","not_packaged","resource_limit"]},
      "next":{"anyOf":[{"$ref":"#/$defs/queryRetry"},{"type":"null"}]}
    }},
    "querySource":{"type":"object","additionalProperties":false,"required":["snapshotId","kind","path","url","state"],"properties":{
      "snapshotId":{"type":"string"},"kind":{"enum":["html","markdown","json","source","validation","api-diff"]},"path":{"type":["string","null"]},"url":{"type":["string","null"]},"state":{"enum":["packaged","logical_path","recorded","unavailable"]}
    }},
    "querySymbolSource":{"type":"object","additionalProperties":false,"required":["url","range","recordedRevision","revisionKind"],"properties":{
      "url":{"type":["string","null"]},
      "range":{"$ref":"#/$defs/sourceRange"},
      "recordedRevision":{"type":["string","null"]},
      "revisionKind":{"enum":["recorded","unavailable"]}
    }},
    "queryPageSource":{"type":"object","additionalProperties":false,"required":["url","path","revisionKind"],"properties":{
      "url":{"type":"null"},"path":{"type":"string"},"revisionKind":{"const":"unavailable"}
    }},
    "queryExposure":{"type":"object","additionalProperties":false,"required":["kind","alias","exposedName","symbolId","snapshotId","state","declaringModuleId","declaringPackage","documentSet","reExport"],"properties":{
      "kind":{"const":"reexport"},"alias":{"type":"string"},"exposedName":{"type":"string"},
      "symbolId":{"type":"string"},"snapshotId":{"type":"string"},"state":{"type":"string"},
      "declaringModuleId":{"type":"string"},"declaringPackage":{"type":"string"},
      "documentSet":{"anyOf":[{"$ref":"#/$defs/documentSetIdentity"},{"type":"null"}]},
      "reExport":{"$ref":"#/$defs/reExport"}
    }},
    "queryReport":{"type":"object","additionalProperties":false,"required":["kind","state","snapshotId","sha256","path","binding","report"],"properties":{
      "kind":{"enum":["validation","api-diff"]},"state":{"enum":["attached","not_attached","binding_unavailable","binding_mismatch","invalid"]},"snapshotId":{"type":"string"},"sha256":{"type":["string","null"]},"path":{"type":["string","null"]},"binding":{"type":"object"},"report":{"type":["object","null"]}
    }}
  }
}
"""
