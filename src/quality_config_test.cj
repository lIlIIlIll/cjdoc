package cjdoc

import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class QualityConfigTest {
    @TestCase
    func repeatedDocumentationPagesDoNotBecomeQualitySettings(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            File.writeTo(root.join("cjdoc.toml"), """
                [docs]
                index = "docs/index.md"
                [[docs.pages]]
                source = "docs/first.md"
                route = "concepts/first"
                [[docs.pages]]
                source = "docs/second.md"
                route = "concepts/second"
                [external-docs.first]
                index = "docs/first.json"
                [external-docs.second]
                index = "docs/second.json"
                [lint]
                severity = "error"
                [coverage]
                symbols = 80
                """.toArray())
            let config = loadDocumentationQualityConfig(root.toString())
            @Expect(config.defaultSeverity, "error")
            @Expect(config.coverage.symbols, Some(80))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func duplicateOwnedSettingsRemainErrors(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            for (table in ["lint", "coverage", "coverage.package.fixture"]) {
                let setting = if (table == "lint") { "severity = \"warning\"" } else { "symbols = 80" }
                File.writeTo(root.join("cjdoc.toml"),
                    ("[" + table + "]\n" + setting + "\n" + setting + "\n").toArray())
                @ExpectThrows[IllegalArgumentException](loadDocumentationQualityConfig(root.toString()))
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
