package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.env.*
import std.fs.*
import std.io.*
import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

private func createExampleProject(source: String): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src"), recursive: true)
    File.writeTo(root.join("cjpm.toml"),
        """
        [package]
        cjc-version = "1.1.0"
        name = "example_compile"
        version = "0.1.0"
        output-type = "static"
        """.toArray())
    File.writeTo(root.join("src/api.cj"), source.toArray())
    root
}

private func createExampleProjectWithPathDependencies(): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src"), recursive: true)
    Directory.create(root.join("deps/alpha/src"), recursive: true)
    Directory.create(root.join("deps/beta/src"), recursive: true)
    File.writeTo(root.join("cjpm.toml"),
        """
        [package]
        cjc-version = "1.1.0"
        name = "example_compile"
        version = "0.1.0"
        output-type = "static"

        [dependencies]
        path_dep_alpha = { path = "deps/alpha", output-type = "static" }
        """.toArray())
    File.writeTo(root.join("src/api.cj"),
        """
        package example_compile

        import path_dep_alpha.*

        /**
         * Calls an imported package.
         * @example Transitive local package
         * ```cangjie
         * let result = alphaApi()
         * ```
         */
        public func rootApi(): Unit { () }
        """.toArray())
    File.writeTo(root.join("deps/alpha/cjpm.toml"),
        """
        [package]
        cjc-version = "1.1.0"
        name = "path_dep_alpha"
        version = "0.1.0"
        output-type = "static"

        [dependencies]
        path_dep_beta = { path = "../beta", output-type = "static" }
        """.toArray())
    File.writeTo(root.join("deps/alpha/src/alpha.cj"),
        """
        package path_dep_alpha

        import path_dep_beta.*

        public func alphaApi(): Int64 { betaApi() }
        """.toArray())
    File.writeTo(root.join("deps/beta/cjpm.toml"),
        """
        [package]
        cjc-version = "1.1.0"
        name = "path_dep_beta"
        version = "0.1.0"
        output-type = "static"
        """.toArray())
    File.writeTo(root.join("deps/beta/src/beta.cj"),
        """
        package path_dep_beta

        public func betaApi(): Int64 { 42 }
        """.toArray())
    root
}

private func exampleRequest(root: Path, checkExamples: Bool): GenerationRequest {
    GenerationRequest(root.toString(), lintProfile: "off", audience: "all",
        checkExamples: checkExamples, astPreflightExecutable: Some("target/release/bin/main"))
}

private func cachedExampleRequest(root: Path, cache: String): GenerationRequest {
    GenerationRequest(root.toString(), lintProfile: "off", audience: "all",
        checkExamples: true, cacheDirectory: Some(cache),
        astPreflightExecutable: Some("target/release/bin/main"))
}

private func hasExampleDiagnostic(documentation: public_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

private func hasExampleDiagnosticAbout(documentation: public_model.DocumentationSet,
    code: String, label: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code && diagnostic.message.contains(label)) { return true }
    }
    false
}

private func exampleDiagnosticSummary(documentation: public_model.DocumentationSet): Array<String> {
    let summary = ArrayList<String>()
    for (diagnostic in documentation.diagnostics) {
        summary.add("${diagnostic.severity}[${diagnostic.code}]${diagnostic.message}")
    }
    summary.toArray()
}

// A `cjc` static link may be unavailable on a host, in which case a run-mode example
// legitimately degrades to CJDOC3074. Run assertions therefore tolerate that single
// code and nothing else; the pre-spawn assertions stay unconditional.
private func runOutcomeAccepted(documentation: public_model.DocumentationSet,
    expected: String): Bool {
    hasExampleDiagnostic(documentation, expected) || hasExampleDiagnostic(documentation, "CJDOC3074")
}

private func noRunOutcome(documentation: public_model.DocumentationSet): Bool {
    !hasExampleDiagnostic(documentation, "CJDOC3030") &&
        !hasExampleDiagnostic(documentation, "CJDOC3070") &&
        !hasExampleDiagnostic(documentation, "CJDOC3071") &&
        !hasExampleDiagnostic(documentation, "CJDOC3072") &&
        !hasExampleDiagnostic(documentation, "CJDOC3073") &&
        !hasExampleDiagnostic(documentation, "CJDOC3075")
}

