package cjdoc

import cjdoc.model as api_model
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let SOURCE_PROVENANCE_FIXTURE = "tests/fixtures/projects/source_provenance"
private let SOURCE_PROVENANCE_FIXTURE_DIGEST =
    "sha256:83d4a986bde0be31775c0510a602ec849ea129338bf581f0000a3ee7388251f3"

private func sourceProvenanceFixtureRequest(sourceRepositories!: ?Array<SourceRepositoryInput> = None):
    GenerationRequest {
    GenerationRequest(SOURCE_PROVENANCE_FIXTURE, lintProfile: "off",
        sourceRepositories: sourceRepositories, astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT)
}

private func sourceProvenanceFixtureFile(documentation: api_model.DocumentationSet,
    path!: String = "src/api.cj"): api_model.FileDoc {
    for (file in documentation.files where file.path == path) { return file }
    throw IllegalArgumentException("source provenance fixture file is missing")
}

private func sourceProvenanceFixtureSymbol(documentation: api_model.DocumentationSet): api_model.SymbolDoc {
    for (symbol in documentation.declarations where symbol.name == "inspectSnapshot") { return symbol }
    throw IllegalArgumentException("source provenance fixture declaration is missing")
}

private let SOURCE_PROVENANCE_TEST_URL = "https://github.com/example/source-provenance-test"
private let SOURCE_PROVENANCE_TEST_REVISION = "1111111111111111111111111111111111111111"

private func sourceProvenanceTestSource(name: String): String {
    "package source_provenance_test\npublic func ${name}(): Unit {}\n"
}

private func sourceProvenanceWriteProject(root: Path, paths: Array<String>,
    sources: Array<String>): Unit {
    Directory.create(root.join("evidence"), recursive: true)
    File.writeTo(root.join("cjpm.toml"),
        "[package]\nname = \"source_provenance_test\"\n".toArray())
    var index: Int64 = 0
    while (index < paths.size) {
        let sourcePath = root.join(paths[index])
        if (!exists(sourcePath.parent)) { Directory.create(sourcePath.parent, recursive: true) }
        File.writeTo(sourcePath, sources[index].toArray())
        index++
    }
}

private func sourceProvenanceReceiptText(url: String, revision: String,
    paths: Array<String>, digests: Array<String>): String {
    let out = StringBuilder()
    out.append("{\"schemaVersion\":\"cjdoc.source-provenance/1\",\"repository\":")
    out.append("{\"url\":\"${url}\",\"revision\":\"${revision}\"},\"files\":[")
    var index: Int64 = 0
    while (index < paths.size) {
        if (index > 0) { out.append(",") }
        out.append("{\"path\":\"${paths[index]}\",\"sha256\":\"${digests[index]}\"}")
        index++
    }
    out.append("]}")
    out.toString()
}

private func sourceProvenanceInput(root: String, repositoryPath: String,
    repository: api_model.RepositoryInfo, pin: String,
    receipt!: String = "evidence/source.json"): SourceRepositoryInput {
    SourceRepositoryInput(root, repository, repositoryPath: repositoryPath,
        receipt: Some(receipt), receiptSha256: Some(pin))
}

private func sourceProvenanceWriteConfig(root: Path,
    registrations: Array<SourceRepositoryInput>): Unit {
    let out = StringBuilder()
    for (registration in registrations) {
        out.append("[[source.repositories]]\n")
        out.append("root = \"${registration.root}\"\n")
        out.append("url = \"${registration.repository.url}\"\n")
        out.append("revision = \"${registration.repository.revision}\"\n")
        out.append("repository-path = \"${registration.repositoryPath}\"\n")
        out.append("receipt = \"${registration.receipt.getOrThrow()}\"\n")
        out.append("receipt-sha256 = \"${registration.receiptSha256.getOrThrow()}\"\n")
    }
    File.writeTo(root.join("cjdoc.toml"), out.toString().toArray())
}

