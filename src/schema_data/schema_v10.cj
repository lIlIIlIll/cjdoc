package cjdoc.schema_data

private let DOC_IR_V10_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v10.schema.json"

private func buildDocIrV10Schema(source: String): String {
    var schema = source
        .replace("https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v9.schema.json", DOC_IR_V10_ID)
        .replace("cjdoc Doc IR v9", "cjdoc Doc IR v10")
        .replace("cjdoc.doc-ir/9", "cjdoc.doc-ir/10")

    let semanticLinkDefinition = """
    "semanticLinkMetadata": {
      "type": "object", "additionalProperties": false,
      "required": ["target", "state", "targetSymbolId", "externalUrl"],
      "properties": {
        "target": {"type": "string", "minLength": 1},
        "state": {"enum": ["resolved", "unresolved", "ambiguous", "unavailable"]},
        "targetSymbolId": {"$ref": "#/$defs/nullableSymbolId"},
        "externalUrl": {"$ref": "#/$defs/nullableString"}
      }
    },
"""
    schema = schema.replace("  \"$defs\": {\n", "  \"$defs\": {\n" + semanticLinkDefinition)
    schema = schema
        .replace("\"$ref\": \"#/$defs/tableCellMetadata\"}]},\n        \"children\"",
            "\"$ref\": \"#/$defs/tableCellMetadata\"}, {\"$ref\": \"#/$defs/semanticLinkMetadata\"}]},\n        \"children\"")
        .replace("\n      ]\n    },\n    \"comment\": {",
            ",\n" +
            "        {\"if\": {\"properties\": {\"kind\": {\"const\": \"semantic_link\"}}}, " +
            "\"then\": {\"properties\": {\"metadata\": {\"$ref\": \"#/$defs/semanticLinkMetadata\"}}}}\n" +
            "      ]\n    },\n    \"comment\": {")
    schema = schema.replace("\"html_inline\", \"custom_inline\"]}, \"literal\"",
        "\"html_inline\", \"custom_inline\", \"semantic_link\"]}, \"literal\"")
    schema
}

private let DOC_IR_CURRENT_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json"

public let DOC_IR_V10_SCHEMA = buildDocIrV10Schema(DOC_IR_V9_SCHEMA)
public let DOC_IR_SCHEMA = DOC_IR_V10_SCHEMA.replace(DOC_IR_V10_ID, DOC_IR_CURRENT_ID)
