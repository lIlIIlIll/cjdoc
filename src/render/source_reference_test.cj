package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let SOURCE_REFERENCE_TEST_MODULE = "cjdoc:module:v1:source-reference-test"
private let SOURCE_REFERENCE_TEST_DIGEST =
    "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
private let SOURCE_REFERENCE_TEST_REVISION = "1111111111111111111111111111111111111111"

private func sourceReferenceFixture(provenance: SourceProvenance,
    projectRepository!: ?RepositoryInfo = None): DocumentationSet {
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("source-reference", repository: projectRepository),
        ConfigurationSnapshot(lintProfile: "off"),
        files: [FileDoc("src/api.cj", SOURCE_REFERENCE_TEST_MODULE, "fixture",
            provenance: provenance)])
}

private func sourceReferenceRange(path!: String = "src/api.cj", endLine!: Int64 = 6,
    endColumn!: Int64 = 1): SourceRange {
    SourceRange(path, SourcePosition(4, 1, 80), SourcePosition(endLine, endColumn, 120))
}

private func verifiedSourceProvenance(repositoryPath: String,
    repository!: RepositoryInfo = RepositoryInfo("https://github.com/example/library",
        SOURCE_REFERENCE_TEST_REVISION)): SourceProvenance {
    SourceProvenance("verified", "receipt_matched", repository: Some(repository),
        repositoryPath: Some(repositoryPath), sourceDigest: Some(SOURCE_REFERENCE_TEST_DIGEST),
        normalizedDigest: Some(SOURCE_REFERENCE_TEST_DIGEST),
        evidenceIdentity: Some(SOURCE_REFERENCE_TEST_DIGEST),
        evidenceKind: "caller_pinned_receipt")
}


private func sourceReferenceReExportDocument(): DocumentationSet {
    let moduleId = SOURCE_REFERENCE_TEST_MODULE
    let reExport = ReExportDoc(
        "cjdoc:reexport:v1:1111111111111111111111111111111111111111111111111111111111111111",
        "packageAlias", "other", "unavailable", sourceReferenceRange(),
        alias: Some("alias"))
    DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("source-reference"),
        ConfigurationSnapshot(audience: "all", lintProfile: "off"),
        providers: [ProviderInfo("ast", "builtin", moduleId, "partial",
            SemanticCapabilities(false, false, false, false, false))],
        modules: [ModuleDoc(moduleId, "source-reference", "root", "",
            packageNames: ["fixture"])],
        packages: [PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"],
            reExports: [reExport])],
        files: [FileDoc("src/api.cj", moduleId, "fixture",
            provenance: verifiedSourceProvenance("src/api.cj"))])
}

private let SOURCE_REFERENCE_EXPOSING_MODULE = "cjdoc:module:v1:root"
private let SOURCE_REFERENCE_TARGET_MODULE = "cjdoc:module:v1:path:source-reference-target"
private let SOURCE_REFERENCE_TARGET_SYMBOL =
    "cjdoc:v2:cjdoc%3Amodule%3Av1%3Apath%3Asource-reference-target::target::class:Thing#g0()"