private func sourceProvenanceGenerateWithReceipt(root: Path,
    repository: api_model.RepositoryInfo, receiptText: String,
    repositoryPath!: String = "src", pin!: ?String = None): api_model.DocumentationSet {
    File.writeTo(root.join("evidence/source.json"), receiptText.toArray())
    let actualPin = Sha256Digest.digestBytes(receiptText.toArray())
    let registration = sourceProvenanceInput("src", repositoryPath, repository,
        pin.getOrDefault({ => actualPin }))
    return DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
        sourceRepositories: Some([registration]),
        astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
}

private func sourceProvenanceGenerate(root: Path,
    registrations: Array<SourceRepositoryInput>): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
        sourceRepositories: Some(registrations),
        astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
}

@Test
class SourceProvenanceCaptureTest {
    @TestCase
    func pinnedReceiptAndFrozenCaptureFactsSurvivePublicProjection(): Unit {
        let documentation = DocumentationEngine().generate(sourceProvenanceFixtureRequest())
        let provenance = sourceProvenanceFixtureFile(documentation).provenance
        @Expect(provenance.state, "verified")
        @Expect(provenance.reason, "receipt_matched")
        @Expect(provenance.repositoryPath, Some("src/api.cj"))
        @Expect(provenance.sourceDigest, Some(SOURCE_PROVENANCE_FIXTURE_DIGEST))
        @Expect(provenance.normalizedDigest, Some(SOURCE_PROVENANCE_FIXTURE_DIGEST))
        @Expect(provenance.evidenceKind, "caller_pinned_receipt")
        @Expect(provenance.evidenceIdentity.isSome(), true)
        @Expect(provenance.repository.getOrThrow().revision,
            "1111111111111111111111111111111111111111")
        let symbol = sourceProvenanceFixtureSymbol(documentation)
        @Expect(symbol.source.path, "src/api.cj")
        @Expect(symbol.source.start.line, 4)
        @Expect(documentation.schemaVersion, "cjdoc.doc-ir/18")
    }

