package cjdoc_core

import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let FIXTURE_PROJECTS = "../../tests/fixtures/projects/"

private func hasDiagnostic(documentation: DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    return false
}

private class CanonicalTestSemanticProvider <: SemanticProvider {
    public func providerName(): String { "test-canonical" }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let result = SemanticResult(providerName(), SemanticCapabilities(true, true, true, true, true))
        for (declaration in source.declarations) {
            let semantic = SemanticDeclaration(declaration.sourceKey, declaration.kind, declaration.name,
                declaration.packageName, declaration.ownerSourceKey, declaration.visibility, "resolved",
                providerName(), canonicalSignature: Some("demo.parse(demo.Real): demo.Result"),
                isContainer: declaration.isContainer)
            semantic.parameters.add(SemanticParameter("value",
                TypeRef("Alias", canonical: Some("demo.Real"), state: "resolved")))
            semantic.returnType = Some(TypeRef("Result", canonical: Some("demo.Result"), state: "resolved"))
            result.declarations.add(semantic)
        }
        return result
    }
}

private class EmptyTestSemanticProvider <: SemanticProvider {
    public func providerName(): String { "test-empty" }

    public func analyze(_: SourceSnapshot): SemanticResult {
        SemanticResult(providerName(), SemanticCapabilities(false, false, false, false, false))
    }
}

private class DishonestTestSemanticProvider <: SemanticProvider {
    public func providerName(): String { "test-dishonest" }

    public func analyze(source: SourceSnapshot): SemanticResult {
        let result = SemanticResult(providerName(),
            SemanticCapabilities(true, true, true, false, false))
        for (declaration in source.declarations) {
            let semantic = SemanticDeclaration(declaration.sourceKey, declaration.kind, declaration.name,
                declaration.packageName, declaration.ownerSourceKey, declaration.visibility, "resolved",
                providerName(), canonicalSignature: Some("forbidden.signature"),
                isContainer: declaration.isContainer)
            for (parameter in declaration.parameters) {
                semantic.parameters.add(SemanticParameter(parameter.name,
                    TypeRef(parameter.typeSpelling, canonical: Some("forbidden.Type"), state: "resolved")))
            }
            result.declarations.add(semantic)
        }
        return result
    }
}

@Test
class CjdocContractsTest {
    @TestCase
    func parsesMarkdownAndStructuredTags(): Unit {
        let parsed = parseDocComment("""
/**
 * Summary paragraph.
 *
 * Description paragraph.
 *
 * ```cj
 * @param notATag code
 * ```
 * @param value input value
 * @return output value
 * @throws Exception failure
 * @see demo.value
 * @since 1.0
 * @deprecated use newValue
 * @author Cjdoc
 * @version 2
 */
""")
        @Expect(parsed.summaryMarkdown, "Summary paragraph.")
        @Expect(parsed.descriptionMarkdown.contains("@param notATag code"))
        @Expect(parsed.params.size, 1)
        @Expect(parsed.params[0].subject, "value")
        @Expect(parsed.params[0].description, "input value")
        @Expect(parsed.returnTagCount, 1)
        @Expect(parsed.throwsTags.size, 1)
        @Expect(parsed.see.size, 1)
        @Expect(parsed.since.getOrThrow(), "1.0")
        @Expect(parsed.deprecated.getOrThrow(), "use newValue")
        @Expect(parsed.authors[0], "Cjdoc")
        @Expect(parsed.version.getOrThrow(), "2")
        let brokenSee = parseDocComment("/** @see */")
        @Expect(brokenSee.see.size, 1)
        @Expect(brokenSee.see[0].subject, "")
    }

    @TestCase
    func symbolIdsDistinguishOverloadsWithoutLocations(): Unit {
        let text = makeSymbolId("demo", "::Parser", "function", "parse", 0, ["String"])
        let bytes = makeSymbolId("demo", "::Parser", "function", "parse", 0, ["Array < UInt8 >"])
        @Expect(text != bytes)
        @Expect(text.contains("String"))
        @Expect(!text.contains(".cj"))
        @Expect(!text.contains(":42:"))
    }

    @TestCase
    func semanticProviderControlsCanonicalIdentityThroughBinder(): Unit {
        let source = SourceSnapshot("demo")
        let location = SourceLocation("src/api.cj", 3, 1, 4, 1)
        let declaration = SourceDeclaration("src/api.cj:3:1:function:parse", "function", "parse",
            "demo", "public", location, "public func parse(value: Alias): Result")
        declaration.parameters.add(SourceParameter("value", "Alias"))
        declaration.returnTypeSpelling = Some("Result")
        source.declarations.add(declaration)
        let pkg = SourcePackage("demo")
        pkg.sourceFiles.add("src/api.cj")
        source.packages.add(pkg)

        let provider = CanonicalTestSemanticProvider()
        let semantic = provider.analyze(source)
        @Expect(semantic.capabilities.sourceBinding)
        @Expect(semantic.capabilities.canonicalTypes)
        @Expect(semantic.capabilities.canonicalSignatures)
        let documentation = DocumentationBinder().bind(source, semantic)
        @Expect(documentation.symbols.size, 1)
        @Expect(documentation.symbols[0].semanticState, "resolved")
        @Expect(documentation.symbols[0].semanticProvider, "test-canonical")
        @Expect(documentation.symbols[0].id.contains("demo.Real"))
        @Expect(!documentation.symbols[0].id.contains("Alias"))
        @Expect(documentation.symbols[0].canonicalSignature.getOrThrow(),
            "demo.parse(demo.Real): demo.Result")
        @Expect(renderDocumentationJson(documentation).contains(
            "\"canonicalSignature\":\"demo.parse(demo.Real): demo.Result\""))
    }

    @TestCase
    func missingSemanticDeclarationFallsBackExplicitly(): Unit {
        let source = SourceSnapshot("demo")
        let location = SourceLocation("src/api.cj", 1, 1, 2, 1)
        let declaration = SourceDeclaration("src/api.cj:1:1:function:parse", "function", "parse",
            "demo", "public", location, "public func parse(value: Alias): Result")
        declaration.parameters.add(SourceParameter("value", "Alias"))
        source.declarations.add(declaration)
        let documentation = DocumentationBinder().bind(source, EmptyTestSemanticProvider().analyze(source))
        @Expect(documentation.symbols.size, 1)
        @Expect(documentation.symbols[0].semanticState, "unavailable")
        @Expect(documentation.symbols[0].semanticProvider, "test-empty")
        @Expect(documentation.symbols[0].parameters[0].typeRef.state, "partial")
        @Expect(hasDiagnostic(documentation, "CJDOC1007"))
        @Expect(!hasFatalDiagnostics(documentation))
    }

