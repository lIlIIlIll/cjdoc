package cjdoc.schema_data

private let DOC_IR_V11_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v11.schema.json"
private let DOC_IR_CURRENT_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json"

public let DOC_IR_V11_SCHEMA = DOC_IR_V10_SCHEMA
    .replace("https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v10.schema.json",
        DOC_IR_V11_ID)
    .replace("cjdoc Doc IR v10", "cjdoc Doc IR v11")
    .replace("cjdoc.doc-ir/10", "cjdoc.doc-ir/11")
    .replace("        \"targetSymbolId\": {\"$ref\": \"#/$defs/nullableSymbolId\"}\n" +
        "      }\n    },\n    \"headingMetadata\": {",
        "        \"targetSymbolId\": {\"$ref\": \"#/$defs/nullableSymbolId\"},\n" +
        "        \"directives\": {\"type\": \"string\"}\n" +
        "      }\n    },\n    \"headingMetadata\": {")

public let DOC_IR_SCHEMA = DOC_IR_V11_SCHEMA
    .replace(DOC_IR_V11_ID, DOC_IR_CURRENT_ID)