    @TestCase
    func fileRegistrationsMatchCanonicalPathsWithoutCapturingSiblings(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let source = sourceProvenanceTestSource("registered")
            let sibling = sourceProvenanceTestSource("unregistered")
            sourceProvenanceWriteProject(root, ["src/api.cj", "src/api.cj.more.cj"], [source, sibling])
            let digest = Sha256Digest.digestBytes(source.toArray())
            let receipt = sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION, ["upstream/exact.cj"], [digest])
            File.writeTo(root.join("evidence/source.json"), receipt.toArray())
            let pin = Sha256Digest.digestBytes(receipt.toArray())
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            let absoluteRoot = canonicalize(root.join("src/api.cj")).toString()
            let documentation = sourceProvenanceGenerate(root, [
                sourceProvenanceInput("src/api.cj", "upstream/exact.cj", repository, pin),
                sourceProvenanceInput(absoluteRoot, "upstream/exact.cj", repository, pin)
            ])
            let matched = sourceProvenanceFixtureFile(documentation).provenance
            @Expect(matched.state, "verified")
            @Expect(matched.reason, "receipt_matched")
            @Expect(matched.repositoryPath, Some("upstream/exact.cj"))
            @Expect(matched.sourceDigest, Some("sha256:" + digest))
            @Expect(matched.evidenceIdentity, Some("sha256:" + pin))
            let unmatched = sourceProvenanceFixtureFile(documentation, path: "src/api.cj.more.cj").provenance
            @Expect(unmatched.state, "unavailable")
            @Expect(unmatched.reason, "no_registration")
            @Expect(unmatched.repository.isNone(), true)
            @Expect(unmatched.sourceDigest.isNone(), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func explicitEmptyOverrideEnablesStrictNoFallbackMode(): Unit {
        let documentation = DocumentationEngine().generate(
            sourceProvenanceFixtureRequest(sourceRepositories: Some([])))
        let provenance = sourceProvenanceFixtureFile(documentation).provenance
        @Expect(provenance.state, "unavailable")
        @Expect(provenance.reason, "no_registration")
        @Expect(provenance.repository.isNone(), true)
        @Expect(provenance.repositoryPath.isNone(), true)
    }

    @TestCase
    func legacyRepositoryMetadataCreatesDeclaredPerFileEvidenceWithoutClaimingVerification(): Unit {
        let repository = api_model.RepositoryInfo("https://github.com/example/legacy", "release/test")
        let documentation = DocumentationEngine().generate(GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", repository: Some(repository), lintProfile: "off",
            astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.project.repository.getOrThrow().url, repository.url)
        @Expect(documentation.project.repository.getOrThrow().revision, repository.revision)
        @Expect(documentation.files.isEmpty(), false)
        for (file in documentation.files) {
            @Expect(file.provenance.state, "declared")
            @Expect(file.provenance.reason, "legacy_project_repository")
            @Expect(file.provenance.repository.getOrThrow().url, repository.url)
            @Expect(file.provenance.repository.getOrThrow().revision, repository.revision)
            @Expect(file.provenance.sourceDigest.isNone(), true)
            @Expect(file.provenance.evidenceKind, "none")
        }
    }

    @TestCase
    func ordinaryTomlTablesDoNotDropPinnedSourceRegistrations(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let source = sourceProvenanceTestSource("stable")
            sourceProvenanceWriteProject(root, ["src/api.cj"], [source])
            File.writeTo(root.join("guide.md"), "# Source capture\n\nPinned source evidence.\n".toArray())
            let digest = Sha256Digest.digestBytes(source.toArray())
            let receipt = sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION, ["src/api.cj"], [digest])
            File.writeTo(root.join("evidence/source.json"), receipt.toArray())
            let pin = Sha256Digest.digestBytes(receipt.toArray())
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            sourceProvenanceWriteConfig(root, [sourceProvenanceInput("src", "src", repository, pin)])
            let registered = String.fromUtf8(File.readFrom(root.join("cjdoc.toml")))
            for (following in [
                "\n[docs]\n",
                "\n[[docs.pages]]\nsource = \"guide.md\"\nroute = \"concepts/guides/source\"\n" +
                    "id = \"source\"\nkind = \"guide\"\n"
            ]) {
                File.writeTo(root.join("cjdoc.toml"), (registered + following).toArray())
                let documentation = DocumentationEngine().generate(GenerationRequest(
                    root.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
                let provenance = sourceProvenanceFixtureFile(documentation).provenance
                @Expect(provenance.state, "verified")
                @Expect(provenance.reason, "receipt_matched")
                @Expect(provenance.repositoryPath, Some("src/api.cj"))
                @Expect(provenance.sourceDigest, Some("sha256:" + digest))
                @Expect(provenance.evidenceIdentity, Some("sha256:" + pin))
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func malformedPinnedReceiptsAreRejectedAtomically(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let first = sourceProvenanceTestSource("first")
            let second = sourceProvenanceTestSource("second")
            sourceProvenanceWriteProject(root, ["src/api.cj", "src/extra.cj"], [first, second])
            let firstDigest = Sha256Digest.digestBytes(first.toArray())
            let secondDigest = Sha256Digest.digestBytes(second.toArray())
            let goodPaths = ["src/api.cj", "src/extra.cj"]
            let goodDigests = [firstDigest, secondDigest]
            let malformedReceipts = [
                sourceProvenanceReceiptText("https://example.test/not-github",
                    SOURCE_PROVENANCE_TEST_REVISION, goodPaths, goodDigests),
                sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL, "not-a-full-sha",
                    goodPaths, goodDigests),
                sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL, SOURCE_PROVENANCE_TEST_REVISION,
                    goodPaths, [firstDigest, "not-a-sha256"]),
                sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL, SOURCE_PROVENANCE_TEST_REVISION,
                    ["src/api.cj", "src/api.cj"], [firstDigest, firstDigest]),
                sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL, SOURCE_PROVENANCE_TEST_REVISION,
                    ["src/api.cj", "../private.cj"], [firstDigest, secondDigest]),
                "{\"schemaVersion\":\"cjdoc.source-provenance/1\"," +
                    "\"schemaVersion\":\"cjdoc.source-provenance/1\"," +
                    "\"repository\":{\"url\":\"${SOURCE_PROVENANCE_TEST_URL}\"," +
                    "\"revision\":\"${SOURCE_PROVENANCE_TEST_REVISION}\"},\"files\":[]}"
            ]
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            for (receiptText in malformedReceipts) {
                let documentation = sourceProvenanceGenerateWithReceipt(root, repository, receiptText)
                for (path in goodPaths) {
                    let provenance = sourceProvenanceFixtureFile(documentation, path: path).provenance
                    @Expect(provenance.state, "unavailable")
                    @Expect(provenance.reason, "invalid_receipt")
                    @Expect(provenance.sourceDigest.isNone(), true)
                    @Expect(provenance.evidenceIdentity.isNone(), true)
                }
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func aWrongIndependentPinRejectsEveryReceiptRecord(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let first = sourceProvenanceTestSource("first")
            let second = sourceProvenanceTestSource("second")
            sourceProvenanceWriteProject(root, ["src/api.cj", "src/extra.cj"], [first, second])
            let receiptText = sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION, ["src/api.cj", "src/extra.cj"],
                [Sha256Digest.digestBytes(first.toArray()), Sha256Digest.digestBytes(second.toArray())])
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            let wrongPin = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            let documentation = sourceProvenanceGenerateWithReceipt(root, repository, receiptText,
                pin: Some(wrongPin))
            for (path in ["src/api.cj", "src/extra.cj"]) {
                let provenance = sourceProvenanceFixtureFile(documentation, path: path).provenance
                @Expect(provenance.state, "unavailable")
                @Expect(provenance.reason, "receipt_pin_mismatch")
                @Expect(provenance.repository.isNone(), true)
                @Expect(provenance.evidenceIdentity.isNone(), true)
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func receiptRepositoryUrlAndRevisionAreBoundPerRegistrationEvenOnPinCacheHit(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let first = sourceProvenanceTestSource("first")
            let urlMismatchSource = sourceProvenanceTestSource("urlMismatch")
            let revisionMismatchSource = sourceProvenanceTestSource("revisionMismatch")
            let filePaths = ["src/api.cj", "src/url-mismatch.cj", "src/revision-mismatch.cj"]
            let fileSources = [first, urlMismatchSource, revisionMismatchSource]
            sourceProvenanceWriteProject(root, filePaths, fileSources)
            let receiptText = sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION, filePaths, [
                    Sha256Digest.digestBytes(first.toArray()),
                    Sha256Digest.digestBytes(urlMismatchSource.toArray()),
                    Sha256Digest.digestBytes(revisionMismatchSource.toArray())])
            File.writeTo(root.join("evidence/source.json"), receiptText.toArray())
            let pin = Sha256Digest.digestBytes(receiptText.toArray())
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            let otherUrlRepository = api_model.RepositoryInfo(
                "https://github.com/example/other-source-provenance",
                SOURCE_PROVENANCE_TEST_REVISION)
            let otherRevisionRepository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                "2222222222222222222222222222222222222222")
            let registrations = [
                sourceProvenanceInput("src/api.cj", "src/api.cj", repository, pin),
                sourceProvenanceInput("src/url-mismatch.cj", "src/url-mismatch.cj",
                    otherUrlRepository, pin),
                sourceProvenanceInput("src/revision-mismatch.cj", "src/revision-mismatch.cj",
                    otherRevisionRepository, pin)
            ]
            let documentation = sourceProvenanceGenerate(root, registrations)
            let verified = sourceProvenanceFixtureFile(documentation, path: "src/api.cj").provenance
            let urlMismatch = sourceProvenanceFixtureFile(documentation,
                path: "src/url-mismatch.cj").provenance
            let revisionMismatch = sourceProvenanceFixtureFile(documentation,
                path: "src/revision-mismatch.cj").provenance
            @Expect(verified.state, "verified")
            @Expect(verified.repository.getOrThrow().url, repository.url)
            @Expect(urlMismatch.state, "unavailable")
            @Expect(urlMismatch.reason, "receipt_repository_mismatch")
            @Expect(urlMismatch.repository.isNone(), true)
            @Expect(urlMismatch.evidenceIdentity.isNone(), true)
            @Expect(revisionMismatch.state, "unavailable")
            @Expect(revisionMismatch.reason, "receipt_repository_mismatch")
            @Expect(revisionMismatch.repository.isNone(), true)
            @Expect(revisionMismatch.evidenceIdentity.isNone(), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func aBadFileDigestDoesNotInvalidateOtherFilesInThePinnedReceipt(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let first = sourceProvenanceTestSource("first")
            let second = sourceProvenanceTestSource("second")
            sourceProvenanceWriteProject(root, ["src/api.cj", "src/extra.cj"], [first, second])
            let receiptText = sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION, ["src/api.cj", "src/extra.cj"],
                ["ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
                    Sha256Digest.digestBytes(second.toArray())])
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            let documentation = sourceProvenanceGenerateWithReceipt(root, repository, receiptText)
            let mismatched = sourceProvenanceFixtureFile(documentation, path: "src/api.cj").provenance
            let verified = sourceProvenanceFixtureFile(documentation, path: "src/extra.cj").provenance
            @Expect(mismatched.state, "unavailable")
            @Expect(mismatched.reason, "digest_mismatch")
            @Expect(mismatched.sourceDigest,
                Some("sha256:${Sha256Digest.digestBytes(first.toArray())}"))
            @Expect(verified.state, "verified")
            @Expect(verified.reason, "receipt_matched")
            @Expect(verified.sourceDigest,
                Some("sha256:${Sha256Digest.digestBytes(second.toArray())}"))
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func equivalentRegistrationsDeduplicateAndConflictingMappingsBecomeAmbiguous(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let source = sourceProvenanceTestSource("stable")
            sourceProvenanceWriteProject(root, ["src/api.cj"], [source])
            let digest = Sha256Digest.digestBytes(source.toArray())
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            let equivalentReceipt = sourceProvenanceReceiptText(repository.url, repository.revision,
                ["src/api.cj"], [digest])
            File.writeTo(root.join("evidence/source.json"), equivalentReceipt.toArray())
            let equivalentPin = Sha256Digest.digestBytes(equivalentReceipt.toArray())
            let equivalent = sourceProvenanceInput("src", "src", repository, equivalentPin)
            let equivalentAlias = sourceProvenanceInput("./src", "src", repository, equivalentPin)
            let deduplicated = sourceProvenanceGenerate(root, [equivalent, equivalentAlias])
            @Expect(sourceProvenanceFixtureFile(deduplicated).provenance.state, "verified")

            let conflictReceipt = sourceProvenanceReceiptText(repository.url, repository.revision,
                ["first/api.cj", "second/api.cj"], [digest, digest])
            File.writeTo(root.join("evidence/source.json"), conflictReceipt.toArray())
            let conflictPin = Sha256Digest.digestBytes(conflictReceipt.toArray())
            let conflicting = sourceProvenanceGenerate(root, [
                sourceProvenanceInput("src", "first", repository, conflictPin),
                sourceProvenanceInput("src", "second", repository, conflictPin)])
            let provenance = sourceProvenanceFixtureFile(conflicting).provenance
            @Expect(provenance.state, "ambiguous")
            @Expect(provenance.reason, "conflicting_registration")
            @Expect(provenance.repository.isNone(), true)
            @Expect(provenance.repositoryPath.isNone(), true)
            @Expect(publicDiagnosticCount(conflicting, "CJDOC1032"), 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func newlineNormalizationCacheReplayAndCorruptionRetainSameCaptureFacts(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let cache = temporary.join("cache")
            let sourcePath = root.join("src/api.cj")
            let lfSource = sourceProvenanceTestSource("stableCapture")
            sourceProvenanceWriteProject(root, ["src/api.cj"], [lfSource])
            Directory.create(cache)
            let repository = api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION)
            let provider = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("source-provenance-capture-v1"),
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT)
            let variants = [lfSource, lfSource.replace("\n", "\r\n"), lfSource.replace("\n", "\r")]
            let normalizedDigest = Sha256Digest.digestBytes(lfSource.toArray())
            var capture: Int64 = 0
            for (rawSource in variants) {
                File.writeTo(sourcePath, rawSource.toArray())
                let receiptText = sourceProvenanceReceiptText(repository.url, repository.revision,
                    ["src/api.cj"], [Sha256Digest.digestBytes(rawSource.toArray())])
                File.writeTo(root.join("evidence/source.json"), receiptText.toArray())
                let registration = sourceProvenanceInput("src", "src", repository,
                    Sha256Digest.digestBytes(receiptText.toArray()))
                sourceProvenanceWriteConfig(root, [registration])
                let snapshot = provider.collect(root.toString())
                let origin = snapshot.sourceFileOrigins[0]
                let facts = origin.capturedFacts.getOrThrow()
                @Expect(facts.rawDigest, Some(Sha256Digest.digestBytes(rawSource.toArray())))
                @Expect(facts.normalizedDigest, Some(normalizedDigest))
                @Expect(origin.capturedSource, lfSource)
                @Expect(origin.provenance.getOrThrow().sourceDigest,
                    Some("sha256:${Sha256Digest.digestBytes(rawSource.toArray())}"))
                @Expect(origin.provenance.getOrThrow().normalizedDigest,
                    Some("sha256:${normalizedDigest}"))
                @Expect(provider.cacheStats.writes, if (capture == 0) { 1 } else { 0 })
                @Expect(provider.cacheStats.hits, if (capture == 0) { 0 } else { 1 })
                capture++
            }
            let entries = Directory.readFrom(cache)
            @Assert(entries.size, 1)
            File.writeTo(entries[0].path, "corrupt cache entry".toArray())
            let corruptedSource = variants[1]
            File.writeTo(sourcePath, corruptedSource.toArray())
            let corruptedReceipt = sourceProvenanceReceiptText(repository.url, repository.revision,
                ["src/api.cj"], [Sha256Digest.digestBytes(corruptedSource.toArray())])
            File.writeTo(root.join("evidence/source.json"), corruptedReceipt.toArray())
            sourceProvenanceWriteConfig(root, [sourceProvenanceInput("src", "src", repository,
                Sha256Digest.digestBytes(corruptedReceipt.toArray()))])
            let recovered = provider.collect(root.toString())
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)
            @Expect(recovered.sourceFileOrigins[0].capturedFacts.getOrThrow().rawDigest,
                Some(Sha256Digest.digestBytes(corruptedSource.toArray())))
            @Expect(recovered.sourceFileOrigins[0].provenance.getOrThrow().state, "verified")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func providerMutationAfterCaptureCannotChangeVerifiedSourceEvidence(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let sourcePath = root.join("src/api.cj")
            let source = sourceProvenanceTestSource("capturedBeforeMutation")
            sourceProvenanceWriteProject(root, ["src/api.cj"], [source])
            let receiptText = sourceProvenanceReceiptText(SOURCE_PROVENANCE_TEST_URL,
                SOURCE_PROVENANCE_TEST_REVISION, ["src/api.cj"],
                [Sha256Digest.digestBytes(source.toArray())])
            File.writeTo(root.join("evidence/source.json"), receiptText.toArray())
            let registration = sourceProvenanceInput("src", "src",
                api_model.RepositoryInfo(SOURCE_PROVENANCE_TEST_URL, SOURCE_PROVENANCE_TEST_REVISION),
                Sha256Digest.digestBytes(receiptText.toArray()))
            let capture = SourceMutationCapture()
            let documentation = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", sourceRepositories: Some([registration]),
                providerFactories: [SourceMutationFactory(sourcePath.toString(), capture)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            let provenance = sourceProvenanceFixtureFile(documentation).provenance
            @Expect(capture.endOffset > capture.startOffset, true)
            @Expect(provenance.state, "verified")
            @Expect(provenance.sourceDigest,
                Some("sha256:${Sha256Digest.digestBytes(source.toArray())}"))
            @Expect(provenance.normalizedDigest,
                Some("sha256:${Sha256Digest.digestBytes(source.toArray())}"))
            @Expect(provenance.evidenceKind, "caller_pinned_receipt")
            @Expect(Sha256Digest.digestBytes(File.readFrom(sourcePath)) ==
                Sha256Digest.digestBytes(source.toArray()), false)
            @Expect(documentation.declarations.size, 1)
            @Expect(documentation.declarations[0].source.path, "src/api.cj")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }
}