    @TestCase
    func semanticCapabilitiesAreEnforcedAndReported(): Unit {
        let source = SourceSnapshot("demo")
        let location = SourceLocation("src/api.cj", 1, 1, 2, 1)
        let declaration = SourceDeclaration("src/api.cj:1:1:function:parse", "function", "parse",
            "demo", "public", location, "public func parse(value: Alias)")
        declaration.parameters.add(SourceParameter("value", "Alias"))
        source.declarations.add(declaration)

        let provider = DishonestTestSemanticProvider()
        let documentation = DocumentationBinder().bind(source, provider.analyze(source),
            expectedProvider: Some(provider.providerName()))
        @Expect(documentation.semanticBinding.matched, 1)
        @Expect(documentation.semanticBinding.missing, 0)
        @Expect(documentation.semanticBinding.contractViolations, 2)
        @Expect(documentation.symbols[0].parameters[0].typeRef.display, "Alias")
        @Expect(documentation.symbols[0].parameters[0].typeRef.canonical.isNone())
        @Expect(documentation.symbols[0].parameters[0].typeRef.state, "partial")
        @Expect(documentation.symbols[0].canonicalSignature.isNone())
        @Expect(hasDiagnostic(documentation, "CJDOC1017"))
        @Expect(!hasFatalDiagnostics(documentation))
    }

    @TestCase
    func defaultDriverSelectsAstProviderExplicitly(): Unit {
        @Expect(defaultSemanticProvider().providerName(), "ast")
        let documentation = DocumentationDriver(AstSourceProvider(),
            defaultSemanticProvider()).generate(FIXTURE_PROJECTS + "functions")
        @Expect(documentation.semanticBinding.provider, "ast")
        @Expect(documentation.semanticBinding.matched, documentation.symbols.size)
        @Expect(documentation.semanticBinding.contractViolations, 0)
    }

    @TestCase
    func bindingStatsDistinguishAmbiguousAndExtraneousDeclarations(): Unit {
        let source = SourceSnapshot("demo")
        let location = SourceLocation("src/api.cj", 1, 1, 2, 1)
        let declaration = SourceDeclaration("source-key", "function", "parse", "demo", "public",
            location, "public func parse()")
        source.declarations.add(declaration)
        let result = SemanticResult("test", SemanticCapabilities(true, true, true, false, false))
        result.declarations.add(SemanticDeclaration("source-key", "function", "parse", "demo",
            None, "public", "partial", "test"))
        result.declarations.add(SemanticDeclaration("source-key", "function", "parse", "demo",
            None, "public", "partial", "test"))
        result.declarations.add(SemanticDeclaration("extra-key", "function", "extra", "demo",
            None, "public", "partial", "test"))

        let documentation = DocumentationBinder().bind(source, result)
        @Expect(documentation.semanticBinding.matched, 0)
        @Expect(documentation.semanticBinding.missing, 0)
        @Expect(documentation.semanticBinding.ambiguous, 1)
        @Expect(documentation.semanticBinding.extraneous, 1)
        @Expect(documentation.semanticBinding.contractViolations, 0)
        @Expect(documentation.symbols[0].semanticState, "ambiguous")
    }

    @TestCase
    func jsonEscapingIsValidAndUnicodePreserving(): Unit {
        @Expect(jsonEscape("仓颉\n\"\\\t"), "\"仓颉\\n\\\"\\\\\\t\"")
        @Expect(jsonEscape("\u{0001}"), "\"\\u0001\"")
    }

    @TestCase
    func goldenProjectProducesDeterministicDocIr(): Unit {
        let root = FIXTURE_PROJECTS + "basic"
        let first = generateDocumentation(root)
        lintDocumentation(first, true)
        let firstJson = renderDocumentationJson(first)
        let second = generateDocumentation(root)
        lintDocumentation(second, true)
        let secondJson = renderDocumentationJson(second)
        @Expect(firstJson, secondJson)
        let parallel = generateDocumentation(root, jobs: 4)
        lintDocumentation(parallel, true)
        @Expect(renderDocumentationJson(parallel), firstJson)
        @Expect(first.symbols.size, 25)
        @Expect(first.diagnostics.size, 0)
        @Expect(!firstJson.contains("/home/"))
        @Expect(firstJson.contains("cjdoc.doc-ir/4"))
        @Expect(firstJson.contains("\"kind\":\"superType\",\"target\":{\"display\":\"Reader\",\"canonical\":null,\"state\":\"partial\"}"))
        @Expect(firstJson.contains("\"kind\":\"extensionTarget\",\"target\":{\"display\":\"Box < String >\",\"canonical\":null,\"state\":\"partial\"}"))
        @Expect(firstJson.contains("function:parse#g0(String)"))
        @Expect(firstJson.contains("function:parse#g0(Array<UInt8>)"))
        @Expect(firstJson.contains("extend:Box<String>{function%3Alength%23g0%28%29}"))
        @Expect(firstJson.contains("extend:Box<String>{function%3Apretty%23g0%28%29}"))
        @Expect(firstJson.contains("enumCase:Ready#g0()"))
        @Expect(firstJson.contains("public func multiline(\\n    text: String,\\n    strict: Bool\\n): String"))
        let resolved = resolveDocReference(first, "basic.parse(String)").getOrThrow()
        @Expect(resolved.id.contains("function:parse#g0(String)"))
        @Expect(docReferenceMatches(first, "basic.parse").size, 2)
        @Expect(resolveDocReference(first, "basic.parse(Array<UInt8>)").getOrThrow().parameters[0].name, "data")
        @Expect(resolveDocReference(first, "basic.multiline(String,Bool)").isSome())
        @Expect(resolveDocReference(first, "basic.multiline(Array<String,Bool>)").isNone())
    }

    @TestCase
    func persistentSourceCacheIsExactRecoverableAndDeterministic(): Unit {
        let root = FIXTURE_PROJECTS + "basic"
        let cache = "/tmp/cjdoc-source-cache-contract"
        let _ = removeIfExists(cache, recursive: true)

        let coldProvider = AstSourceProvider(cacheDirectory: Some(cache),
            cacheFingerprint: Some("sdk-a"), jobs: 4)
        let cold = DocumentationDriver(coldProvider, AstSemanticProvider()).generate(root)
        let coldJson = renderDocumentationJson(cold)
        @Expect(coldProvider.cacheStats.hits, 0)
        @Expect(coldProvider.cacheStats.misses, 1)
        @Expect(coldProvider.cacheStats.writes, 1)

        let hotProvider = AstSourceProvider(cacheDirectory: Some(cache),
            cacheFingerprint: Some("sdk-a"), jobs: 4)
        let hot = DocumentationDriver(hotProvider, AstSemanticProvider()).generate(root)
        @Expect(renderDocumentationJson(hot), coldJson)
        @Expect(hotProvider.cacheStats.hits, 1)
        @Expect(hotProvider.cacheStats.misses, 0)

        let changedSdkProvider = AstSourceProvider(cacheDirectory: Some(cache),
            cacheFingerprint: Some("sdk-b"))
        let changedSdk = DocumentationDriver(changedSdkProvider, AstSemanticProvider()).generate(root)
        @Expect(renderDocumentationJson(changedSdk), coldJson)
        @Expect(changedSdkProvider.cacheStats.hits, 0)
        @Expect(changedSdkProvider.cacheStats.misses, 1)

        for (entry in Directory.readFrom(cache)) {
            if (entry.isRegular() && entry.name.endsWith(".cache")) {
                File.writeTo(entry.path, "not a cache entry".toArray())
            }
        }
        let recoveredProvider = AstSourceProvider(cacheDirectory: Some(cache),
            cacheFingerprint: Some("sdk-a"))
        let recovered = DocumentationDriver(recoveredProvider, AstSemanticProvider()).generate(root)
        @Expect(renderDocumentationJson(recovered), coldJson)
        @Expect(recoveredProvider.cacheStats.corruptEntries, 1)
        @Expect(recoveredProvider.cacheStats.writes, 1)
        let _ = removeIfExists(cache, recursive: true)
    }