private func sourceReferenceMultiModuleDocument(): DocumentationSet {
    let exposingRepository = RepositoryInfo("https://github.com/example/exposing",
        "2222222222222222222222222222222222222222")
    let targetRepository = RepositoryInfo("https://github.com/example/target",
        "3333333333333333333333333333333333333333")
    let exposureRange = sourceReferenceRange(endLine: 4, endColumn: 20)
    let targetRange = SourceRange("src/api.cj", SourcePosition(9, 1, 160),
        SourcePosition(9, 20, 179))
    let reExport = ReExportDoc(
        "cjdoc:reexport:v1:2222222222222222222222222222222222222222222222222222222222222222",
        "single", "target", "resolved", exposureRange,
        targetModuleId: Some(SOURCE_REFERENCE_TARGET_MODULE),
        bindings: [ReExportBinding("Thing", targetSymbolIds: [SOURCE_REFERENCE_TARGET_SYMBOL])])
    let target = SymbolDoc(SOURCE_REFERENCE_TARGET_SYMBOL, "class", "Thing", "target.Thing",
        "target", SOURCE_REFERENCE_TARGET_MODULE, "public", targetRange, "public class Thing",
        SemanticInfo("partial", "ast"))
    let capabilities = SemanticCapabilities(false, false, false, false, false)
    return DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete",
        ProjectInfo("source-reference-multi-module"),
        ConfigurationSnapshot(audience: "all", lintProfile: "off"),
        providers: [
            ProviderInfo("ast", "builtin", SOURCE_REFERENCE_EXPOSING_MODULE, "partial", capabilities),
            ProviderInfo("ast", "builtin", SOURCE_REFERENCE_TARGET_MODULE, "partial", capabilities)],
        modules: [
            ModuleDoc(SOURCE_REFERENCE_EXPOSING_MODULE, "exposing", "root", "",
                packageNames: ["exposing"], dependencyIds: [SOURCE_REFERENCE_TARGET_MODULE]),
            ModuleDoc(SOURCE_REFERENCE_TARGET_MODULE, "target", "pathDependency", "",
                packageNames: ["target"])],
        packages: [
            PackageDoc("exposing", SOURCE_REFERENCE_EXPOSING_MODULE,
                sourceFiles: ["src/api.cj"], reExports: [reExport]),
            PackageDoc("target", SOURCE_REFERENCE_TARGET_MODULE,
                sourceFiles: ["src/api.cj"], symbolIds: [SOURCE_REFERENCE_TARGET_SYMBOL])],
        files: [
            FileDoc("src/api.cj", SOURCE_REFERENCE_EXPOSING_MODULE, "exposing",
                provenance: verifiedSourceProvenance("packages/exposing/src/api.cj",
                    repository: exposingRepository)),
            FileDoc("src/api.cj", SOURCE_REFERENCE_TARGET_MODULE, "target",
                provenance: verifiedSourceProvenance("packages/target/src/api.cj",
                    repository: targetRepository))],
        declarations: [target])
}
@Test
class SourceReferenceProjectionTest {
    @TestCase
    func verifiedPathsAreEncodedPerRepositoryPathSegmentAndRespectHalfOpenRanges(): Unit {
        let documentation = sourceReferenceFixture(verifiedSourceProvenance(
            "packages/main/src/中文 #?%.cj"))
        let source = SourceReferenceProjection(documentation).project(SOURCE_REFERENCE_TEST_MODULE,
            sourceReferenceRange())
        @Expect(source.state, "verified")
        @Expect(source.reason, "receipt_matched")
        @Expect(source.revisionKind, "exact")
        @Expect(source.url.getOrThrow(),
            "https://github.com/example/library/blob/${SOURCE_REFERENCE_TEST_REVISION}/" +
            "packages/main/src/%E4%B8%AD%E6%96%87%20%23%3F%25.cj#L4-L5")
        let serialized = JsonNode.parse(sourceReferenceJson(source)).asObject()
        @Expect(serialized.size(), 11)
        @Expect(serialized.get("state").getOrThrow().asString(), "verified")
        @Expect(serialized.get("evidenceKind").getOrThrow().asString(), "caller_pinned_receipt")
        @Expect(serialized.get("range").getOrThrow().asObject().get("path").getOrThrow().asString(),
            "src/api.cj")
    }

    @TestCase
    func legacyDeclaredRefsRemainLinksButDoNotClaimPinnedEvidence(): Unit {
        let repository = RepositoryInfo("https://github.com/example/library", "release/candidate")
        let provenance = SourceProvenance("declared", "legacy_project_repository",
            repository: Some(repository), repositoryPath: Some("main/src/api.cj"))
        let documentation = sourceReferenceFixture(provenance, projectRepository: Some(repository))
        let source = SourceReferenceProjection(documentation).project(SOURCE_REFERENCE_TEST_MODULE,
            sourceReferenceRange(endLine: 4, endColumn: 20))
        @Expect(source.url.getOrThrow(),
            "https://github.com/example/library/blob/release%2Fcandidate/main/src/api.cj#L4")
        @Expect(source.state, "declared")
        @Expect(source.reason, "legacy_project_repository")
        @Expect(source.revisionKind, "ref")
        @Expect(source.evidenceKind, "none")
        @Expect(source.evidenceIdentity.isNone(), true)
    }

    @TestCase
    func projectRepositoryAloneDoesNotAuthorizeSourceLinkOnReplay(): Unit {
        let repository = RepositoryInfo("https://github.com/example/library", "release/1")
        let documentation = sourceReferenceFixture(SourceProvenance.unavailable("no_registration"),
            projectRepository: Some(repository))
        let source = SourceReferenceProjection(documentation).project(SOURCE_REFERENCE_TEST_MODULE,
            sourceReferenceRange())
        @Expect(source.url.isNone(), true)
        @Expect(source.state, "unavailable")
        @Expect(source.reason, "no_registration")
        @Expect(source.repository.isNone(), true)
        @Expect(source.recordedRevision.isNone(), true)
    }