private let arithmeticSource = """
    package example_compile

    import std.env.*

    public func add(left: Int64, right: Int64): Int64 { left + right }

    public func at(values: Array<Int64>, index: Int64): Int64 { values[index] }
    """

private func sourceWith(body: String): String {
    "${arithmeticSource}\n/**\n * Adds two values.\n *\n${body}\n * @param left left operand.\n */\npublic func probe(): Unit { () }\n"
}

@Test
class ExampleCompilerTest {
    @TestCase
    func validCangjieExampleCompilesWithoutChangingDefaultBehavior(): Unit {
        let root = createExampleProject(
            """
            package example_compile

            /**
             * Adds two values.
             * @example Basic addition
             * ```cangjie
             * let result = add(1, 2)
             * ```
             */
            public func add(left: Int64, right: Int64): Int64 { left + right }
            """)
        try {
            let withoutCheck = DocumentationEngine().generate(exampleRequest(root, false))
            @Expect(!hasExampleDiagnostic(withoutCheck, "CJDOC3030"))
            let withCheck = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(!hasExampleDiagnostic(withCheck, "CJDOC3030"))
            @Expect(!hasExampleDiagnostic(withCheck, "CJDOC3031"))
            @Expect(!hasExampleDiagnostic(withCheck, "CJDOC3032"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func invalidCangjieExampleReportsCompilerDiagnostic(): Unit {
        let root = createExampleProject(
            """
            package example_compile

            /**
             * Adds two values.
             * @example Invalid call
             * ```cangjie
             * let result = missingApi(1, 2)
             * ```
             */
            public func add(left: Int64, right: Int64): Int64 { left + right }
            """)
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnostic(documentation, "CJDOC3030"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func nonCangjieExampleProducesAnActionableWarning(): Unit {
        let root = createExampleProject(
            """
            package example_compile

            /**
             * A text-only example.
             * @example Output
             * ```text
             * result: 3
             * ```
             */
            public func add(left: Int64, right: Int64): Int64 { left + right }
            """)
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnostic(documentation, "CJDOC3032"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func pinnedFailureSatisfiesTheExpectation(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Missing call {must-fail}
             * ```cangjie
             * let result = missingApi(1, 2)
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(noRunOutcome(documentation))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3031"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func pinnedFailureRejectsAnExampleThatCompiles(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Compiling call {must-fail}
             * ```cangjie
             * let result = add(1, 2)
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3070",
                "is pinned to fail but compiled successfully"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func pinnedFailureMessageIsComparedAgainstTheCompilerOutput(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Named failure {must-fail error="missingApi"}
             * ```cangjie
             * let result = missingApi(1, 2)
             * ```
             *
             * @example Other failure {must-fail error="missingApi"}
             * ```cangjie
             * let result = add(1, "two")
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3070", "Other failure"))
            @Expect(!hasExampleDiagnosticAbout(documentation, "CJDOC3070", "Named failure"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func pinnedFailureIsNotCreditedWhenThePackageFails(): Unit {
        let root = createExampleProject(
            """
            package example_compile

            /**
             * Adds two values.
             * @example Unaffected {must-fail}
             * ```cangjie
             * let result = 1
             * ```
             */
            public func add(left: Int64, right: Int64): Int64 { "not a number" }
            """)
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnostic(documentation, "CJDOC3031"))
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3070",
                "did not fail inside the example"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func invalidDirectivesStopBeforeAnyCompilation(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Nonsense {bogus}
             * ```cangjie
             * let result = add(1, 2)
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3033", "unknown directive"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3030"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3031"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3070"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3074"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func rejectedCompilerOptionIsNotAnExampleFailure(): Unit {
        // `cjc` itself rejects a built-in `--cfg` key with a driver error that names no
        // source file, so the gate must report a context failure rather than blame the
        // documentation or credit a `must-fail` pin.
        let root = createExampleProject(sourceWith(
            """
             * @example Builtin key {flags="--cfg os=Linux"}
             * ```cangjie
             * let result = add(1, 2)
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnostic(documentation, "CJDOC3031"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3030"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func acceptedCompilerOptionReachesCjc(): Unit {
        let body = """
             * @example Wrapping {run flags="--int-overflow wrapping"}
             * ```cangjie
             * println(at([1, 2], 0) + 9223372036854775807)
             * ```
             * ```output
             * -9223372036854775808
             * ```
            """
        let root = createExampleProject(sourceWith(body))
        let withoutFlag = createExampleProject(sourceWith(
            body.replace("flags=\"--int-overflow wrapping\"", "")))
        try {
            let pinned = DocumentationEngine().generate(exampleRequest(root, true))
            let unpinned = DocumentationEngine().generate(exampleRequest(withoutFlag, true))
            @Expect(noRunOutcome(pinned) || hasExampleDiagnostic(pinned, "CJDOC3074"), true)
            @Expect(runOutcomeAccepted(unpinned, "CJDOC3071"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
            let _ = removeIfExists(withoutFlag, recursive: true)
        }
    }

    @TestCase
    func runExamplePinsItsStandardOutput(): Unit {
        let matching = createExampleProject(sourceWith(
            """
             * @example Prints {run}
             * ```cangjie
             * println(add(1, 2))
             * ```
             * ```output
             * 3
             * ```
            """))
        let differing = createExampleProject(sourceWith(
            """
             * @example Prints {run}
             * ```cangjie
             * println(add(1, 2))
             * ```
             * ```output
             * result: 4
             * ```
            """))
        try {
            let pinned = DocumentationEngine().generate(exampleRequest(matching, true))
            @Expect(noRunOutcome(pinned) || hasExampleDiagnostic(pinned, "CJDOC3074"), true)
            let mismatched = DocumentationEngine().generate(exampleRequest(differing, true))
            @Expect(runOutcomeAccepted(mismatched, "CJDOC3072"), true)
        } finally {
            let _ = removeIfExists(matching, recursive: true)
            let _ = removeIfExists(differing, recursive: true)
        }
    }

    @TestCase
    func existingMainKeywordIsReusedForRunExamples(): Unit {
        let root = createExampleProject(
            """
            package example_compile

            /**
             * Runs a documented example with the existing entry point.
             * @example Existing entry point {run}
             * ```cangjie
             * println("example output")
             * ```
             */
            public func sample(): Unit { () }

            main(): Unit {
                println("original main")
            }
            """)
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3030"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3031"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func runtimeFailureReportsCapturedEvidence(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Exits {run}
             * ```cangjie
             * exit(3)
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3071", "exit code 3") ||
                hasExampleDiagnostic(documentation, "CJDOC3074"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func timedOutExampleTerminatesDescendantProcesses(): Unit {
        let source = """
            package example_compile

            import std.process.*

            /**
             * Spawns a child that keeps inherited output pipes open.
             * @example Descendant timeout {run}
             * ```cangjie
             * let descendant = try {
             *     launch("sleep", ["30"],
             *         stdIn: ProcessRedirect.Discard,
             *         stdOut: ProcessRedirect.Inherit,
             *         stdErr: ProcessRedirect.Inherit)
             * } catch (_: Exception) {
             *     launch("cmd.exe", ["/c", "ping", "-n", "31", "127.0.0.1"],
             *         stdIn: ProcessRedirect.Discard,
             *         stdOut: ProcessRedirect.Inherit,
             *         stdErr: ProcessRedirect.Inherit)
             * }
             * let _ = descendant.pid
             * ```
             */
            public func exampleEntry(): Unit { () }
            """
        let root = createExampleProject(source)
        let start = MonoTime.now()
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            let elapsed = (MonoTime.now() - start).toMilliseconds()
            let timedOut = hasExampleDiagnostic(documentation, "CJDOC3073")
            if (!timedOut) {
                for (diagnostic in documentation.diagnostics) {
                    println("${diagnostic.severity}[${diagnostic.code}] ${diagnostic.message}")
                }
            }
            @Expect(timedOut, true)
            @Expect(elapsed < 25000, true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func uncaughtPanicIsReportedAsARuntimeFailure(): Unit {
        // Only the code is asserted: the exception rendering, and the absolute temporary
        // paths it embeds, are platform-shaped. `<temporary>` normalisation is covered by
        // the determinism case below.
        let root = createExampleProject(sourceWith(
            """
             * @example Out of range {run}
             * ```cangjie
             * println(at([1, 2], 5))
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(runOutcomeAccepted(documentation, "CJDOC3071"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func pinnedOutputRequiresTheRunDirective(): Unit {
        // Both are pre-spawn checks, so they hold on every host.
        let unrun = createExampleProject(sourceWith(
            """
             * @example Output only
             * ```cangjie
             * let result = add(1, 2)
             * ```
             * ```output
             * result: 3
             * ```
            """))
        let doubled = createExampleProject(sourceWith(
            """
             * @example Twice {run}
             * ```cangjie
             * println("a")
             * ```
             * ```output
             * a
             * ```
             * ```output
             * b
             * ```
            """))
        try {
            let withoutRun = DocumentationEngine().generate(exampleRequest(unrun, true))
            @Expect(hasExampleDiagnosticAbout(withoutRun, "CJDOC3033", "pins output without run"))
            let twoBlocks = DocumentationEngine().generate(exampleRequest(doubled, true))
            @Expect(hasExampleDiagnosticAbout(twoBlocks, "CJDOC3033", "more than one output block"))
        } finally {
            let _ = removeIfExists(unrun, recursive: true)
            let _ = removeIfExists(doubled, recursive: true)
        }
    }

    @TestCase
    func pinnedExampleWithoutCodeIsReportedAsUnchecked(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Prose only {must-fail}
             * ```text
             * not code
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, true))
            @Expect(hasExampleDiagnostic(documentation, "CJDOC3032"))
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3070", "was not checked"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func directivesAreInertWithoutTheExampleGate(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Nonsense {bogus}
             * ```cangjie
             * let result = missingApi(1, 2)
             * ```
            """))
        try {
            let documentation = DocumentationEngine().generate(exampleRequest(root, false))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3030"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3033"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3070"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func importedPackageExamplesCompileAcrossColdAndWarmCaches(): Unit {
        let root = createExampleProjectWithPathDependencies()
        let cache = Directory.createTemp(getTempDirectory())
        let request = GenerationRequest(root.toString(), lintProfile: "off", audience: "all",
            checkExamples: true, includePathDependencies: true,
            cacheDirectory: Some(cache.toString()),
            astPreflightExecutable: Some("target/release/bin/main"))
        try {
            let cold = DocumentationEngine().generate(request)
            @Expect(!hasExampleDiagnostic(cold, "CJDOC3030"))
            @Expect(!hasExampleDiagnostic(cold, "CJDOC3031"))
            let warm = DocumentationEngine().generate(request)
            @Expect(!hasExampleDiagnostic(warm, "CJDOC3030"))
            @Expect(!hasExampleDiagnostic(warm, "CJDOC3031"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
            let _ = removeIfExists(cache, recursive: true)
        }
    }

    @TestCase
    func pinnedDiagnosticsAreDeterministicAcrossRuns(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Other failure {must-fail error="missingApi"}
             * ```cangjie
             * let result = add(1, "two")
             * ```
             *
             * @example Prints {run}
             * ```cangjie
             * println(at([1, 2], 5))
             * ```
            """))
        try {
            let first = exampleDiagnosticSummary(DocumentationEngine().generate(exampleRequest(root, true)))
            let second = exampleDiagnosticSummary(DocumentationEngine().generate(exampleRequest(root, true)))
            @Expect(first, second)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func warmSourceCacheKeepsPinnedExpectations(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Compiling call {must-fail}
             * ```cangjie
             * let result = add(1, 2)
             * ```
            """))
        let cache = Directory.createTemp(getTempDirectory())
        try {
            let cold = DocumentationEngine().generate(cachedExampleRequest(root, cache.toString()))
            @Expect(hasExampleDiagnostic(cold, "CJDOC3070"))
            let warm = DocumentationEngine().generate(cachedExampleRequest(root, cache.toString()))
            @Expect(hasExampleDiagnostic(warm, "CJDOC3070"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
            let _ = removeIfExists(cache, recursive: true)
        }
    }

    @TestCase
    func directiveManagedExamplesDoNotEnterLegacyDoctest(): Unit {
        let root = createExampleProject(sourceWith(
            """
             * @example Expected failure {must-fail}
             * ```cangjie
             * let invalid: Int64 = "wrong"
             * ```
            """))
        try {
            let generated = generateDocumentationWithSource(
                exampleRequest(root, false), defaultSemanticProvider())
            let report = runDoctests(generated.publicDocumentation,
                DoctestConfig(mode: "warn"), root.join("legacy-doctest"),
                projectRoot: root,
                sourceOrigins: generated.internalDocumentation.sourceFileOrigins.toArray())
            @Expect(report.results.size, 0)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