    @TestCase
    func sourceCacheInvalidatesOnlyTheChangedFile(): Unit {
        let root = "/tmp/cjdoc-source-cache-invalidation"
        let cache = root + "/cache"
        let _ = removeIfExists(root, recursive: true)
        Directory.create(Path(root).join("src"), recursive: true)
        File.writeTo(Path(root).join("cjpm.toml"), """
[package]
cjc-version = "1.1.0"
name = "cache_invalidation"
version = "0.1.0"
output-type = "static"
""".toArray())
        File.writeTo(Path(root).join("src/a.cj"), """
package cache_invalidation
public func first(): Int64 { 1 }
""".toArray())
        File.writeTo(Path(root).join("src/b.cj"), """
package cache_invalidation
public func second(): Int64 { 2 }
""".toArray())

        let coldProvider = AstSourceProvider(cacheDirectory: Some(cache),
            cacheFingerprint: Some("sdk"), jobs: 2)
        let cold = DocumentationDriver(coldProvider, AstSemanticProvider()).generate(root)
        @Expect(coldProvider.cacheStats.misses, 2)
        @Expect(coldProvider.cacheStats.hits, 0)

        let hotProvider = AstSourceProvider(cacheDirectory: Some(cache),
            cacheFingerprint: Some("sdk"), jobs: 2)
        let hot = DocumentationDriver(hotProvider, AstSemanticProvider()).generate(root)
        @Expect(renderDocumentationJson(hot), renderDocumentationJson(cold))
        @Expect(hotProvider.cacheStats.hits, 2)

        File.writeTo(Path(root).join("src/b.cj"), """
package cache_invalidation
public func changed(): Int64 { 3 }
""".toArray())
        let changedProvider = AstSourceProvider(cacheDirectory: Some(cache),
            cacheFingerprint: Some("sdk"), jobs: 2)
        let changed = DocumentationDriver(changedProvider, AstSemanticProvider()).generate(root)
        @Expect(changedProvider.cacheStats.hits, 1)
        @Expect(changedProvider.cacheStats.misses, 1)
        @Expect(renderDocumentationJson(changed) != renderDocumentationJson(cold))
        let _ = removeIfExists(root, recursive: true)
    }

    @TestCase
    func isolatedAstPreflightFailureSkipsOnlyTheAffectedSource(): Unit {
        let provider = AstSourceProvider(
            astPreflightExecutable: Some("/tmp/cjdoc-preflight-that-does-not-exist"))
        let documentation = DocumentationDriver(provider, AstSemanticProvider()).generate(
            FIXTURE_PROJECTS + "basic")
        @Expect(documentation.symbols.size, 0)
        @Expect(documentation.diagnostics.size, 1)
        @Expect(documentation.diagnostics[0].code, "CJDOC1020")
        @Expect(!hasFatalDiagnostics(documentation))
    }

    @TestCase
    func inaccessibleProjectBecomesDiagnostic(): Unit {
        let documentation = generateDocumentation("/tmp/cjdoc-project-that-does-not-exist")
        @Expect(documentation.symbols.size, 0)
        @Expect(documentation.diagnostics.size, 1)
        @Expect(documentation.diagnostics[0].code, "CJDOC1010")
        @Expect(documentation.diagnostics[0].severity, "error")
    }

