protected package cjdoc.source.cache

import cjdoc.source.SourceLocation
import cjdoc.source.model.{CapturedSourceIndex, SourceDeclaration, SourceInputFile, SourceModule, SourceParameter}
import std.ast.cangjieLex
import std.collection.ArrayList
import std.env.getTempDirectory
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class SourceCacheValidationTest {
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
    func defaultTokenComparisonIgnoresNewlinesButRejectsChangedValues(): Unit {
        let source = cangjieLex("1\n")
        @Expect(cachedDefaultMatchesSourceTokens("1", source, 0, source.size), true)
        @Expect(cachedDefaultMatchesSourceTokens("2", source, 0, source.size), false)
        let closure = cangjieLex("{ value => value }")
        @Expect(cachedDefaultMatchesSourceTokens("{\nvalue => value\n}", closure,
            0, closure.size), true)
        @Expect(cachedDefaultMatchesSourceTokens("{ value => 0 }", closure,
            0, closure.size), false)
    }

    @TestCase
    func sourceParseWorkerRejectsNormalizedOutputTraversal(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let workerRoot = temporary.join("worker")
            Directory.create(workerRoot)
            let sourcePath = workerRoot.join("source.cj")
            let requestPath = workerRoot.join("request.bin")
            let escapedPath = temporary.join("escaped.bin")
            let sourceText = "package worker_safe\npublic func value(): Int64 { 1 }\n"
            File.writeTo(sourcePath, sourceText.toArray())
            let input = SourceInputFile(sourcePath.toString(), workerRoot.toString(),
                "src/source.cj", SourceModule("worker-safe", "worker_safe", "root", ""),
                sourceText.toArray().size)
            writeSourceParseWorkerRequest(requestPath, sourcePath,
                Path(workerRoot.toString() + "/../escaped.bin"), input, "worker_safe",
                sourceParseWorkerCacheKey(sourceText))
            @Expect(runSourceParseWorker(requestPath.toString()) != 0, true)
            @Expect(exists(escapedPath), false)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }
}
