package cjdoc

import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Windows"]
import std.posix.*

@When[os != "Windows"]
@Test
class CachedDependencyContainmentTest {
    @TestCase
    func rejectsCachedDependencySymlinkThatEscapesCanonicalCacheRoot(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let cache = temporary.join("cache")
            let outside = temporary.join("outside-dependency")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(cache.join("git/escaped"), recursive: true)
            Directory.create(outside.join("src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"),
                "[package]\nname = \"cache_containment\"\n".toArray())
            File.writeTo(root.join("cjpm.lock"), """
                [requires]
                escaped = { git = "https://example.invalid/escaped.git", commitId = "abc123" }
                """.toArray())
            File.writeTo(root.join("src/root.cj"),
                "package cache_containment\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(outside.join("cjpm.toml"),
                "[package]\nname = \"escaped\"\n".toArray())
            File.writeTo(outside.join("src/api.cj"),
                "package escaped\npublic func escapedApi(): Unit {}\n".toArray())
            @Expect(symlink(outside.toString(),
                cache.join("git/escaped/abc123").toString()), 0)

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includeCachedDependencies: true, cjpmCacheRoot: Some(cache.toString()),
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            var escapedFound = false
            for (declaration in documentation.declarations) {
                if (declaration.name == "escapedApi") { escapedFound = true }
            }
            @Expect(escapedFound, false)
            @Expect(containsDiagnostic(documentation, "CJDOC1021"), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

}