    @TestCase
    func conflictingOrUnsafeSourceRangesNeverProduceLinks(): Unit {
        let conflict = sourceReferenceFixture(SourceProvenance("ambiguous", "conflicting_registration"))
        let conflicting = SourceReferenceProjection(conflict).project(SOURCE_REFERENCE_TEST_MODULE,
            sourceReferenceRange())
        @Expect(conflicting.url.isNone(), true)
        @Expect(conflicting.state, "ambiguous")
        @Expect(conflicting.reason, "conflicting_registration")

        let verified = sourceReferenceFixture(verifiedSourceProvenance("src/api.cj"))
        let invalidRange = SourceRange("src/api.cj", SourcePosition(5, 1, 120),
            SourcePosition(4, 1, 80))
        let unsafeReference = SourceReferenceProjection(verified).project(SOURCE_REFERENCE_TEST_MODULE,
            invalidRange)
        @Expect(unsafeReference.url.isNone(), true)
        @Expect(unsafeReference.state, "unavailable")
        @Expect(unsafeReference.reason, "invalid_range")
    }

    @TestCase
    func htmlAndMarkdownExposeReExportLocationSeparatelyFromSymbolSource(): Unit {
        let documentation = sourceReferenceReExportDocument()
        let expectedUrl =
            "https://github.com/example/library/blob/${SOURCE_REFERENCE_TEST_REVISION}/src/api.cj#L4"
        var htmlHasExposureSource = false
        for (artifact in HtmlDocumentationRenderer().render(documentation)) {
            if (artifact.content.contains("reexport-source")) {
                htmlHasExposureSource = artifact.content.contains("Exposure source") &&
                    artifact.content.contains(expectedUrl)
            }
        }
        @Expect(htmlHasExposureSource, true)
        var markdownHasExposureSource = false
        for (artifact in renderDocumentationFormatsWithOptions(documentation, ["markdown"],
            locale: "en")) {
            if (artifact.path.startsWith("markdown/packages/")) {
                markdownHasExposureSource = artifact.content.contains("Exposure source") &&
                    artifact.content.contains(expectedUrl)
            }
        }
        @Expect(markdownHasExposureSource, true)
    }
    @TestCase
    func identicalLogicalPathsResolveIndependentlyForExposureAndTarget(): Unit {
        let documentation = sourceReferenceMultiModuleDocument()
        let encoded = encodeDocIr(documentation)
        @Expect(encodeDocIr(decodeDocIr(encoded)), encoded)
        let projection = SourceReferenceProjection(documentation)
        let exposure = projection.project(SOURCE_REFERENCE_EXPOSING_MODULE,
            sourceReferenceRange(endLine: 4, endColumn: 20))
        let target = projection.project(SOURCE_REFERENCE_TARGET_MODULE,
            SourceRange("src/api.cj", SourcePosition(9, 1, 160), SourcePosition(9, 20, 179)))
        let exposureUrl =
            "https://github.com/example/exposing/blob/2222222222222222222222222222222222222222/" +
            "packages/exposing/src/api.cj#L4"
        let targetUrl =
            "https://github.com/example/target/blob/3333333333333333333333333333333333333333/" +
            "packages/target/src/api.cj#L9"
        @Expect(exposure.url.getOrThrow(), exposureUrl)
        @Expect(target.url.getOrThrow(), targetUrl)
        @Expect(exposure.url == target.url, false)

        var hasExposureSource = false
        var hasTargetSource = false
        for (artifact in HtmlDocumentationRenderer().render(documentation)) {
            if (artifact.content.contains("reexport-source")) {
                hasExposureSource = artifact.content.contains(exposureUrl)
            }
            if (artifact.content.contains("source-action")) {
                hasTargetSource = artifact.content.contains(targetUrl)
            }
        }
        @Expect(hasExposureSource, true)
        @Expect(hasTargetSource, true)
        var markdownHasTargetSource = false
        for (artifact in renderDocumentationFormatsWithOptions(documentation, ["markdown"],
            locale: "en")) {
            if (artifact.path == "markdown/" + markdownSymbolPagePath(documentation.declarations[0])) {
                @Expect(artifact.content.contains(targetUrl), true)
                @Expect(artifact.content.contains(exposureUrl), false)
                @Expect(artifact.content.contains("verified/receipt_matched"), true)
                markdownHasTargetSource = true
            }
        }
        @Expect(markdownHasTargetSource, true)
    }
}
