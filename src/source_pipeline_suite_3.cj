package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
class SourcePipelineSuite3 {
    @TestCase
    func sharesTomlByteAndWorkLimitsAcrossAllParsedArrays(): Unit {
        let text = "[package]\nname = \"sample\"\n" +
            "[workspace]\nmembers = [\"a\", \"b\"]\n" +
            "[dependencies]\ndep = { path = \"../dep\" }\n"
        let byteLimited = parseCjpmManifest(text, maxBytes: text.size - 1)
        @Expect(byteLimited.limitReached, true)
        @Expect(byteLimited.workspaceMembers.size, 0)
        @Expect(byteLimited.pathDependencies.size, 0)

        let workLimited = parseCjpmManifest(text, maxWork: text.size + 1)
        @Expect(workLimited.limitReached, true)
        let lockText = "[requires]\na = { version = \"1\" }\nb = { version = \"2\" }\n"
        let lockLimited = parseCjpmLock(lockText, maxWork: lockText.size - 1)
        @Expect(lockLimited.limitReached, true)
    }

    @TestCase
    func ignoresTomlHeadersInsideMultilineStringsAndBoundsAdapterEntries(): Unit {
        let basicFence = "\"\"\""
        let literalFence = "'''"
        let manifest = parseCjpmManifest(
            "[package]\nname = \"sample\"\ndescription = ${basicFence}\n" +
            "[workspace] # example only\nmembers = [\"ghost\"]\n${basicFence}\n" +
            "notes = ${literalFence}\n[dependencies] # example only\n" +
            "ghost = { path = \"../ghost\" }\n${literalFence}\n" +
            "[workspace] # real\nmembers = [\"member\"]\n" +
            "[dependencies] # real\ndep = { path = \"../dep\" }\n")
        @Expect(manifest.packageName, Some("sample"))
        @Expect(manifest.workspaceMembers.size, 1)
        @Expect(manifest.workspaceMembers[0], "member")
        @Expect(manifest.pathDependencies.size, 1)
        @Expect(manifest.pathDependencies[0], "../dep")

        let lock = parseCjpmLock(
            "notes = ${basicFence}\n[requires] # example only\n" +
            "ghost = { version = \"0.0.0\" }\n${basicFence}\n" +
            "[requires] # real\ndep = { version = \"1.0.0\" }\n")
        @Expect(lock.dependencies.size, 1)
        @Expect(lock.dependencies[0].name, "dep")

        let members = parseCjpmWorkspaceMembers(
            "[workspace]\nmembers = [\"a\", \"b\", \"c\"]\n", 2)
        @Expect(members.values.size, 2)
        @Expect(members.values[0], "a")
        @Expect(members.values[1], "b")
        @Expect(members.entryCount, 2)
        @Expect(members.limitReached, true)

        let paths = parseCjpmPathDependencies(
            "[dependencies]\na = { path = \"a\" }\nb = { path = \"b\" }\n", 1)
        @Expect(paths.values.size, 1)
        @Expect(paths.values[0], "a")
        @Expect(paths.limitReached, true)

        let boundedLock = parseCjpmLock(
            "[requires]\na = { version = \"1\" }\nb = { version = \"2\" }\n",
            maxEntries: 1)
        @Expect(boundedLock.dependencies.size, 1)
        @Expect(boundedLock.entryCount, 1)
        @Expect(boundedLock.limitReached, true)
    }

