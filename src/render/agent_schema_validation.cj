package cjdoc.render

import cjdoc.model.*
import cjdoc.schema_data.*
import yjson.*
import yjson_algorithms.*

/** Validate a versioned reading artifact without accessing any external schema or source. */
public func validateDocumentationArtifactJson(text: String, schemaName: String): Unit {
    if (text.size > DOC_IR_MAX_JSON_DOCUMENT_BYTES) {
        throw RenderResourceLimitException("machine artifact exceeds 64 MiB UTF-8 bytes")
    }
    let value = JsonNode.parse(text, config: JsonReadOptions(maxInputBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES,
        maxStringBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES, maxBufferedValueBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES,
        maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH))
    let schema = JsonSchema.parse(compatibleSchemaText(documentationArtifactSchema(schemaName)),
        config: JsonSchemaConfig(limits: JsonSchemaLimits(maxEvaluations: DOC_IR_SCHEMA_MAX_WORK,
            maxRefResolutions: DOC_IR_SCHEMA_MAX_WORK, maxRegexSteps: DOC_IR_SCHEMA_MAX_REGEX_STEPS,
            maxErrors: 20, maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH)))
    if (!schema.validate(value).isEmpty()) {
        throw IllegalArgumentException("machine artifact does not satisfy its declared schema")
    }
}
