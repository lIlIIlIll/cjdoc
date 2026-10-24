package cjdoc

import cjdoc.model.*
import cjdoc.schema_data.*
import yjson.*
import yjson_algorithms.*

internal func validateQueryVersionCatalog(catalog: JsonObject): Unit {
    // Keep the published schema frozen. Its lookahead-based path constraint is
    // checked below instead of being passed to the bounded linear regex engine.
    let definition = JsonNode.parse(VERSIONS_SCHEMA).asObject()
    definition.get("$defs").getOrThrow().asObject().get("safePath").getOrThrow()
        .asObject().put("pattern", JsonNode.string("^.+$"))
    let maxWork = DOC_IR_MAX_SCHEMA_OBJECTS * 64 + DOC_IR_MAX_SCHEMA_ARRAY_ITEMS * 4
    let schema = JsonSchema.parse(definition.toJson(), config: JsonSchemaConfig(
        limits: JsonSchemaLimits(maxEvaluations: maxWork,
            maxRefResolutions: maxWork, maxRegexSteps: maxWork * 4, maxErrors: 20)))
    if (!schema.validate(catalog).isEmpty()) {
        throw DocumentationQueryException("unavailable", "invalid_version_catalog",
            "The explicit version catalog does not satisfy cjdoc.versions/2.")
    }
    let versions = catalog.get("versions").getOrThrow().asArray()
    for (index in 0..versions.size()) {
        let version = versions[index].asObject()
        for (field in ["basePath", "index", "symbolIndex", "apiDiff"]) {
            let value = version.get(field).getOrThrow()
            if (!value.isNull) { validateQueryVersionPath(value.asString()) }
        }
        if (let Some(languages) <- version.get("languages")) {
            let entries = languages.asArray()
            for (position in 0..entries.size()) {
                let language = entries[position].asObject()
                validateQueryVersionPath(queryString(language, "root"))
                validateQueryVersionPath(queryString(language, "index"))
            }
        }
    }
}

private func validateQueryVersionPath(value: String): Unit {
    queryResourcePath(value)
    for (segment in value.split("/")) {
        if (segment == "latest") {
            throw DocumentationQueryException("unavailable", "unsafe_version_path",
                "A captured version root cannot itself be the moving latest alias.")
        }
    }
}