    @TestCase
    func boundsCacheEncodingAndCapturedSourceOffsets(): Unit {
        let exact = SourceCacheWriter(maxBytes: 3)
        exact.add("a")
        @Expect(exact.result().getOrThrow(), "1:a".toArray())

        let exceeded = SourceCacheWriter(maxBytes: 2)
        exceeded.add("a")
        @Expect(exceeded.result().isNone(), true)

        let aggregateWriter = SourceCacheWriter(maxItems: 2)
        @Expect(aggregateWriter.addCount(1), true)
        @Expect(aggregateWriter.addCount(1), true)
        @Expect(aggregateWriter.addCount(1), false)
        @Expect(aggregateWriter.result().isNone(), true)

        let aggregateReader = SourceCacheReader("1:21:1".toArray(), maxItems: 2)
        @Expect(aggregateReader.nextCount(), 2)
        @ExpectThrows[IllegalArgumentException](aggregateReader.nextCount())

        let defaultSignature =
            "public func sample(required: Int64, count!: Int64 = 40  + /*note*/ 2, " +
            "label!: String = \"cjdoc\"): Unit"
        let exactDefaults = SourceDeclaration("exact-defaults", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        exactDefaults.parameters.add(SourceParameter("required", "Int64"))
        exactDefaults.parameters.add(SourceParameter("count", "Int64",
            defaultExpression: Some("40 + 2")))
        exactDefaults.parameters.add(SourceParameter("label", "String",
            defaultExpression: Some("\"cjdoc\"")))
        validateCachedParameterDefaults(exactDefaults)

        let swappedDefaults = SourceDeclaration("swapped-defaults", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        swappedDefaults.parameters.add(SourceParameter("required", "Int64"))
        swappedDefaults.parameters.add(SourceParameter("count", "Int64",
            defaultExpression: Some("\"cjdoc\"")))
        swappedDefaults.parameters.add(SourceParameter("label", "String",
            defaultExpression: Some("40 + 2")))
        @ExpectThrows[IllegalArgumentException](validateCachedParameterDefaults(swappedDefaults))

        let missingDefault = SourceDeclaration("missing-default", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        missingDefault.parameters.add(SourceParameter("required", "Int64"))
        missingDefault.parameters.add(SourceParameter("count", "Int64"))
        missingDefault.parameters.add(SourceParameter("label", "String",
            defaultExpression: Some("\"cjdoc\"")))
        @ExpectThrows[IllegalArgumentException](validateCachedParameterDefaults(missingDefault))

        let missingParameters = SourceDeclaration("missing-parameters", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        @ExpectThrows[IllegalArgumentException](validateCachedParameterDefaults(missingParameters))

        let captured = CapturedSourceIndex("a\nβ")
        @Expect(captured.available, true)
        @Expect(captured.byteOffset(1, 1), Some(0))
        @Expect(captured.byteOffset(1, 2), Some(1))
        @Expect(captured.byteOffset(1, 3), None<Int64>)
        @Expect(captured.byteOffset(2, 1), Some(2))
        @Expect(captured.byteOffset(2, 3), Some(4))
        @Expect(captured.byteOffset(2, 4), None<Int64>)
        @Expect(captured.positionMatches(2, 3, 4), true)
        @Expect(captured.positionMatches(2, 3, 3), false)
        @Expect(sourceCacheLocationMatchesCaptured(
            SourceLocation("src/api.cj", 1, 1, 2, 3), "src/api.cj", captured), true)
        @Expect(sourceCacheLocationMatchesCaptured(
            SourceLocation("src/api.cj", 1, 1, 2, 4), "src/api.cj", captured), false)
        @Expect(sourceCacheLocationMatchesCaptured(
            SourceLocation("src/other.cj", 1, 1, 2, 3), "src/api.cj", captured), false)

        let tooManyLines = CapturedSourceIndex("a\nb\nc", maxLines: 2)
        @Expect(tooManyLines.available, false)
        @Expect(tooManyLines.byteOffset(1, 1), None<Int64>)

        let owner = SourceDeclaration("owner", "class", "Owner", "pkg", "module",
            "public", SourceLocation("src/api.cj", 1, 1, 3, 2), "public class Owner",
            isContainer: true)
        let child = SourceDeclaration("child", "function", "child", "pkg", "module",
            "public", SourceLocation("src/api.cj", 2, 1, 2, 22),
            "public func child(): Unit")
        child.ownerSourceKey = Some(owner.sourceKey)
        let ownerGraph = ArrayList<SourceDeclaration>()
        ownerGraph.add(owner)
        ownerGraph.add(child)
        validateSourceCacheOwnerGraph(ownerGraph, maxDepth: 2)
        @ExpectThrows[IllegalArgumentException](
            validateSourceCacheOwnerGraph(ownerGraph, maxDepth: 1))
        owner.ownerSourceKey = Some(child.sourceKey)
        @ExpectThrows[IllegalArgumentException](validateSourceCacheOwnerGraph(ownerGraph))
    }

    @TestCase
    func discoversCommentedManifestHeadersThroughPublicApi(): Unit {
        let documentation = generateFixture("manifest_headers",
            includePathDependencies: true, includeCachedDependencies: true,
            cjpmCacheRoot: Some("tests/fixtures/cjpm_cache"))
        @Expect(documentation.status, "complete")
        @Expect(documentation.project.name, "manifest_headers")
        @Expect(documentation.modules.size, 5)
        for (name in ["rootApi", "memberApi", "pathApi", "cachedApi", "transitiveApi"]) {
            @Expect(declarationNamed(documentation, name).documentation.isSome(), true)
        }
        @Expect(documentation.diagnostics.size, 0)
    }

    @TestCase
    func reportsLintWithoutDroppingDeclarations(): Unit {
        let documentation = generateFixture("lint", lintProfile: "standard")
        @Expect(documentation.declarations.size, 3)
        @Expect(documentation.status, "complete")
        for (code in ["CJDOC3001", "CJDOC3002", "CJDOC3003", "CJDOC3005", "CJDOC3008"]) {
            @Expect(containsDiagnostic(documentation, code), true)
        }
    }

    @TestCase
    func unsupportedAndBrokenSourcesProducePartialIr(): Unit {
        let unsupported = generateFixture("unsupported")
        @Expect(unsupported.status, "partial")
        @Expect(unsupported.unsupportedDeclarations.size, 1)
        @Expect(containsDiagnostic(unsupported, "CJDOC1009"), true)

        let recovery = generateFixture("recovery")
        @Expect(recovery.status, "partial")
        @Expect(recovery.declarations.size, 1)
        @Expect(containsDiagnostic(recovery, "CJDOC1011"), true)
    }

    @TestCase
    func recordsFrontendGapsWithoutTraversingFunctionBodies(): Unit {
        let documentation = generateFixture("frontend_gaps")
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 1)
        @Expect(documentation.declarations[0].name, "outer")
        @Expect(documentation.declarations[0].documentation.isSome())
        @Expect(documentation.orphanDocComments.size, 2)
        @Expect(documentation.macroInvocations.size, 1)
        @Expect(documentation.macroInvocations[0].name, "missing.Generate")
        @Expect(documentation.unsupportedDeclarations.size, 1)
        @Expect(containsDiagnostic(documentation, "CJDOC1009"), true)
        @Expect(containsDiagnostic(documentation, "CJDOC1014"), true)
    }

    @TestCase
    func rejectsChecksumTamperingAndOversizedSourceCacheEntries(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let cache = temporary.join("cache")
            Directory.create(cache)
            let provider = AstSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("source-cache-contract-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT)
            let first = provider.collect(FIXTURES + "basic")
            @Expect(first.declarations.size, 25)
            @Expect(provider.cacheStats.writes, 1)
            let entries = Directory.readFrom(cache)
            @Expect(entries.size, 1)
            let cachePath = entries[0].path
            let corrupted = File.readFrom(cachePath)
            let last = corrupted.size - 1
            corrupted[last] = if (corrupted[last] == b'0') { b'1' } else { b'0' }
            File.writeTo(cachePath, corrupted)

            let reparsed = provider.collect(FIXTURES + "basic")
            @Expect(reparsed.declarations.size, 25)
            @Expect(provider.cacheStats.hits, 0)
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)

            let oversizedEntry = File(cachePath, OpenMode.ReadWrite)
            try {
                oversizedEntry.setLength(64 * 1024 * 1024 + 1)
            } finally {
                oversizedEntry.close()
            }
            let oversized = provider.collect(FIXTURES + "basic")
            @Expect(oversized.declarations.size, 25)
            @Expect(provider.cacheStats.hits, 0)
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

}
