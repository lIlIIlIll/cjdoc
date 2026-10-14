package cjdoc.schema_data

public let VERSIONS_SCHEMA = VERSIONS_V1_SCHEMA.replace("cjdoc.versions/1", "cjdoc.versions/2")
    .replace("versions.schema.json", "versions-v2.schema.json")
    .replace("\"release\": {\"type\": \"string\", \"minLength\": 1}",
        "\"release\": {\"type\": \"string\", \"minLength\": 1},\n" +
        "        \"languages\": {\"type\": \"array\", \"maxItems\": 2, \"items\": {\"type\": \"object\", \"additionalProperties\": false, \"required\": [\"language\", \"root\", \"index\"], \"properties\": {\"language\": {\"enum\": [\"en\", \"zh-CN\"]}, \"root\": {\"$ref\": \"#/$defs/safePath\"}, \"index\": {\"$ref\": \"#/$defs/safePath\"}}}}")

public let API_SURFACE_SCHEMA = API_SURFACE_V2_SCHEMA
    .replace("api-surface-v2.schema.json", "api-surface-v3.schema.json")
    .replace("API surface v2", "API surface v3").replace("cjdoc.api-surface/2", "cjdoc.api-surface/3")
    .replace("\"documentationFingerprint\", \"sourceFingerprint\"", "\"documentationFingerprint\", \"documentationLanguages\", \"sourceFingerprint\"")
    .replace("\"documentationFingerprint\": {\"$ref\": \"#/$defs/fingerprint\"}",
        "\"documentationFingerprint\": {\"$ref\": \"#/$defs/fingerprint\"},\n" +
        "        \"documentationLanguages\": {\"type\": \"array\", \"maxItems\": 3, \"items\": {\"type\": \"object\", \"additionalProperties\": false, \"required\": [\"language\", \"fingerprint\"], \"properties\": {\"language\": {\"enum\": [\"zh-CN\", \"en\", null]}, \"fingerprint\": {\"$ref\": \"#/$defs/fingerprint\"}}}}")

public let API_DIFF_SCHEMA = API_DIFF_V1_SCHEMA
    .replace("api-diff.schema.json", "api-diff-v2.schema.json")
    .replace("API diff v1", "API diff v2").replace("cjdoc.api-diff/1", "cjdoc.api-diff/2")
    .replace("\"required\": [\"field\", \"before\", \"after\", \"state\"]", "\"required\": [\"field\", \"before\", \"after\", \"state\", \"language\"]")
    .replace("\"field\": {\"type\": \"string\", \"minLength\": 1}", "\"field\": {\"type\": \"string\", \"minLength\": 1}, \"language\": {\"enum\": [\"zh-CN\", \"en\", null]}")

public let DOCTEST_RESULTS_SCHEMA = DOCTEST_RESULTS_V1_SCHEMA
    .replace("doctest-results.schema.json", "doctest-results-v2.schema.json")
    .replace("doctest results v1", "doctest results v2").replace("cjdoc.doctest/1", "cjdoc.doctest/2")
    .replace("\"jobs\", \"summary\", \"results\"", "\"jobs\", \"environmentFingerprint\", \"summary\", \"results\"")
    .replace("\"results\": {\"type\": \"array\"", "\"environmentFingerprint\": {\"type\": \"string\", \"pattern\": \"^[0-9a-f]{64}$\"},\n    \"results\": {\"type\": \"array\"")
    .replace("\"title\", \"language\", \"status\"", "\"title\", \"language\", \"documentationLanguage\", \"evidenceKey\", \"status\"")
    .replace("\"language\": {\"const\": \"cj\"}", "\"language\": {\"type\": \"string\"}, \"documentationLanguage\": {\"enum\": [\"zh-CN\", \"en\", null]}, \"evidenceKey\": {\"type\": \"string\"}")

public let SEARCH_INDEX_SCHEMA = SEARCH_INDEX_V8_SCHEMA
    .replace("search-index.schema.json", "search-index-v9.schema.json")
    .replace("cjdoc.search-index/8", "cjdoc.search-index/9")
    .replace("          \"externalDocs\":", "          \"fields\": {\"type\": \"array\", \"items\": {\"type\": \"object\", \"additionalProperties\": false, \"required\": [\"kind\", \"subject\", \"actualLanguage\", \"state\", \"text\"], \"properties\": {\"kind\": {\"type\": \"string\"}, \"subject\": {\"type\": \"string\"}, \"actualLanguage\": {\"enum\": [\"zh-CN\", \"en\", null]}, \"state\": {\"enum\": [\"complete\", \"fallback\", \"empty-fallback\", \"conflict-fallback\", \"empty\", \"conflict\", \"missing\", \"unknown\", \"unpaired\"]}, \"text\": {\"type\": \"string\"}}}},\n          \"externalDocs\":")

public let TRANSLATION_COVERAGE_SCHEMA = """
{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/translation-coverage.schema.json","title":"cjdoc translation coverage v1","type":"object","additionalProperties":false,"required":["schemaVersion","languages"],"properties":{"schemaVersion":{"const":"cjdoc.translation-coverage/1"},"languages":{"type":"array","maxItems":2,"items":{"type":"object","additionalProperties":false,"required":["language","total","translated","percent","fallback","missing","empty","unknown","conflict","unpaired","entries"],"properties":{"language":{"enum":["en","zh-CN"]},"total":{"type":"integer","minimum":0},"translated":{"type":"integer","minimum":0},"percent":{"type":"integer","minimum":0,"maximum":100},"fallback":{"type":"integer","minimum":0},"missing":{"type":"integer","minimum":0},"empty":{"type":"integer","minimum":0},"unknown":{"type":"integer","minimum":0},"conflict":{"type":"integer","minimum":0},"unpaired":{"type":"integer","minimum":0},"entries":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["symbolId","fieldId","kind","subject","state","actualLanguage"],"properties":{"symbolId":{"type":["string","null"]},"fieldId":{"type":"string"},"kind":{"type":"string"},"subject":{"type":"string"},"state":{"enum":["complete","fallback","missing","empty","unknown","conflict","unpaired"]},"actualLanguage":{"enum":["en","zh-CN",null]}}}}}}}}}
"""

public let SITE_MANIFEST_SCHEMA = """
{"$schema":"https://json-schema.org/draft/2020-12/schema","$id":"https://github.com/lIlIIlIll/cjdoc/blob/main/docs/schema/site-manifest.schema.json","title":"cjdoc site manifest v1","type":"object","additionalProperties":false,"required":["schemaVersion","project","version","routes"],"properties":{"schemaVersion":{"const":"cjdoc.site-manifest/1"},"project":{"type":"string"},"version":{"type":["string","null"]},"defaultLanguage":{"enum":["en","zh-CN",null]},"routes":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["language","pageId","symbolId","sectionId","href"],"properties":{"language":{"enum":["en","zh-CN"]},"pageId":{"type":["string","null"]},"symbolId":{"type":["string","null"]},"sectionId":{"type":["string","null"]},"ownerSymbolId":{"type":["string","null"]},"href":{"type":"string"}}}}}}
"""
