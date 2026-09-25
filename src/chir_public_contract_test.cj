package cjdoc

import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
@Test
class ChirPublicContracts {
    @TestCase
    func chirOptionsCopyInputsAndRejectInvalidValues(): Unit {
        let paths = ["existing-import-root"]
        let options = ChirOptions(compilerExecutable: "cjc", importPaths: paths)
        paths[0] = "mutated-after-construction"
        @Expect(options.compilerExecutable, "cjc")
        @Expect(options.importPaths[0], "existing-import-root")
        @ExpectThrows[IllegalArgumentException](ChirOptions(compilerExecutable: " "))
        @ExpectThrows[IllegalArgumentException](ChirOptions(importPaths: [""]))
    }

    @TestCase
    func explicitChirCompilesStructuredSourceAndKeepsCurrentDocIr(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.3.0"
                name = "chir_contract"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(temporary.join("src/api.cj"),
                """
                package chir_contract

                public class Box {
                    public init() {}
                    public func value(): Int64 { 1 }
                }

                public enum State {
                    | Ready
                    | Failed(String)
                }

                extend Box {
                    public func extra(): Int64 { 2 }
                }

                public type Alias = Int64
                """.toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    chir: Some(ChirOptions())))
            @Expect(documentation.schemaVersion, "cjdoc.doc-ir/10")
            @Expect(documentation.providers[0].name, "chir")
            @Expect(documentation.declarations.size > 0, true)
            var compilerUnavailable = ""
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code == "CJDOC2101") {
                    compilerUnavailable = diagnostic.message
                }
            }
            @Expect(compilerUnavailable, "")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func chirSemanticFixtureUsesStructuredPackageRecords(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest("tests/fixtures/projects/chir_semantics", lintProfile: "off",
                chir: Some(ChirOptions())))
        @Expect(documentation.providers[0].name, "chir")
        @Expect(documentation.declarations.size > 0, true)
        var compilerUnavailable = ""
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC2101") {
                compilerUnavailable = diagnostic.message
            }
        }
        @Expect(compilerUnavailable, "")
        var sawState = false
        var sawExtra = false
        for (declaration in documentation.declarations) {
            if (declaration.name == "State") { sawState = true }
            if (declaration.name == "extra") { sawExtra = true }
        }
        @Expect(sawState, true)
        @Expect(sawExtra, true)
    }

    @TestCase
    func failedChirCompilationPreservesSourceDeclarations(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest("tests/fixtures/projects/basic", lintProfile: "off",
                chir: Some(ChirOptions(compilerExecutable: "missing-cjc-for-cjdoc-test"))))
        @Expect(documentation.declarations.size, 25)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2101"))
        @Expect(documentation.providers[0].name, "chir")
    }
}
