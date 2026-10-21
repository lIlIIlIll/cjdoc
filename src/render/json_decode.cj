package cjdoc.render

import cjdoc.model.*
import yjson.*

public func decodeDocIr(text: String): DocumentationSet {
    let parsed = JsonNode.parse(text, config: JsonReadOptions(
        duplicateKeyPolicy: JsonDuplicateKeyPolicy.Reject,
        maxDepth: DOC_IR_CODEC_MAX_NESTING_DEPTH,
        maxStringBytes: DOC_IR_MAX_JSON_STRING_BYTES,
        maxBufferedValueBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES,
        maxInputBytes: DOC_IR_MAX_JSON_DOCUMENT_BYTES))
    validateRawSchemaShape(parsed)
    validatePortablePathFields(parsed, "$")
    validateDeclarativeSchema(parsed)
    let root = strictObject(parsed, "$", ["schemaVersion", "generator", "status", "apiCollectionState",
        "documentationRevision", "project", "configuration", "providers", "modules", "packages", "files",
        "declarations", "assets", "orphanDocComments", "macroInvocations", "unsupportedDeclarations",
        "unboundSemanticDeclarations", "diagnostics", "languageOptions", "pages", "readingLanguage",
        "externalDocumentation", "dependencies", "documentSets"])
    let generator = strictObject(required(root, "generator", "$"), "$.generator",
        ["name", "version", "toolchain"])
    let project = strictObject(required(root, "project", "$"), "$.project",
        ["name", "kind", "repository"])
    let configuration = strictObject(required(root, "configuration", "$"), "$.configuration",
        ["audience", "lintProfile", "cfgProfile"])
    let documentation = DocumentationSet(
        GeneratorInfo(stringAt(generator, "name", "$.generator"),
            stringAt(generator, "version", "$.generator"),
            toolchain: stringAt(generator, "toolchain", "$.generator")),
        stringAt(root, "status", "$"),
        ProjectInfo(stringAt(project, "name", "$.project"),
            kind: stringAt(project, "kind", "$.project"),
            repository: nullableRepositoryAt(project, "repository", "$.project")),
        ConfigurationSnapshot(audience: stringAt(configuration, "audience", "$.configuration"),
            lintProfile: stringAt(configuration, "lintProfile", "$.configuration"),
            cfgProfile: stringAt(configuration, "cfgProfile", "$.configuration")),
        providers: decodeProviders(root),
        modules: decodeModules(root),
        packages: decodePackages(root),
        files: decodeFiles(root),
        declarations: decodeDeclarations(root),
        assets: decodeAssets(root),
        orphanDocComments: decodeOrphans(root),
        macroInvocations: decodeMacros(root),
        unsupportedDeclarations: decodeUnsupported(root),
        unboundSemanticDeclarations: decodeUnbound(root),
        diagnostics: decodeDiagnostics(root),
        languageOptions: decodeDocumentationLanguageOptions(root.get("languageOptions"), "$.languageOptions"),
        pages: decodeDocumentationPages(root.get("pages")),
        readingLanguage: optionalDocumentationLanguage(root.get("readingLanguage"), "$.readingLanguage"),
        externalDocumentation: decodeExternalDocumentation(root.get("externalDocumentation")),
        dependencies: decodeDependencyInstances(root.get("dependencies")),
        documentSets: decodeDocumentSetIdentities(root.get("documentSets")),
        apiCollectionState: Some(stringAt(root, "apiCollectionState", "$")),
        documentationRevision: stringAt(root, "documentationRevision", "$"))
    validateDocumentationSet(documentation)
    documentation
}
