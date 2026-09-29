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
        let dependencyRoot = temporary.join("deps").join("chir_dependency")
        try {
            Directory.create(temporary.join("src"), recursive: true)
            Directory.create(dependencyRoot.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.3.0"
                name = "chir_contract"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                chir_dependency = { path = "deps/chir_dependency", output-type = "static" }
                """.toArray())
            File.writeTo(dependencyRoot.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.3.0"
                name = "chir_dependency"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(temporary.join("src/api.cj"),
                """
                package chir_contract

                import chir_dependency as dep

                public enum State {
                    | Ready
                    | Failed(String)
                }

                extend dep.Box {
                    public func extra(): Int64 { 2 }
                }

                public type Alias = Int64
                """.toArray())
            File.writeTo(dependencyRoot.join("src/api.cj"),
                """
                package chir_dependency

                public class Box {
                    public init() {}
                }
                """.toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    includePathDependencies: true, chir: Some(ChirOptions()),
                    astPreflightExecutable: Some("target/release/bin/main")))
            @Expect(documentation.schemaVersion, "cjdoc.doc-ir/11")
            @Expect(documentation.providers[0].name, "chir")
            @Expect(documentation.declarations.size > 0, true)
            var compilerFailure = ""
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code == "CJDOC2101" ||
                    diagnostic.code == "CJDOC2102" ||
                    diagnostic.code == "CJDOC2103" ||
                    diagnostic.code == "CJDOC2104") {
                    compilerFailure = diagnostic.message
                }
            }
            @Expect(compilerFailure, "")
            var extensionState = "missing"
            for (declaration in documentation.declarations) {
                if (declaration.kind == "extend") {
                    extensionState = declaration.semantic.state
                }
            }
            @Expect(extensionState, "partial")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func chirSemanticFixtureUsesStructuredPackageRecords(): Unit {
        let documentation = DocumentationEngine().generate(
        GenerationRequest("tests/fixtures/projects/chir_semantics", lintProfile: "off",
                chir: Some(ChirOptions()),
                astPreflightExecutable: Some("target/release/bin/main")))
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
    func chirDoesNotMixSameLogicalPathsAcrossModules(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        let dependencyRoot = temporary.join("deps").join("foreign")
        try {
            Directory.create(temporary.join("src"), recursive: true)
            Directory.create(dependencyRoot.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.3.0"
                name = "collision"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                foreign = { path = "deps/foreign", output-type = "static" }
                """.toArray())
            File.writeTo(dependencyRoot.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.3.0"
                name = "collision"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(temporary.join("src").join("api.cj"),
                """
                package collision

                public class Duplicate {
                    public init() {}
                }

                public func rootApi(): Int64 { 1 }
                """.toArray())
            File.writeTo(dependencyRoot.join("src").join("api.cj"),
                """
                package collision

                import decoy

                public class Duplicate {
                    public init() {}
                }

                public func foreignApi(): Int64 { 2 }
                """.toArray())
            File.writeTo(dependencyRoot.join("src").join("decoy.cj"),
                """
                package decoy

                public func unavailableApi(): MissingType { 1 }
                """.toArray())

            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    includePathDependencies: true, chir: Some(ChirOptions()),
                    astPreflightExecutable: Some("target/release/bin/main")))
            var rootApiState = "missing"
            for (declaration in documentation.declarations) {
                if (declaration.name == "rootApi" && declaration.packageName == "collision") {
                    rootApiState = declaration.semantic.state
                }
            }
            @Expect(rootApiState, "partial")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func failedChirCompilationPreservesSourceDeclarations(): Unit {
        let documentation = DocumentationEngine().generate(
        GenerationRequest("tests/fixtures/projects/basic", lintProfile: "off",
                chir: Some(ChirOptions(compilerExecutable: "missing-cjc-for-cjdoc-test")),
                astPreflightExecutable: Some("target/release/bin/main")))
        @Expect(documentation.declarations.size, 25)
        var compilerFailureCode = ""
        var compilerFailureMessage = ""
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code.startsWith("CJDOC21")) {
                compilerFailureCode = diagnostic.code
                compilerFailureMessage = diagnostic.message
            }
        }
        @Expect(compilerFailureCode, "CJDOC2101")
        if (compilerFailureCode != "CJDOC2101") {
            @Expect(compilerFailureMessage, "")
        }
        @Expect(documentation.providers[0].name, "chir")
    }
}
