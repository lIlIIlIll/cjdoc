package cjdoc.schema_data

private let DOC_IR_V12_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v12.schema.json"
private let DOC_IR_CURRENT_ID =
    "https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir.schema.json"

// Every member v12 adds is presentation-only and optional, so a document without
// highlight data keeps the exact v11 member set. That is why the additions are
// expressed as anchored insertions over the frozen v11 definition instead of a
// rewritten copy of the whole schema: the frozen bytes stay the single source.
//
// Each insertion text ends at the property's own closing brace and carries no
// trailing comma, because the schema line that follows the anchor already closes
// the enclosing object.
private func docIrV12HighlightProperty(name: String): String {
    "        \"" + name + "\": {\n" +
    "          \"type\": \"object\", \"additionalProperties\": false,\n" +
    "          \"required\": [\"language\", \"sourceHash\", \"byteLength\", \"engineId\", " +
        "\"engineRevision\", \"state\", \"reason\", \"spans\"],\n" +
    "          \"properties\": {\n" +
    "            \"language\": {\"type\": \"string\"},\n" +
    "            \"sourceHash\": {\"type\": \"string\", \"pattern\": \"^[0-9a-f]{64}$\"},\n" +
    "            \"byteLength\": {\"type\": \"integer\", \"minimum\": 0},\n" +
    "            \"engineId\": {\"type\": \"string\", \"minLength\": 1},\n" +
    "            \"engineRevision\": {\"type\": \"string\", \"minLength\": 1},\n" +
    "            \"state\": {\"enum\": [\"complete\", \"partial\", \"plain\"]},\n" +
    "            \"reason\": {\"type\": [\"string\", \"null\"], \"enum\": [\"disabled\", " +
        "\"no-language\", \"unsupported\", \"missing-metadata\", \"backend-unavailable\", " +
        "\"invalid-spans\", \"resource-limit\", \"lexer-failed\", \"unterminated-token\", null]},\n" +
    "            \"spans\": {\"type\": \"array\", \"maxItems\": 65536, \"items\": {\n" +
    "              \"type\": \"object\", \"additionalProperties\": false,\n" +
    "              \"required\": [\"startByte\", \"endByte\", \"kind\"],\n" +
    "              \"properties\": {\n" +
    "                \"startByte\": {\"type\": \"integer\", \"minimum\": 0},\n" +
    "                \"endByte\": {\"type\": \"integer\", \"minimum\": 1},\n" +
    "                \"kind\": {\"enum\": [\"keyword\", \"type\", \"string\", \"number\", " +
        "\"literal\", \"comment\", \"operator\", \"punctuation\", \"function\", " +
        "\"property\", \"meta\"]}\n" +
    "              }\n" +
    "            }}\n" +
    "          }\n" +
    "        }\n"
}

// The code-block definition's own property list already ends with `attributesRaw`
// followed by the closing line of `properties`.
private let DOC_IR_V12_CODE_BLOCK_ANCHOR = "        \"attributesRaw\": {\"type\": \"string\"}\n"

// The signature presentation member is added to the declaration definition's own
// property list, after its final member; the definition's closing lines are kept
// exactly as they are.
private let DOC_IR_V12_SIGNATURE_ANCHOR =
    "        \"enumNonExhaustive\": {\"type\": [\"boolean\", \"null\"]}\n"

// The parsed example tree is stored on the tag that declares it. Reusing the
// existing Markdown node definition keeps one representation for example code
// instead of a render-time reparse.
private let DOC_IR_V12_TAG_ANCHOR = "        \"directives\": {\"type\": \"string\"}\n"

private let DOC_IR_V12_TAG_REPLACEMENT =
    "        \"directives\": {\"type\": \"string\"},\n" +
    "        \"exampleMarkdown\": {\"$ref\": \"#/$defs/markdownNode\"}\n"

public let DOC_IR_V12_SCHEMA = DOC_IR_V11_SCHEMA
    .replace("https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/doc-ir-v11.schema.json",
        DOC_IR_V12_ID)
    .replace("cjdoc Doc IR v11", "cjdoc Doc IR v12")
    .replace("cjdoc.doc-ir/11", "cjdoc.doc-ir/12")
    .replace(DOC_IR_V12_CODE_BLOCK_ANCHOR,
        "        \"attributesRaw\": {\"type\": \"string\"},\n" +
            docIrV12HighlightProperty("codeHighlight"))
    .replace(DOC_IR_V12_SIGNATURE_ANCHOR,
        "        \"enumNonExhaustive\": {\"type\": [\"boolean\", \"null\"]},\n" +
            docIrV12HighlightProperty("signatureHighlight"))
    .replace(DOC_IR_V12_TAG_ANCHOR, DOC_IR_V12_TAG_REPLACEMENT)
