package cjdoc.schema_data

/** API collection completeness is independent of presentation failures from v14. */
public let DOC_IR_V14_SCHEMA = DOC_IR_V13_SCHEMA
    .replace("doc-ir-v13.schema.json", "doc-ir-v14.schema.json")
    .replace("cjdoc Doc IR v13", "cjdoc Doc IR v14")
    .replace("cjdoc.doc-ir/13", "cjdoc.doc-ir/14")
    .replace("\"generator\", \"status\", \"project\"", "\"generator\", \"status\", \"apiCollectionState\", \"project\"")
    .replace("    \"status\": {\"enum\": [\"complete\", \"partial\"]},",
        "    \"status\": {\"enum\": [\"complete\", \"partial\"]},\n" +
        "    \"apiCollectionState\": {\"enum\": [\"resolved\", \"partial\", \"unavailable\"]},")
