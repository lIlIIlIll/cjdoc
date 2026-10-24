package cjdoc

import yjson.*

// Content selection and serialized transport have separate resource ceilings.
// Every adapter decodes exactly the same bounded core result.
internal let QUERY_RESULT_BYTES: Int64 = 64 * 1024 * 1024
internal let QUERY_RESULT_DEPTH: Int64 = 256

internal func queryDecodeResponse(text: String): JsonObject {
    JsonNode.parse(text, config: JsonReadOptions(maxInputBytes: QUERY_RESULT_BYTES,
        maxStringBytes: QUERY_RESULT_BYTES, maxBufferedValueBytes: QUERY_RESULT_BYTES,
        maxDepth: QUERY_RESULT_DEPTH)).asObject()
}

internal func queryEncodeResponse(value: JsonObject): String {
    try {
        value.toJson(options: JsonWriteOptions(maxOutputBytes: QUERY_RESULT_BYTES,
            maxDepth: QUERY_RESULT_DEPTH))
    } catch (error: JsonException) {
        if (error.code == "output_too_large") {
            throw DocumentationQueryException("resource_limit", "result_wire_byte_limit",
                "The serialized query result exceeds the 64 MiB wire limit; no truncated result is returned.")
        }
        throw error
    }
}
