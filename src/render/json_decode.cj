package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

public func decodeDocIr(text: String): DocumentationSet {
    let parsed = JsonNode.parse(text, config: JsonReadOptions(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH,
        maxStringBytes: DOC_IR_MAX_JSON_STRING_BYTES,
        maxBufferedValueBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES,
        maxInputBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES))
    let rawShape = validateRawSchemaShape(parsed)
    validatePortablePathFields(parsed, "$")
    validateDeclarativeSchema(parsed)
    let root = strictObject(parsed, "$", ["schemaVersion", "generator", "status", "apiCollectionState", "project",
        "configuration", "providers", "modules", "packages", "files", "declarations", "assets",
        "orphanDocComments", "macroInvocations", "unsupportedDeclarations",
        "unboundSemanticDeclarations", "diagnostics", "languageOptions", "pages", "readingLanguage", "externalDocumentation"])
    let version = stringAt(root, "schemaVersion", "$")
    let legacyV6 = version == DOC_IR_V6_SCHEMA_VERSION
    let legacy = legacyV6 || version == DOC_IR_V7_SCHEMA_VERSION
    let legacyV8 = version == DOC_IR_V8_SCHEMA_VERSION
    let legacyV9 = version == DOC_IR_V9_SCHEMA_VERSION
    let legacyV10 = version == DOC_IR_V10_SCHEMA_VERSION
    let legacyV11 = version == DOC_IR_V11_SCHEMA_VERSION
    let legacyV12 = version == DOC_IR_V12_SCHEMA_VERSION
    let legacyV13 = version == DOC_IR_V13_SCHEMA_VERSION
    let current = version == DOC_IR_SCHEMA_VERSION
    let modern = legacyV9 || legacyV10 || legacyV11 || legacyV12 || legacyV13 || current
    if (!legacy && !legacyV8 && !modern) {
        fail("$.schemaVersion", "expected '${DOC_IR_SCHEMA_VERSION}', '${DOC_IR_V13_SCHEMA_VERSION}', " +
            "'${DOC_IR_V12_SCHEMA_VERSION}', '${DOC_IR_V11_SCHEMA_VERSION}', " +
            "'${DOC_IR_V10_SCHEMA_VERSION}', '${DOC_IR_V9_SCHEMA_VERSION}', " +
            "'${DOC_IR_V8_SCHEMA_VERSION}', '${DOC_IR_V7_SCHEMA_VERSION}', or " +
            "'${DOC_IR_V6_SCHEMA_VERSION}'")
    }
    let generator = strictObject(required(root, "generator", "$") , "$.generator", ["name", "version"])
    let project = strictObject(required(root, "project", "$.project"), "$.project",
        if (modern) { ["name", "kind", "repository"] }
        else { ["name", "kind"] })
    let configuration = strictObject(required(root, "configuration", "$") ,
        "$.configuration", ["audience", "lintProfile", "cfgProfile"])
    let modules = decodeModules(root, legacy, modern)
    let legacyModules = buildLegacyModuleIndex(modules)
    let legacyIds = if (legacyV6) { buildLegacySymbolIds(root, legacyModules) }
        else { HashMap<String, String>() }
    let decodedAssets = decodeAssets(root, legacy)
    let documentation = DocumentationSet(GeneratorInfo(stringAt(generator, "name", "$.generator"),
        stringAt(generator, "version", "$.generator")), stringAt(root, "status", "$"),
        ProjectInfo(stringAt(project, "name", "$.project"), kind: stringAt(project, "kind", "$.project"),
            repository: if (modern) {
                nullableRepositoryAt(project, "repository", "$.project")
            } else { None }),
        ConfigurationSnapshot(audience: stringAt(configuration, "audience", "$.configuration"),
            lintProfile: stringAt(configuration, "lintProfile", "$.configuration"),
            cfgProfile: stringAt(configuration, "cfgProfile", "$.configuration")),
        providers: decodeProviders(root, modules, legacyV6, rawShape, text.size), modules: modules,
        packages: decodePackages(root, legacy, legacyV6, legacyIds),
        files: decodeFiles(root), declarations: decodeDeclarations(root, legacyV6, legacy,
            legacyModules, legacyIds, decodedAssets.references),
        assets: decodedAssets.assets,
        orphanDocComments: decodeOrphans(root), macroInvocations: decodeMacros(root),
        unsupportedDeclarations: decodeUnsupported(root), unboundSemanticDeclarations: decodeUnbound(root),
        diagnostics: decodeDiagnostics(root, legacyV6, legacyIds),
        languageOptions: decodeDocumentationLanguageOptions(root.get("languageOptions"), "$.languageOptions"),
        pages: decodeDocumentationPages(root.get("pages"), decodedAssets.references),
        readingLanguage: optionalDocumentationLanguage(root.get("readingLanguage"), "$.readingLanguage"),
        externalDocumentation: decodeExternalDocumentation(root.get("externalDocumentation")),
        apiCollectionState: if (current) { Some(stringAt(root, "apiCollectionState", "$")) } else { None })
    validateDocumentationSet(documentation)
    documentation
}
