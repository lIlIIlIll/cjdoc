package cjdoc

import cjdoc.schema_data as query_schema
import std.collection.*
import std.sort.*
import yjson.*
import yjson_algorithms.*

internal let QUERY_INPUT_BYTES: Int64 = 1024 * 1024
internal let QUERY_DEFAULT_BYTES: Int64 = 65536
internal let QUERY_MAX_BYTES: Int64 = 64 * 1024 * 1024

internal class DocumentationQueryException <: Exception {
    let status: String
    let code: String
    init(status: String, code: String, message: String) {
        super(message)
        this.status = status
        this.code = code
    }
}

internal func queryString(value: JsonObject, key: String, fallback!: String = ""): String {
    match (value.get(key)) {
        case Some(node) => if (node.kind() == JsonKind.String) { node.asString() } else { fallback }
        case None => fallback
    }
}

internal func queryInt(value: JsonObject, key: String, fallback!: Int64 = 0): Int64 {
    match (value.get(key)) { case Some(node) => node.asInt64(); case None => fallback }
}

internal func queryBool(value: JsonObject, key: String, fallback!: Bool = false): Bool {
    match (value.get(key)) { case Some(node) => node.asBool(); case None => fallback }
}

internal func queryStrings(value: JsonObject, key: String): Array<String> {
    let result = ArrayList<String>()
    if (let Some(node) <- value.get(key)) {
        let values = node.asArray()
        for (index in 0..values.size()) { result.add(values[index].asString()) }
    }
    result.toArray()
}

internal func queryNullable(value: ?String): JsonNode {
    match (value) { case Some(text) => JsonNode.string(text); case None => JsonNode.nullValue }
}

internal func queryStringArray(values: Array<String>): JsonArray {
    let result = JsonArray()
    for (value in values) { result.add(JsonNode.string(value)) }
    result
}

internal func queryCanonical(value: JsonNode): String {
    match (value) {
        case object: JsonObject =>
            let keys = ArrayList<String>()
            for (index in 0..object.size()) { keys.add(object.nameAt(index)) }
            sort(keys, lessThan: { left, right => left < right }, stable: true)
            let out = StringBuilder()
            out.append("{")
            var first = true
            for (key in keys) {
                if (!first) { out.append(",") }; first = false
                out.append(JsonNode.string(key).toJson() + ":" + queryCanonical(object.get(key).getOrThrow()))
            }
            out.append("}")
            out.toString()
        case array: JsonArray =>
            let out = StringBuilder()
            out.append("[")
            for (index in 0..array.size()) {
                if (index > 0) { out.append(",") }
                out.append(queryCanonical(array[index]))
            }
            out.append("]")
            out.toString()
        case _ => value.toJson()
    }
}

/**
 * The published request contract, compiled once.
 *
 * The schema is a pure function of the declarative table in
 * `cjdoc.schema_data`, so compiling it once per process cannot disagree with
 * the bytes `cjdoc schema query-request` publishes.
 */
private let QUERY_REQUEST_SCHEMA_TEXT: String = query_schema.DOCUMENTATION_QUERY_REQUEST_SCHEMA
private let QUERY_REQUEST_SCHEMA: JsonSchema = JsonSchema.parse(QUERY_REQUEST_SCHEMA_TEXT)

/** Field names the request contract declares, used to name an unknown field. */
private let QUERY_REQUEST_FIELDS: HashSet<String> = queryRequestFieldNames()

private func queryRequestFieldNames(): HashSet<String> {
    let result = HashSet<String>()
    let properties = JsonNode.parse(QUERY_REQUEST_SCHEMA_TEXT).asObject()
        .get("properties").getOrThrow().asObject()
    for (index in 0..properties.size()) { let _ = result.add(properties.nameAt(index)) }
    result
}

/**
 * The first request field the operation does not honour, if any.
 *
 * The schema already rejects every inadmissible combination; this pass exists to
 * name the offending field in the machine-readable error instead of returning an
 * opaque schema violation. It reads the same violation paths the validator
 * reports, so the two can never disagree about which field is wrong.
 */
private func queryNamedField(violation: JsonSchemaViolation): String {
    let path = violation.instancePath
    if (!path.startsWith("/")) { return "" }
    let tail = path[1..]
    var end: Int64 = 0
    while (end < tail.size) {
        if (tail[end] == b'/') { break }
        end++
    }
    tail[..end].replace("~1", "/").replace("~0", "~")
}

internal func parseDocumentationQueryRequest(text: String): JsonObject {
    if (text.size > QUERY_INPUT_BYTES) {
        throw DocumentationQueryException("invalid_request", "request_byte_limit", "Query request exceeds 1 MiB UTF-8 bytes.")
    }
    let request = JsonNode.parse(text, config: JsonReadOptions(maxInputBytes: QUERY_INPUT_BYTES,
        maxStringBytes: QUERY_INPUT_BYTES, maxBufferedValueBytes: QUERY_INPUT_BYTES, maxDepth: 64)).asObject()
    for (index in 0..request.size()) {
        let name = request.nameAt(index)
        if (!QUERY_REQUEST_FIELDS.contains(name)) {
            throw DocumentationQueryException("invalid_request", "unknown_field",
                "Request field '${name}' is not declared by cjdoc.query-request/1.")
        }
    }
    let errors = QUERY_REQUEST_SCHEMA.validate(request)
    if (!errors.isEmpty()) {
        let field = queryNamedField(errors[0])
        if (errors[0].schemaPath.contains("/propertyNames")) {
            throw DocumentationQueryException("invalid_request", "field_not_applicable",
                "Request field '${field}' is not applicable to this operation or identity.")
        }
        throw DocumentationQueryException("invalid_request", "request_schema",
            "Request does not satisfy cjdoc.query-request/1." +
            (if (field.isEmpty()) { "" } else { " Invalid field '${field}'." }))
    }
    request
}

/** Stable MCP input schema for one operation, derived from the same declaration. */
public func documentationQueryToolSchema(operation: String): String {
    query_schema.documentationQueryOperationSchema(operation)
}

/** A self-contained strict response schema, including unchanged Doc IR v16 definitions. */
public func documentationQueryOutputSchema(): String {
    query_schema.completeDocumentationSchema(query_schema.DOCUMENTATION_QUERY_RESULT_SCHEMA_TEMPLATE)
}

/**
 * Exit status for a machine query; ambiguity and scoped absence are normal outcomes.
 *
 * The result is decoded with the shared bounded result reader, so a legitimate
 * result above any adapter's default buffer still yields its status instead of
 * being reparsed with a smaller implicit limit.
 */
public func documentationQueryExitCode(result: String): Int64 {
    let status = queryString(queryDecodeResponse(result), "status")
    if (["ok", "ambiguous", "not_found", "source_incomplete"].contains(status)) { return 0 }
    if (["invalid_request", "scope_mismatch", "stale_cursor"].contains(status)) { return 2 }
    3
}
