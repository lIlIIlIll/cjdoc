package cjdoc

import cjdoc.source.discovery.SyntaxSourceProvider
import cjdoc.source.cache.{SourceCacheWriter, SourceCacheReader, cacheReadOptionalString}
import cjdoc.source.SOURCE_CACHE_FORMAT
import cjdoc.digest.Sha256Digest
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
class SourcePipelineSuite3 {
    @TestCase
    func genericConstraintCacheRoundTripsAndInvalidatesOlderSourceEntries(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let project = temporary.join("project")
            let cache = temporary.join("cache")
            Directory.create(project.join("src"), recursive: true)
            Directory.create(cache)
            File.writeTo(project.join("cjpm.toml"),
                "[package]\nname = \"constraints\"\n".toArray())
            let source = "package constraints\npublic interface Widget {}\npublic interface Container<T> {}\n" +
                "public func constrained<T>(input: T): T where T <: Widget & Container<T> { input }\n"
            File.writeTo(project.join("src/api.cj"), source.toArray())
            let fingerprint = "source-constraint-cache-v1"
            let provider = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some(fingerprint), astPreflightExecutable: TEST_AST_PREFLIGHT)
            let cold = provider.collect(project.toString())
            @Expect(provider.cacheStats.writes, 1)
            let entries = Directory.readFrom(cache)
            @Assert(entries.size, 1)
            let cachePath = entries[0].path
            let bytes = File.readFrom(cachePath)
            let reader = SourceCacheReader(bytes)
            @Expect(reader.next(), SOURCE_CACHE_FORMAT)
            let key = reader.next()
            let legacyKey = SourceCacheWriter()
            for (value in ["cjdoc-source-cache-v17", fingerprint, "src/api.cj",
                cold.modules[0].id, "constraints", source]) { legacyKey.add(value) }
            @Expect(key != Sha256Digest.digestBytes(legacyKey.result().getOrThrow()), true)
            let warm = provider.collect(project.toString())
            @Expect(provider.cacheStats.hits, 1)
            for (snapshot in [cold, warm]) {
                var found = false
                for (declaration in snapshot.declarations) {
                    if (declaration.name != "constrained") { continue }
                    found = true
                    @Assert(declaration.relationships.size, 2)
                    @Expect(declaration.relationships[0].kind, "genericConstraint")
                    @Expect(declaration.relationships[0].targetSpelling, "Widget")
                    @Expect(declaration.relationships[1].targetSpelling.replace(" ", ""), "Container<T>")
                }
                @Expect(found, true)
            }
            // Even an older source-cache payload placed under the new cache filename
            // is rejected before decoding declarations, then rebuilt from AST.
            let legacy = String.fromUtf8(bytes).replace(SOURCE_CACHE_FORMAT, "cjdoc-source-cache-v19")
            File.writeTo(cachePath, legacy.toArray())
            let reparsed = provider.collect(project.toString())
            @Expect(provider.cacheStats.hits, 0)
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)
            @Expect(reparsed.declarations.size, cold.declarations.size)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func discoversCommentedManifestHeadersThroughPublicApi(): Unit {
        let documentation = generateFixture("manifest_headers",
            includePathDependencies: true, includeCachedDependencies: true,
            cjpmCacheRoot: Some(nativeFixturePath("tests/fixtures/cjpm_cache")))
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
    func macroDeclarationsAreCollectedAndBrokenSourcesProducePartialIr(): Unit {
        let unsupported = generateFixture("unsupported")
        @Expect(unsupported.status, "complete")
        @Expect(unsupported.unsupportedDeclarations.size, 0)
        @Expect(declarationNamed(unsupported, "Echo").kind, "macro")
        @Expect(containsDiagnostic(unsupported, "CJDOC1009"), false)

        let recovery = generateFixture("recovery")
        @Expect(recovery.status, "partial")
        @Expect(recovery.declarations.size, 1)
        @Expect(containsDiagnostic(recovery, "CJDOC1011"), true)
    }

    @TestCase
    func recordsFrontendGapsWithoutTraversingFunctionBodies(): Unit {
        let documentation = generateFixture("frontend_gaps")
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 2)
        @Expect(declarationNamed(documentation, "Generated").kind, "class")
        @Expect(declarationNamed(documentation, "outer").documentation.isSome())
        @Expect(documentation.orphanDocComments.size, 2)
        @Expect(documentation.macroInvocations.size, 1)
        @Expect(documentation.macroInvocations[0].name, "missing.Generate")
        @Expect(documentation.unsupportedDeclarations.size, 0)
        @Expect(containsDiagnostic(documentation, "CJDOC1009"), true)
        @Expect(containsDiagnostic(documentation, "CJDOC1014"), true)
    }

    @TestCase
    func rejectsChecksumTamperingAndOversizedSourceCacheEntries(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let cache = temporary.join("cache")
            Directory.create(cache)
            let provider = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
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
    @TestCase
    func rejectsChecksumValidImportMetadataTampering(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let project = temporary.join("project")
            let cache = temporary.join("cache")
            Directory.create(project.join("src"), recursive: true)
            Directory.create(cache)
            File.writeTo(project.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.3.0"
                name = "cache_integrity"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(project.join("src/main.cj"),
                """
                package cache_integrity
                public import cache_orig.Foo
                public class Api {}
                """.toArray())
            let provider = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("cache-import-integrity-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT)
            let cold = provider.collect(project.toString())
            @Expect(cold.sourceFileOrigins.size, 1)
            @Expect(cold.sourceFileOrigins[0].imports[0], "public import cache_orig.Foo")
            @Expect(cold.sourceFileOrigins[0].packageImports[0], "cache_orig")
            let validProvider = SyntaxSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("cache-import-integrity-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT)
            let validCacheHit = validProvider.collect(project.toString())
            @Expect(validCacheHit.sourceFileOrigins[0].imports[0], "public import cache_orig.Foo")
            @Expect(validCacheHit.sourceFileOrigins[0].packageImports[0], "cache_orig")
            @Expect(validProvider.cacheStats.hits, 1)
            let entries = Directory.readFrom(cache)
            @Expect(entries.size, 1)
            let cachePath = entries[0].path
            let bytes = File.readFrom(cachePath)
            let reader = SourceCacheReader(bytes)
            @Expect(reader.next(), SOURCE_CACHE_FORMAT)
            let _ = reader.next()
            let _ = cacheReadOptionalString(reader)
            @Expect(reader.nextCount(), 1)
            let originalImport = reader.next()
            let importStart = reader.offset - originalImport.toArray().size
            @Expect(reader.nextCount(), 1)
            let originalPackage = reader.next()
            let packageStart = reader.offset - originalPackage.toArray().size
            @Expect(originalPackage, "cache_orig")
            let replacementPackage = "cache_fake"
            let replacementImport = originalImport.replace(originalPackage, replacementPackage)
            @Expect(replacementImport.size, originalImport.size)
            let replacementImportBytes = replacementImport.toArray()
            let replacementPackageBytes = replacementPackage.toArray()
            var index: Int64 = 0
            while (index < replacementImportBytes.size) {
                bytes[importStart + index] = replacementImportBytes[index]
                index++
            }
            index = 0
            while (index < replacementPackageBytes.size) {
                bytes[packageStart + index] = replacementPackageBytes[index]
                index++
            }
            let checksumStart = bytes.size - 67
            @Expect(bytes[checksumStart], b'6')
            @Expect(bytes[checksumStart + 1], b'4')
            @Expect(bytes[checksumStart + 2], b':')
            let checksum = Sha256Digest.digestBytes(bytes[..checksumStart]).toArray()
            @Expect(checksum.size, 64)
            index = 0
            while (index < checksum.size) {
                bytes[checksumStart + 3 + index] = checksum[index]
                index++
            }
            File.writeTo(cachePath, bytes)

            let repaired = provider.collect(project.toString())
            @Expect(repaired.sourceFileOrigins[0].imports[0], "public import cache_orig.Foo")
            @Expect(repaired.sourceFileOrigins[0].packageImports[0], "cache_orig")
            @Expect(provider.cacheStats.hits, 0)
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }
}