    @TestCase
    func sourceModelIncludesPrimaryConstructorAndEnumCases(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "types")
        @Expect(documentation.diagnostics.size, 0)
        @Expect(documentation.symbols.size, 11)
        var sawConstructor = false
        var sawIdle = false
        var sawFailed = false
        for (symbol in documentation.symbols) {
            if (symbol.kind == "constructor" && symbol.name == "Point") {
                sawConstructor = true
                @Expect(symbol.parameters.size, 2)
                @Expect(symbol.sourceSignature, "public Point(public let x: Int64, public let y: Int64)")
            } else if (symbol.kind == "enumCase" && symbol.name == "Idle") {
                sawIdle = true
                @Expect(symbol.source.startLine > 0)
                @Expect(symbol.documentation.isSome())
            } else if (symbol.kind == "enumCase" && symbol.name == "Failed") {
                sawFailed = true
                @Expect(symbol.parameters.size, 1)
                @Expect(symbol.parameters[0].typeRef.display, "String")
            }
        }
        @Expect(sawConstructor)
        @Expect(sawIdle)
        @Expect(sawFailed)
    }

    @TestCase
    func publicOnlyKeepsReachableApiAndExtensionOwners(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "extend_visibility")
        retainPublicApi(documentation)
        @Expect(documentation.symbols.size, 8)
        let json = renderDocumentationJson(documentation)
        @Expect(!json.contains("hiddenMember"))
        @Expect(!json.contains("hiddenExtensionMember"))
        @Expect(!json.contains("packageOnly"))
        @Expect(!json.contains("fileOnly"))
        @Expect(json.contains("function:length"))
        @Expect(json.contains("function:pretty"))
    }

    @TestCase
    func lintCodesRemainStable(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "lint")
        lintDocumentation(documentation, true)
        @Expect(documentation.diagnostics.size, 7)
        @Expect(hasDiagnostic(documentation, "CJDOC1001"))
        @Expect(hasDiagnostic(documentation, "CJDOC1002"))
        @Expect(hasDiagnostic(documentation, "CJDOC1003"))
        @Expect(hasDiagnostic(documentation, "CJDOC1004"))
        @Expect(hasDiagnostic(documentation, "CJDOC1005"))
        @Expect(hasDiagnostic(documentation, "CJDOC1008"))
        var referenceDiagnostics: Int64 = 0
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC1008") { referenceDiagnostics++ }
        }
        @Expect(referenceDiagnostics, 2)
    }

    @TestCase
    func malformedFileProducesPartialDocIr(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "recovery")
        @Expect(documentation.symbols.size, 1)
        @Expect(documentation.symbols[0].name, "good")
        @Expect(documentation.diagnostics.size, 1)
        @Expect(documentation.diagnostics[0].code, "CJDOC1011")
        @Expect(!hasFatalDiagnostics(documentation))
        @Expect(hasErrorDiagnostics(documentation))
        @Expect(renderDocumentationJson(documentation).contains("function:good"))
    }

    @TestCase
    func crlfUnicodeLocationsAndPublicOwnerFilteringAreStable(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "source_edges")
        @Expect(documentation.projectName, "source_edges_fixture")
        @Expect(documentation.diagnostics.size, 0)
        var sawUnicode = false
        for (symbol in documentation.symbols) {
            if (symbol.name == "解析") {
                sawUnicode = true
                @Expect(symbol.source.startLine, 3)
                @Expect(symbol.source.startColumn, 24)
                @Expect(symbol.sourceSignature, "public func 解析(文本: String): String")
                @Expect(symbol.documentation.getOrThrow().summaryMarkdown, "中文摘要。")
            }
        }
        @Expect(sawUnicode)

        retainPublicApi(documentation)
        let json = renderDocumentationJson(documentation)
        @Expect(documentation.symbols.size, 3)
        @Expect(json.contains("inherited"))
        @Expect(!json.contains("hidden"))
        @Expect(!json.contains("PrivateOwner"))
        @Expect(!json.contains("mustNotLeak"))
    }

    @TestCase
    func crlfMultilineSourceSpellingIsCanonicalized(): Unit {
        let root = "/tmp/cjdoc-crlf-source-spelling"
        let _ = removeIfExists(root, recursive: true)
        Directory.create(Path(root).join("src"), recursive: true)
        File.writeTo(Path(root).join("cjpm.toml"), """
[package]
cjc-version = "1.1.0"
name = "crlf_source_spelling"
version = "0.1.0"
output-type = "static"
""".toArray())
        File.writeTo(Path(root).join("src/api.cj"), (
            "package crlf_source_spelling\r\n\r\n" +
            "/** Multiline. */\r\n" +
            "public func multiline(\r\n" +
            "    text: String,\r\n" +
            "    strict: Bool\r\n" +
            "): String { text }\r\n").toArray())

        let documentation = generateDocumentation(root)
        @Expect(documentation.diagnostics.size, 0)
        @Expect(documentation.symbols.size, 1)
        @Expect(documentation.symbols[0].sourceSignature,
            "public func multiline(\n    text: String,\n    strict: Bool\n): String")
        @Expect(!renderDocumentationJson(documentation).contains("\\r"))
        let _ = removeIfExists(root, recursive: true)
    }

    @TestCase
    func workspaceUsesOnlyDeclaredMembers(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "workspace")
        @Expect(documentation.projectName, "workspace")
        @Expect(documentation.diagnostics.size, 0)
        @Expect(documentation.packages.size, 2)
        @Expect(documentation.symbols.size, 2)
        let json = renderDocumentationJson(documentation)
        @Expect(json.contains("workspace_alpha"))
        @Expect(json.contains("workspace_beta"))
        @Expect(json.contains("packages/alpha/src/alpha.cj"))
        @Expect(!json.contains("workspace_ignored"))
        @Expect(!json.contains("ignored.cj"))
    }

    @TestCase
    func manifestPackageNameIsProjectTruth(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "functions")
        @Expect(documentation.projectName, "functions_fixture")
    }

    @TestCase
    func cjpmManifestAdapterKeepsTomlSubsetAtOneBoundary(): Unit {
        let manifest = """
[package]
name = "demo"

[workspace]
members = [
  "packages/a",
  'packages/b'
]

[dependencies]
plain = "1.0.0"
local = {
  path = "../local",
  output-type = "static"
}
commented = { git = "https://example.test/path=value" } # path = "ignored"
"""
        let parsed = parseCjpmManifest(manifest)
        @Expect(parsed.packageName.getOrThrow(), "demo")
        @Expect(parsed.workspaceMembers.size, 2)
        @Expect(parsed.workspaceMembers[0], "packages/a")
        @Expect(parsed.workspaceMembers[1], "packages/b")
        @Expect(parsed.pathDependencies.size, 1)
        @Expect(parsed.pathDependencies[0], "../local")
    }

    @TestCase
    func hostPathNormalizationKeepsWindowsWorkspaceBoundariesSafe(): Unit {
        @Expect(normalizedHostPath("C:\\repo\\workspace\\"), "C:/repo/workspace")
        @Expect(hostPathIsWithin("C:\\repo\\workspace", "C:\\repo\\workspace\\packages\\a"))
        @Expect(!hostPathIsWithin("C:\\repo\\workspace", "C:\\repo\\workspace-copy\\a"))
        @Expect(normalizedHostPath("C:\\"), "C:/")
        @Expect(hostPathIsWithin("C:\\", "C:\\repo\\workspace"))
    }

    @TestCase
    func cjpmLockAdapterAndOfflineCacheDiscoveryAreDeterministic(): Unit {
        let parsed = parseCjpmLock("""
version = 0
[requires]
zeta = { version = "2.0.0" }
alpha = {
  git = "https://example.test/alpha.git",
  commitId = "abc123"
}
unsupported = { branch = "main" }
""")
        @Expect(parsed.size, 2)
        @Expect(parsed[0].name, "alpha")
        @Expect(parsed[0].commitId.getOrThrow(), "abc123")
        @Expect(parsed[1].name, "zeta")
        @Expect(parsed[1].version.getOrThrow(), "2.0.0")

        let root = FIXTURE_PROJECTS + "cached_dependencies"
        let cacheRoot = "../../tests/fixtures/cjpm_cache"
        let withoutCache = generateDocumentation(root)
        @Expect(withoutCache.symbols.size, 1)
        let withCache = generateDocumentation(root, includeCachedDependencies: true,
            cjpmCacheRoot: Some(cacheRoot))
        @Expect(withCache.symbols.size, 3)
        @Expect(withCache.modules.size, 3)
        @Expect(hasDiagnostic(withCache, "CJDOC1021"))
        let json = renderDocumentationJson(withCache)
        @Expect(json.contains("dependencies/cached_dep/src/api.cj"))
        @Expect(json.contains("dependencies/transitive_dep/src/api.cj"))
        @Expect(json.contains("\"name\":\"cached_dep\",\"role\":\"externalDependency\"," +
            "\"sourcePrefix\":\"dependencies/cached_dep\"," +
            "\"packageNames\":[\"cached_dep\"]," +
            "\"dependencyIds\":[\"cjdoc:module:v1:external:transitive_dep\"]"))
        @Expect(!json.contains(cacheRoot))
    }

    @TestCase
    func duplicateIdsAndInvalidWorkspaceFailClosed(): Unit {
        let duplicate = generateDocumentation(FIXTURE_PROJECTS + "duplicate")
        @Expect(duplicate.symbols.size, 2)
        @Expect(duplicate.diagnostics.size, 1)
        @Expect(duplicate.diagnostics[0].code, "CJDOC1006")
        @Expect(hasFatalDiagnostics(duplicate))

        let invalidWorkspace = generateDocumentation(FIXTURE_PROJECTS + "workspace_invalid")
        @Expect(invalidWorkspace.symbols.size, 0)
        @Expect(invalidWorkspace.diagnostics.size, 1)
        @Expect(invalidWorkspace.diagnostics[0].code, "CJDOC1010")
        @Expect(hasFatalDiagnostics(invalidWorkspace))
    }

    @TestCase
    func unsupportedMacroProducesStableDiagnostic(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "unsupported")
        @Expect(documentation.symbols.size, 0)
        @Expect(documentation.unsupportedDeclarations.size, 1)
        @Expect(documentation.unsupportedDeclarations[0].kind, "macro")
        @Expect(documentation.unsupportedDeclarations[0].name, "Echo")
        @Expect(documentation.unsupportedDeclarations[0].origin.kind, "source")
        @Expect(documentation.unsupportedDeclarations[0].origin.macroSymbolId.isNone())
        @Expect(documentation.diagnostics.size, 1)
        @Expect(documentation.diagnostics[0].code, "CJDOC1009")
        @Expect(documentation.diagnostics[0].severity, "warning")
        @Expect(renderDocumentationJson(documentation).contains(
            "\"unsupportedDeclarations\":[{\"kind\":\"macro\",\"name\":\"Echo\""))
        @Expect(!hasFatalDiagnostics(documentation))
    }

    @TestCase
    func astOverrideRelationshipRemainsExplicitlyUnavailable(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "override")
        @Expect(documentation.symbols.size, 4)
        var sawOverride = false
        for (symbol in documentation.symbols) {
            if (symbol.qualifiedName == "override_fixture.DerivedReader.read") {
                @Expect(symbol.symbolRelationships.size, 1)
                @Expect(symbol.symbolRelationships[0].kind, "override")
                @Expect(symbol.symbolRelationships[0].targetDisplay, "read")
                @Expect(symbol.symbolRelationships[0].state, "unavailable")
                @Expect(symbol.symbolRelationships[0].targetSymbolId.isNone())
                sawOverride = true
            }
        }
        @Expect(sawOverride)
        let json = renderDocumentationJson(documentation)
        @Expect(json.contains("\"kind\":\"override\",\"targetDisplay\":\"read\"," +
            "\"state\":\"unavailable\",\"targetSymbolId\":null"))
    }

    @TestCase
    func deepBinaryExpressionIsSkippedWithoutCrashing(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "deep_binary")
        @Expect(documentation.symbols.size, 0)
        @Expect(documentation.diagnostics.size, 1)
        @Expect(documentation.diagnostics[0].code, "CJDOC1012")
        @Expect(!hasFatalDiagnostics(documentation))
        @Expect(hasErrorDiagnostics(documentation))
    }

    @TestCase
    func documentationQualityLintCoverageAndMachineDiagnosticsAreStable(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "lint_quality")
        validateDocumentationMarkdown(documentation)
        lintDocumentation(documentation, true, missingSymbolDocs: true)
        @Expect(hasDiagnostic(documentation, "CJDOC1022"))
        @Expect(hasDiagnostic(documentation, "CJDOC1023"))
        @Expect(hasDiagnostic(documentation, "CJDOC1024"))
        @Expect(hasDiagnostic(documentation, "CJDOC1025"))
        let coverage = documentationCoverage(documentation)
        @Expect(coverage.publicSymbols, 2)
        @Expect(coverage.documentedPublicSymbols, 1)
        @Expect(coverage.symbolPercent(), 50)
        @Expect(coverage.publicParameters, 1)
        @Expect(coverage.documentedPublicParameters, 0)
        @Expect(renderDiagnosticsJson(documentation).contains("cjdoc.diagnostics/1"))
        let sarif = renderDiagnosticsSarif(documentation)
        @Expect(sarif.contains("\"version\":\"2.1.0\""))
        @Expect(sarif.contains("\"ruleId\":\"CJDOC1022\""))
        @Expect(!sarif.contains("/home/"))
    }

    @TestCase
    func configFileProvidesDefaultsAndCliArgumentsOverrideThem(): Unit {
        let path = FIXTURE_PROJECTS + "lint_quality/cjdoc.toml"
        let options = parseCli(["--config", path, "--format", "json", "--jobs", "4"])
        @Expect(options.format, "json")
        @Expect(options.jobs, 4)
        @Expect(options.noCache)
        @Expect(options.lintMissingSymbols)
        @Expect(options.coverage)
        @Expect(options.denyWarnings)
        let stdoutOptions = parseCli(["--format", "json", "--stdout",
            "--diagnostic-output", "/tmp/diagnostics.txt"])
        @Expect(stdoutOptions.stdout)
    }

    @TestCase
    func conditionalDuplicateGroupIsExplicitlyOmitted(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "conditional")
        @Expect(documentation.symbols.size, 0)
        @Expect(documentation.diagnostics.size, 1)
        @Expect(documentation.diagnostics[0].code, "CJDOC1013")
        @Expect(documentation.diagnostics[0].severity, "warning")
        @Expect(!hasFatalDiagnostics(documentation))

        let linux = generateDocumentation(FIXTURE_PROJECTS + "conditional",
            cfgValues: [CfgValue("os", "Linux")])
        @Expect(linux.symbols.size, 1)
        @Expect(linux.symbols[0].source.startLine, 3)
        @Expect(linux.diagnostics.size, 0)
        @Expect(renderDocumentationJson(linux).contains(
            "\"configuration\":{\"cfg\":[{\"name\":\"os\",\"value\":\"Linux\"}]}"))

        let other = generateDocumentation(FIXTURE_PROJECTS + "conditional",
            cfgValues: [CfgValue("os", "Windows")])
        @Expect(other.symbols.size, 1)
        @Expect(other.symbols[0].source.startLine, 6)
        @Expect(other.diagnostics.size, 0)

        let unknown = generateDocumentation(FIXTURE_PROJECTS + "conditional",
            cfgValues: [CfgValue("arch", "x86_64")])
        @Expect(unknown.symbols.size, 0)
        @Expect(unknown.diagnostics.size, 2)
        @Expect(hasDiagnostic(unknown, "CJDOC1019"))
    }

    @TestCase
    func conditionalProfilesSupportBooleanCompositionAndDominance(): Unit {
        let documentation = generateDocumentation(FIXTURE_PROJECTS + "conditional_complex",
            cfgValues: [CfgValue("os", "Linux"), CfgValue("arch", "x86_64"),
                CfgValue("docs", "true"), CfgValue("missing", "false")])
        @Expect(documentation.symbols.size, 2)
        @Expect(documentation.symbols[0].name, "selected")
        @Expect(documentation.symbols[1].name, "provenByOr")
        @Expect(documentation.diagnostics.size, 0)

        let unresolved = generateDocumentation(FIXTURE_PROJECTS + "conditional_complex",
            cfgValues: [CfgValue("docs", "false")])
        @Expect(unresolved.symbols.size, 0)
        @Expect(hasDiagnostic(unresolved, "CJDOC1019"))
    }

    @TestCase
    func cfgMatrixProfilesAreExplicitSortedAndSchemaVersioned(): Unit {
        let options = parseCli(["--format", "json",
            "--cfg-matrix-profile", "windows:os=Windows,arch=x86_64",
            "--cfg-matrix-profile", "linux:arch=x86_64,os=Linux"])
        @Expect(options.cfgMatrixProfiles.size, 2)
        @Expect(options.cfgMatrixProfiles[0].name, "windows")
        @Expect(options.cfgMatrixProfiles[0].profile.values.size, 2)

        let root = FIXTURE_PROJECTS + "conditional"
        let windows = generateDocumentation(root,
            cfgValues: options.cfgMatrixProfiles[0].profile.values.toArray())
        let linux = generateDocumentation(root,
            cfgValues: options.cfgMatrixProfiles[1].profile.values.toArray())
        let json = renderCfgMatrixJson([
            CfgMatrixDocumentation("windows", windows),
            CfgMatrixDocumentation("linux", linux)
        ])
        @Expect(json.startsWith("{\"schemaVersion\":\"cjdoc.cfg-matrix/1\""))
        @Expect(json.indexOf("\"name\":\"linux\"").getOrThrow() <
            json.indexOf("\"name\":\"windows\"").getOrThrow())
        @Expect(json.contains("\"configuration\":{\"cfg\":[" +
            "{\"name\":\"arch\",\"value\":\"x86_64\"}," +
            "{\"name\":\"os\",\"value\":\"Linux\"}]}"))

        var rejected = false
        try {
            let _ = parseCli(["--cfg", "os=Linux", "--cfg-matrix-profile", "linux:os=Linux"])
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
        rejected = false
        try {
            let _ = parseCli(["--cfg-matrix-profile", "../linux:os=Linux"])
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
        rejected = false
        try {
            let _ = renderCfgMatrixJson([
                CfgMatrixDocumentation("same", linux),
                CfgMatrixDocumentation("same", windows)
            ])
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
    }

    @TestCase
    func markdownOutputUsesParsedMarkdownAndStableHeadingDepth(): Unit {
        let root = FIXTURE_PROJECTS + "basic"
        let first = generateDocumentation(root)
        validateDocumentationMarkdown(first)
        lintDocumentation(first, true)
        let firstMarkdown = renderDocumentationMarkdown(first)
        let second = generateDocumentation(root)
        validateDocumentationMarkdown(second)
        lintDocumentation(second, true)
        let secondMarkdown = renderDocumentationMarkdown(second)
        @Expect(firstMarkdown, secondMarkdown)
        @Expect(markdownInputComplete(firstMarkdown))
        @Expect(firstMarkdown.contains("# `basic` API documentation"))
        @Expect(firstMarkdown.contains("## Modules"))
        @Expect(firstMarkdown.contains("- Role: `root`"))
        @Expect(firstMarkdown.contains("- Source prefix: `.`"))
        @Expect(firstMarkdown.contains("## Package `basic`"))
        @Expect(firstMarkdown.contains("##### Example"))
        @Expect(firstMarkdown.contains("```cj\nlet value = parse(\"42\")\n```"))
        @Expect(firstMarkdown.contains("#### Parameters"))
        @Expect(firstMarkdown.contains("#### Throws"))
        @Expect(firstMarkdown.contains("#### See also"))
        @Expect(firstMarkdown.contains("#### Relationships"))
        @Expect(firstMarkdown.contains("- Supertype: `Reader` — semantic state `partial`"))
        @Expect(firstMarkdown.contains("- Extension target: `Box < String >` — semantic state `partial`"))
        @Expect(firstMarkdown.contains("<a id=\"cjdoc-symbol-"))
        @Expect(firstMarkdown.contains(
            "##### [`basic.parse(String)`](#cjdoc-symbol-cjdoc_3av1_3abasic_3a_3afunction_3aparse_23g0_28String_29)"))
        @Expect(!firstMarkdown.contains("/home/"))
        @Expect(!firstMarkdown.contains("@param text"))
    }

    @TestCase
    func markdownHeadingDemotionUsesAstAndPreservesNonHeadingBlocks(): Unit {
        let source = """
Setext title
============

```cj
# code heading
```

<div>
# raw html text
</div>
"""
        let prepared = prepareDocumentationMarkdown(source)
        @Expect(prepared.startsWith("#### Setext title"))
        @Expect(prepared.contains("```cj\n# code heading\n```"))
        @Expect(prepared.contains("<div>\n# raw html text\n</div>"))
        @Expect(markdownInputComplete(prepared))
    }

    @TestCase
    func cliAcceptsMarkdownHtmlAndRejectsUnknownFormats(): Unit {
        let options = parseCli(["--format", "markdown", "--output", "docs.md"])
        @Expect(options.format, "markdown")
        @Expect(options.output.getOrThrow(), "docs.md")
        @Expect(parseCli(["--format", "html"]).format, "html")
        let linked = parseCli(["--format", "html", "--source-url-template",
            "https://example.test/blob/main/{path}#L{line}"])
        @Expect(linked.sourceUrlTemplate.getOrThrow(), "https://example.test/blob/main/{path}#L{line}")
        @Expect(parseCli(["--include-path-dependencies"]).includePathDependencies)
        let withSource = parseCli(["--dependency-source", "markdown=/opt/src/markdown"])
        @Expect(withSource.dependencySources.size, 1)
        @Expect(withSource.dependencySources[0].name, "markdown")
        @Expect(withSource.dependencySources[0].path, "/opt/src/markdown")
        let withCfg = parseCli(["--cfg", "os=Linux", "--cfg", "arch=x86_64"])
        @Expect(withCfg.cfgValues.size, 2)
        @Expect(withCfg.cfgValues[0].name, "os")
        @Expect(withCfg.cfgValues[0].value, "Linux")
        @Expect(parseCli(["--jobs", "4"]).jobs, 4)
        let dependencyLinks = parseCli(["--format", "html",
            "--dependency-revision", "example=release/1.0",
            "--dependency-source-url", "example=https://example.test/blob/{revision}/{path}#L{line}"])
        @Expect(dependencyLinks.dependencySourceLinks.size, 1)
        @Expect(dependencyLinks.dependencySourceLinks[0].name, "example")
        @Expect(dependencyLinks.dependencySourceLinks[0].revision.getOrThrow(), "release/1.0")
        var rejected = false
        try {
            let _ = parseCli(["--format", "pdf"])
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
        rejected = false
        try {
            let _ = parseCli(["--format", "json", "--source-url-template", "https://example.test/{path}"])
        } catch (_: IllegalArgumentException) {
            rejected = true
        }
        @Expect(rejected)
        @Expect(!sourceUrlTemplateValid("javascript:{path}"))
        @Expect(!sourceUrlTemplateValid("https:///{path}"))
        @Expect(!sourceUrlTemplateValid("https://{path}"))
        @Expect(!sourceUrlTemplateValid("https://example.test/{unknown}"))
        @Expect(!sourceUrlTemplateValid("https://example.test/static"))
    }

    @TestCase
    func htmlSiteIsDeterministicLinkedAndSafe(): Unit {
        let first = generateDocumentation(FIXTURE_PROJECTS + "basic")
        validateDocumentationMarkdown(first)
        lintDocumentation(first, true)
        let firstSite = renderDocumentationHtml(first)
        let seeTarget = resolveDocReference(first, "basic.parse(String)").getOrThrow()
        let expectedSeeHref = "../packages/package-basic.html#symbol-${htmlStableSlug(seeTarget.id)}"
        let second = generateDocumentation(FIXTURE_PROJECTS + "basic")
        validateDocumentationMarkdown(second)
        lintDocumentation(second, true)
        let secondSite = renderDocumentationHtml(second)
        @Expect(firstSite.files.size, secondSite.files.size)
        var sawIndex = false
        var sawSearch = false
        var sawSearchScript = false
        var sawSymbolPage = false
        var sawResolvedSee = false
        var sawBreadcrumb = false
        var sawOwnerLink = false
        var sawRelationship = false
        var index: Int64 = 0
        while (index < firstSite.files.size) {
            @Expect(firstSite.files[index].path, secondSite.files[index].path)
            @Expect(firstSite.files[index].content, secondSite.files[index].content)
            @Expect(!firstSite.files[index].content.contains("/home/"))
            if (firstSite.files[index].path == "index.html") { sawIndex = true }
            if (firstSite.files[index].path == "search-index.json") {
                sawSearch = true
                @Expect(firstSite.files[index].content.contains("cjdoc.search-index/2"))
                @Expect(firstSite.files[index].content.contains("\"visibility\":"))
                @Expect(firstSite.files[index].content.contains("symbols/symbol-"))
            }
            if (firstSite.files[index].path == "search.js") {
                @Expect(firstSite.files[index].content.contains("textContent"))
                @Expect(!firstSite.files[index].content.contains("innerHTML"))
                @Expect(firstSite.files[index].content.contains("ArrowDown"))
                @Expect(firstSite.files[index].content.contains("data-cjdoc-kind"))
                sawSearchScript = true
            }
            if (firstSite.files[index].path.endsWith(".html")) {
                @Expect(firstSite.files[index].content.contains("data-cjdoc-search"))
                @Expect(firstSite.files[index].content.contains("data-cjdoc-results"))
                @Expect(firstSite.files[index].content.contains("Content-Security-Policy"))
                @Expect(firstSite.files[index].content.contains("role=\"combobox\""))
            }
            if (firstSite.files[index].path.startsWith("symbols/")) { sawSymbolPage = true }
            if (firstSite.files[index].content.contains(
                "<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\">")) {
                sawBreadcrumb = true
            }
            if (firstSite.files[index].content.contains("class=\"owner-link\"")) {
                sawOwnerLink = true
            }
            if (firstSite.files[index].content.contains("<h3>Relationships</h3>") &&
                firstSite.files[index].content.contains("<dt>Extension target</dt><dd><code>Box &lt; String &gt;</code> <span class=\"badge\">partial</span>")) {
                sawRelationship = true
            }
            if (firstSite.files[index].content.contains("href=\"${expectedSeeHref}\"") &&
                firstSite.files[index].content.contains("<code>basic.parse(String)</code></a>")) {
                sawResolvedSee = true
            }
            index++
        }
        @Expect(sawIndex)
        @Expect(sawSearch)
        @Expect(sawSearchScript)
        @Expect(sawSymbolPage)
        @Expect(sawResolvedSee)
        @Expect(sawBreadcrumb)
        @Expect(sawOwnerLink)
        @Expect(sawRelationship)
        @Expect(htmlStableSlug("解析"), "_e8_a7_a3_e6_9e_90")

        let malicious = DocumentationSet("unsafe <project>")
        let source = SourceLocation("src/unsafe.cj", 1, 1, 2, 1)
        let symbol = SymbolDoc("function", "unsafe", "unsafe", "public", source,
            "public func unsafe(): Unit")
        symbol.id = "unsafe::function:unsafe#g0()"
        symbol.qualifiedName = "unsafe"
        symbol.documentation = Some(parseDocComment("""
/**
 * <script>alert(1)</script>
 *
 * [bad](javascript:alert(1))
 */
"""))
        malicious.symbols.add(symbol)
        let pkg = PackageDoc("unsafe")
        pkg.symbolIds.add(symbol.id)
        pkg.sourceFiles.add(source.path)
        malicious.packages.add(pkg)
        let unsafeSite = renderDocumentationHtml(malicious)
        for (file in unsafeSite.files where file.path.endsWith(".html")) {
            @Expect(file.content.contains("<script defer src="))
            @Expect(!file.content.contains("<script>alert"))
            @Expect(!file.content.contains("onerror="))
            @Expect(!file.content.contains("javascript:"))
        }

        let linkedSet = DocumentationSet("linked")
        let linkedSource = SourceLocation("src/中文 name#.cj", 42, 7, 43, 1)
        let linkedSymbol = SymbolDoc("function", "linked", "linked", "public", linkedSource,
            "public func linked(): Unit")
        linkedSymbol.id = "linked::function:linked"
        linkedSymbol.qualifiedName = "linked.linked"
        linkedSet.symbols.add(linkedSymbol)
        let linkedPackage = PackageDoc("linked")
        linkedPackage.symbolIds.add(linkedSymbol.id)
        linkedPackage.sourceFiles.add(linkedSource.path)
        linkedSet.packages.add(linkedPackage)
        let linkedSite = renderDocumentationHtml(linkedSet,
            sourceUrlTemplate: Some("https://example.test/blob/main/{path}#L{line}C{column}"))
        var linkedPage = ""
        for (file in linkedSite.files) {
            if (file.path.startsWith("packages/")) { linkedPage = file.content }
        }
        @Expect(linkedPage.contains("href=\"https://example.test/blob/main/src/%E4%B8%AD%E6%96%87%20name%23.cj#L42C7\""))
        @Expect(linkedPage.contains(">src/中文 name#.cj:42:7</code></a>"))
        let dependencySource = SourceLocation("dependencies/example/src/api.cj", 3, 1, 4, 1)
        let dependencySymbol = SymbolDoc("function", "dependency", "example", "public", dependencySource,
            "public func dependency(): Unit")
        dependencySymbol.id = "example::function:dependency"
        dependencySymbol.qualifiedName = "example.dependency"
        let dependencySet = DocumentationSet("dependency")
        dependencySet.symbols.add(dependencySymbol)
        let dependencyPackage = PackageDoc("example")
        dependencyPackage.symbolIds.add(dependencySymbol.id)
        dependencyPackage.sourceFiles.add(dependencySource.path)
        dependencySet.packages.add(dependencyPackage)
        let dependencySite = renderDocumentationHtml(dependencySet,
            sourceUrlTemplate: Some("https://example.test/blob/main/{path}#L{line}"))
        for (file in dependencySite.files where file.path.endsWith(".html")) {
            @Expect(!file.content.contains("class=\"source-link\""))
        }
        let explicitlyLinkedDependencySite = renderDocumentationHtml(dependencySet,
            dependencySourceLinks: [DependencySourceLink("example",
                "https://deps.example.test/blob/{revision}/{path}#L{line}C{column}",
                revision: Some("release/1.0"))])
        var dependencyPage = ""
        for (file in explicitlyLinkedDependencySite.files where file.path.startsWith("packages/")) {
            dependencyPage = file.content
        }
        @Expect(dependencyPage.contains(
            "href=\"https://deps.example.test/blob/release/1.0/src/api.cj#L3C1\""))
        @Expect(dependencyPage.contains(">dependencies/example/src/api.cj:3:1</code></a>"))
        let invalidLinkedSite = renderDocumentationHtml(linkedSet,
            sourceUrlTemplate: Some("javascript:{path}"))
        for (file in invalidLinkedSite.files where file.path.endsWith(".html")) {
            @Expect(!file.content.contains("javascript:"))
            @Expect(!file.content.contains("class=\"source-link\""))
        }

        let nestedSet = DocumentationSet("nested")
        let nestedPackage = PackageDoc("nested")
        let parent = SymbolDoc("class", "Outer", "nested", "public", source, "public class Outer {}",
            isContainer: true)
        parent.id = "nested::class:Outer"
        parent.qualifiedName = "nested.Outer"
        let nested = SymbolDoc("class", "Inner", "nested", "public", source, "public class Inner {}",
            isContainer: true)
        nested.id = "nested::Outer::class:Inner"
        nested.qualifiedName = "nested.Outer.Inner"
        nested.ownerId = Some(parent.id)
        let member = SymbolDoc("function", "work", "nested", "public", source, "public func work(): Unit")
        member.id = "nested::Outer::Inner::function:work"
        member.qualifiedName = "nested.Outer.Inner.work"
        member.ownerId = Some(nested.id)
        nestedSet.symbols.add(parent)
        nestedSet.symbols.add(nested)
        nestedSet.symbols.add(member)
        nestedPackage.symbolIds.add(parent.id)
        nestedPackage.symbolIds.add(nested.id)
        nestedPackage.symbolIds.add(member.id)
        nestedSet.packages.add(nestedPackage)
        let nestedSite = renderDocumentationHtml(nestedSet)
        var nestedSearch = ""
        var nestedPage = ""
        for (file in nestedSite.files) {
            if (file.path == "search-index.json") { nestedSearch = file.content }
            if (file.content.contains("<title>nested.Outer.Inner</title>")) { nestedPage = file.content }
        }
        @Expect(nestedSearch.contains("symbol-nested_3a_3aOuter_3a_3aclass_3aInner.html#symbol-nested_3a_3aOuter_3a_3aInner_3a_3afunction_3awork"))
        @Expect(nestedPage.contains(
            "<li><a href=\"../symbols/symbol-nested_3a_3aclass_3aOuter.html\"><code>Outer</code></a></li>"))
        @Expect(nestedPage.contains(
            "<li aria-current=\"page\"><code>Inner</code></li>"))

        let longSet = DocumentationSet("long-pages")
        let longPackageNameBuilder = StringBuilder()
        longPackageNameBuilder.append("long_package_")
        for (_ in 0..300) { longPackageNameBuilder.append("x") }
        let longPackageName = longPackageNameBuilder.toString()
        let longPackage = PackageDoc(longPackageName)
        let longIdBuilder = StringBuilder()
        longIdBuilder.append("cjdoc:v1:long::extend:Target{")
        for (_ in 0..300) { longIdBuilder.append("function:member(Int64);") }
        let firstLong = SymbolDoc("extend", "Target", longPackageName, "public", source,
            "extend Target {}", isContainer: true)
        firstLong.id = longIdBuilder.toString() + "first}"
        firstLong.qualifiedName = "long.Target.first"
        let secondLong = SymbolDoc("extend", "Target", longPackageName, "public", source,
            "extend Target {}", isContainer: true)
        secondLong.id = longIdBuilder.toString() + "second}"
        secondLong.qualifiedName = "long.Target.second"
        longSet.symbols.add(firstLong)
        longSet.symbols.add(secondLong)
        longPackage.symbolIds.add(firstLong.id)
        longPackage.symbolIds.add(secondLong.id)
        longSet.packages.add(longPackage)
        let longSite = renderDocumentationHtml(longSet)
        var longSymbolPages: Int64 = 0
        var firstPath = ""
        for (file in longSite.files) {
            if (file.path.startsWith("packages/")) { @Expect(file.path.size < 200) }
            if (file.path.startsWith("symbols/")) {
                @Expect(file.path.size < 200)
                longSymbolPages++
                if (firstPath.isEmpty()) {
                    firstPath = file.path
                } else {
                    @Expect(file.path != firstPath)
                }
            }
        }
        @Expect(longSymbolPages, 2)
    }

    @TestCase
    func pathDependenciesAreExplicitRecursiveAndRecoverable(): Unit {
        let root = FIXTURE_PROJECTS + "path_dependencies"
        let rootOnly = generateDocumentation(root)
        @Expect(rootOnly.symbols.size, 1)
        @Expect(rootOnly.packages.size, 1)

        let included = generateDocumentation(root, includePathDependencies: true)
        @Expect(included.symbols.size, 3)
        @Expect(included.packages.size, 3)
        @Expect(included.modules.size, 3)
        @Expect(included.diagnostics.size, 0)
        let json = renderDocumentationJson(included)
        @Expect(json.contains("path_dep_alpha"))
        @Expect(json.contains("path_dep_beta"))
        @Expect(json.contains("dependencies/path_dep_alpha/src/alpha.cj"))
        @Expect(json.contains("dependencies/path_dep_beta/src/beta.cj"))
        @Expect(json.contains("\"role\":\"pathDependency\""))
        @Expect(json.contains("\"dependencyIds\":[\"cjdoc:module:v1:path:path_dep_beta\"]"))
        @Expect(json.contains("\"subject\":\"path_dep_alpha.alphaApi\",\"description\":\"\"," +
            "\"state\":\"resolved\",\"targetSymbolId\":\"cjdoc:v1:path_dep_alpha"))
        @Expect(json.contains("\"subject\":\"path_dep_beta.betaApi\",\"description\":\"\"," +
            "\"state\":\"resolved\",\"targetSymbolId\":\"cjdoc:v1:path_dep_beta"))
        @Expect(!json.contains("/home/"))
        let dependencyMarkdown = renderDocumentationMarkdown(included)
        @Expect(dependencyMarkdown.contains("## Modules"))
        @Expect(dependencyMarkdown.contains("### `path_dep_alpha`"))
        @Expect(dependencyMarkdown.contains("Direct dependencies:\n\n- `path_dep_beta`"))
        let dependencySite = renderDocumentationHtml(included)
        var dependencyIndex = ""
        for (file in dependencySite.files) {
            if (file.path == "index.html") { dependencyIndex = file.content }
        }
        @Expect(dependencyIndex.contains("<span class=\"badge\">pathDependency</span>"))
        @Expect(dependencyIndex.contains("href=\"#module-cjdoc_3amodule_3av1_3apath_3apath_dep_beta\""))
        @Expect(dependencyIndex.contains("href=\"packages/package-path_dep_alpha.html\""))

        let invalid = generateDocumentation(FIXTURE_PROJECTS + "path_dependencies_invalid",
            includePathDependencies: true)
        @Expect(invalid.symbols.size, 1)
        @Expect(invalid.diagnostics.size, 2)
        @Expect(hasDiagnostic(invalid, "CJDOC1015"))
        @Expect(hasDiagnostic(invalid, "CJDOC1016"))
        @Expect(!hasFatalDiagnostics(invalid))
        @Expect(!renderDocumentationJson(invalid).contains("also-missing"))
    }

    @TestCase
    func configuredOfflineDependencySourcesAreScannedWithoutDownloading(): Unit {
        let root = FIXTURE_PROJECTS + "path_dependencies"
        let inputs = [
            DependencySourceInput("offline_alpha", root + "/deps/alpha"),
            DependencySourceInput("offline_beta", root + "/deps/beta")
        ]
        let documentation = generateDocumentation(root, dependencySources: inputs)
        @Expect(documentation.symbols.size, 3)
        @Expect(documentation.modules.size, 3)
        @Expect(documentation.diagnostics.size, 0)
        let json = renderDocumentationJson(documentation)
        @Expect(json.contains("\"role\":\"externalDependency\""))
        @Expect(json.contains("dependencies/offline_alpha/src/alpha.cj"))
        @Expect(json.contains("dependencies/offline_beta/src/beta.cj"))
        @Expect(json.contains("\"subject\":\"path_dep_alpha.alphaApi\",\"description\":\"\"," +
            "\"state\":\"resolved\""))
        @Expect(json.contains("\"subject\":\"path_dep_beta.betaApi\",\"description\":\"\"," +
            "\"state\":\"resolved\""))
        @Expect(!json.contains(root))
    }
}
