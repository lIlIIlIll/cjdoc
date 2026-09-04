package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
class SourcePipelineSuite5 {
    @TestCase
    func failsClosedOnModuleAndLogicalPathCollisions(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let nested = temporary.join("nested")
            Directory.create(nested.join("src/member/src"), recursive: true)
            File.writeTo(nested.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "nested_root"
                version = "0.1.0"
                output-type = "static"

                [workspace]
                members = ["src/member"]
                """.toArray())
            File.writeTo(nested.join("src/member/cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "nested_member"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(nested.join("src/root.cj"),
                "package nested_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(nested.join("src/member/src/member.cj"),
                "package nested_member\npublic func memberApi(): Unit {}\n".toArray())

            let nestedResult = DocumentationEngine().generate(GenerationRequest(
                nested.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(nestedResult.status, "partial")
            @Expect(containsDiagnostic(nestedResult, "CJDOC1010"), true)
            @Expect(nestedResult.modules.size, 1)
            @Expect(nestedResult.declarations.size, 0)

            let duplicate = temporary.join("duplicate")
            Directory.create(duplicate.join("src"), recursive: true)
            Directory.create(duplicate.join("deps/a/src"), recursive: true)
            Directory.create(duplicate.join("deps/b/src"), recursive: true)
            File.writeTo(duplicate.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "duplicate_root"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                a = { path = "deps/a" }
                b = { path = "deps/b" }
                """.toArray())
            for (name in ["a", "b"]) {
                File.writeTo(duplicate.join("deps/${name}/cjpm.toml"), """
                    [package]
                    cjc-version = "1.1.0"
                    name = "duplicate_dep"
                    version = "0.1.0"
                    output-type = "static"
                    """.toArray())
                File.writeTo(duplicate.join("deps/${name}/src/api.cj"),
                    "package duplicate_dep\npublic func ${name}Api(): Unit {}\n".toArray())
            }
            File.writeTo(duplicate.join("src/root.cj"),
                "package duplicate_root\npublic func rootApi(): Unit {}\n".toArray())
            let duplicateResult = DocumentationEngine().generate(GenerationRequest(
                duplicate.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(duplicateResult.status, "partial")
            @Expect(containsDiagnostic(duplicateResult, "CJDOC1016"), true)
            @Expect(duplicateResult.modules.size, 2)
            @Expect(duplicateResult.declarations.size, 2)

            @Expect(relativePathFromResolved("/project",
                "/project/src/a\\b.cj").isNone(), true)
            @Expect(relativePathFromResolved("/project\\root",
                "/project\\root/src/a.cj"), Some("src/a.cj"))
            @Expect(relativePathFromResolved("/", "/src/a.cj"), Some("src/a.cj"))
            @Expect(relativePathFromResolved("C:\\project",
                "C:\\project\\src\\a.cj"), Some("src/a.cj"))

            let posix = temporary.join("posix-backslash")
            Directory.create(posix.join("src/a"), recursive: true)
            if (canonicalize(posix).toString().startsWith("/")) {
                File.writeTo(posix.join("cjpm.toml"), """
                    [package]
                    cjc-version = "1.1.0"
                    name = "posix_backslash"
                    version = "0.1.0"
                    output-type = "static"
                    """.toArray())
                File.writeTo(posix.join("src/a/b.cj"),
                    "package posix_backslash\npublic func slashApi(): Unit {}\n".toArray())
                File.writeTo(Path(posix.join("src").toString() + "/a\\b.cj"),
                    "package posix_backslash\npublic func backslashApi(): Unit {}\n".toArray())
                let posixResult = DocumentationEngine().generate(GenerationRequest(
                    posix.toString(), lintProfile: "off", audience: "all",
                    astPreflightExecutable: TEST_AST_PREFLIGHT))
                @Expect(posixResult.status, "partial")
                @Expect(containsDiagnostic(posixResult, "CJDOC1010"), true)
                @Expect(posixResult.modules.size, 1)
                @Expect(posixResult.declarations.size, 0)
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func sharesDirectoryEntryBudgetAcrossWorkspaceModules(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("bounded")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("member/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "bounded_root"
                version = "0.1.0"
                output-type = "static"

                [workspace]
                members = ["member"]
                """.toArray())
            File.writeTo(root.join("member/cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "bounded_member"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(root.join("src/root.cj"),
                "package bounded_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("member/src/member.cj"),
                "package bounded_member\npublic func memberApi(): Unit {}\n".toArray())

            let snapshot = AstSourceProvider(astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceDirectoryEntryLimit: 1).collect(root.toString())
            var limitDiagnostics: Int64 = 0
            for (diagnostic in snapshot.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { limitDiagnostics++ }
            }
            @Expect(limitDiagnostics, 1)
            @Expect(snapshot.modules.size, 2)
            @Expect(snapshot.declarations.size, 0)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func discoversUnicodeWorkspaceAndPathMetadataAndRejectsInvalidEscapes(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("unicode")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("成员/src"), recursive: true)
            Directory.create(root.join("依赖/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), (
                "[package]\nname = \"unicode_root\"\n" +
                "[workspace]\nmembers = [\"成\\u5458\"]\n" +
                "[dependencies]\ndep = { path = \"依\\u8d56\" }\n").toArray())
            File.writeTo(root.join("成员/cjpm.toml"),
                "[package]\nname = \"member_pkg\"\n".toArray())
            File.writeTo(root.join("依赖/cjpm.toml"),
                "[package]\nname = \"dep_pkg\"\n".toArray())
            File.writeTo(root.join("src/root.cj"),
                "package unicode_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("成员/src/member.cj"),
                "package member_pkg\npublic func memberApi(): Unit {}\n".toArray())
            File.writeTo(root.join("依赖/src/dep.cj"),
                "package dep_pkg\npublic func depApi(): Unit {}\n".toArray())

            let generated = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", includePathDependencies: true,
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(generated.status, "complete")
            @Expect(generated.modules.size, 3)
            @Expect(declarationNamed(generated, "memberApi").packageName, "member_pkg")
            @Expect(declarationNamed(generated, "depApi").packageName, "dep_pkg")

            let invalidRoot = temporary.join("invalid")
            Directory.create(invalidRoot.join("src"), recursive: true)
            File.writeTo(invalidRoot.join("cjpm.toml"),
                "[package]\nname = \"bad\\q\"\n".toArray())
            File.writeTo(invalidRoot.join("src/api.cj"),
                "package invalid\npublic func mustNotParse(): Unit {}\n".toArray())
            let invalid = DocumentationEngine().generate(GenerationRequest(
                invalidRoot.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(invalid.status, "partial")
            @Expect(invalid.modules.size, 1)
            @Expect(invalid.declarations.size, 0)
            @Expect(diagnosticCount(invalid, "CJDOC1010"), 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func auxiliaryBudgetFailsClosedOnceAcrossMetadataAndCacheWork(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("bounded-auxiliary")
            let cache = temporary.join("cache")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(cache)
            let manifest = "[package]\nname = \"bounded_auxiliary\"\n"
            File.writeTo(root.join("cjpm.toml"), manifest.toArray())
            File.writeTo(root.join("src/api.cj"),
                "package bounded_auxiliary\npublic func api(): Unit {}\n".toArray())

            let metadataLimited = AstSourceProvider(astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceAuxiliaryByteLimit: manifest.size - 1).collect(root.toString())
            @Expect(metadataLimited.modules.size, 1)
            @Expect(metadataLimited.declarations.size, 0)
            var metadataLimits: Int64 = 0
            for (diagnostic in metadataLimited.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { metadataLimits++ }
            }
            @Expect(metadataLimits, 1)

            let workLimited = AstSourceProvider(astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceAuxiliaryWorkLimit: manifest.size).collect(root.toString())
            @Expect(workLimited.modules.size, 1)
            @Expect(workLimited.declarations.size, 0)
            var workLimits: Int64 = 0
            for (diagnostic in workLimited.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { workLimits++ }
            }
            @Expect(workLimits, 1)

            let cacheLimited = AstSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("bounded-cache-work-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceAuxiliaryByteLimit: manifest.size + 1).collect(root.toString())
            @Expect(cacheLimited.declarations.size, 1)
            var cacheLimits: Int64 = 0
            for (diagnostic in cacheLimited.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { cacheLimits++ }
            }
            @Expect(cacheLimits, 1)
            @Expect(Directory.readFrom(cache).size, 0)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }


}
