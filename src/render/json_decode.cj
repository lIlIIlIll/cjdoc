package cjdoc.render

import cjdoc.model.*
import std.collection.*
import yjson.*

public func decodeDocIr(text: String): DocumentationSet {
    let parsed = YJson.parse(text, config: JsonReadConfig(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        limits: JsonReadLimits(maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH,
            maxStringBytes: DOC_IR_MAX_JSON_STRING_BYTES,
            maxBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES)))
    let rawShape = validateRawSchemaShape(parsed)
    validateDeclarativeSchema(parsed)
    let root = strictObject(parsed, "$", ["schemaVersion", "generator", "status", "project",
        "configuration", "providers", "modules", "packages", "files", "declarations", "assets",
        "orphanDocComments", "macroInvocations", "unsupportedDeclarations",
        "unboundSemanticDeclarations", "diagnostics"])
    let version = stringAt(root, "schemaVersion", "$")
    let legacyV6 = version == DOC_IR_V6_SCHEMA_VERSION
    let legacy = legacyV6 || version == DOC_IR_V7_SCHEMA_VERSION
    if (!legacy && version != DOC_IR_SCHEMA_VERSION) {
        fail("$.schemaVersion", "expected '${DOC_IR_SCHEMA_VERSION}', " +
            "'${DOC_IR_V7_SCHEMA_VERSION}', or '${DOC_IR_V6_SCHEMA_VERSION}'")
    }
    let generator = strictObject(required(root, "generator", "$"), "$.generator", ["name", "version"])
    let project = strictObject(required(root, "project", "$"), "$.project", ["name", "kind"])
    let configuration = strictObject(required(root, "configuration", "$"), "$.configuration",
        ["audience", "lintProfile", "cfgProfile"])
    let modules = decodeModules(root, legacy)
    let legacyModules = buildLegacyModuleIndex(modules)
    let legacyIds = if (legacyV6) { buildLegacySymbolIds(root, legacyModules) }
        else { HashMap<String, String>() }
    let decodedAssets = decodeAssets(root, legacy)
    let documentation = DocumentationSet(GeneratorInfo(stringAt(generator, "name", "$.generator"),
        stringAt(generator, "version", "$.generator")), stringAt(root, "status", "$"),
        ProjectInfo(stringAt(project, "name", "$.project"), kind: stringAt(project, "kind", "$.project")),
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
        diagnostics: decodeDiagnostics(root, legacyV6, legacyIds))
    validateDocumentationSet(documentation)
    documentation
}
