protected package cjdoc.cli

import cjdoc.schema_data.*

protected func schemaTextForCli(name: String): String {
    match (name) {
        case "list" => "doc-ir\ndoc-ir-v18\ndiagnostics\ncfg-matrix\nsearch-index\n" +
            "search-index-v11\nsymbol-index\nnavigation-index\napi-surface\napi-surface-v3\n" +
            "api-diff\napi-diff-v2\ndocumentation-coverage\ndocumentation-quality\n" +
            "versions\nversions-v2\ntranslation-coverage\nsite-manifest\nnavigation-index-v1\n" +
            "navigation-index-v2\nagent-full-index\ndeclaration\npage\nmachine-manifest\nquery-request\nquery-result\n" +
            "search-contract\nsource-provenance\n"
        case "doc-ir" => DOC_IR_SCHEMA
        case "doc-ir-v18" => DOC_IR_V18_SCHEMA
        case "source-provenance" => sourceProvenanceReceiptSchema()
        case "diagnostics" => DIAGNOSTICS_SCHEMA
        case "cfg-matrix" => CFG_MATRIX_SCHEMA
        case "search-index" => SEARCH_INDEX_SCHEMA
        case "search-index-v11" => SEARCH_INDEX_SCHEMA
        case "symbol-index" => SYMBOL_INDEX_SCHEMA
        case "navigation-index" | "navigation-index-v2" => NAVIGATION_INDEX_V2_SCHEMA
        case "navigation-index-v1" => NAVIGATION_INDEX_SCHEMA
        case "agent-full-index" | "declaration" | "page" | "machine-manifest" =>
            documentationArtifactSchema(name)
        case "query-request" => DOCUMENTATION_QUERY_REQUEST_SCHEMA
        case "query-result" => documentationQueryResultSchema()
        // The search contract is not a JSON Schema; it is the published rule
        // table both executors read, exported for consumers and diff tests.
        case "search-contract" => documentationSearchContract()
        case "api-surface" => API_SURFACE_SCHEMA
        case "api-surface-v3" => API_SURFACE_SCHEMA
        case "api-diff" => API_DIFF_SCHEMA
        case "api-diff-v2" => API_DIFF_SCHEMA
        case "documentation-coverage" => DOCUMENTATION_COVERAGE_SCHEMA
        case "documentation-quality" => DOCUMENTATION_QUALITY_SCHEMA
        case "versions" => VERSIONS_SCHEMA
        case "versions-v2" => VERSIONS_SCHEMA
        case "translation-coverage" => TRANSLATION_COVERAGE_SCHEMA
        case "site-manifest" => SITE_MANIFEST_SCHEMA
        case _ => throw IllegalArgumentException("unknown schema '${name}'")
    }
}

protected func runSchema(name: String): Int64 {
    print(schemaTextForCli(name))
    0
}
