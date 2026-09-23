package cjdoc

import cjdoc.model as public_model
import std.collection.*
import std.env.*
import std.fs.*
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
// legitimately degrades to CJDOC3038. Run assertions therefore tolerate that single
// code and nothing else; the pre-spawn assertions stay unconditional.
private func runOutcomeAccepted(documentation: public_model.DocumentationSet,
    expected: String): Bool {
    hasExampleDiagnostic(documentation, expected) || hasExampleDiagnostic(documentation, "CJDOC3038")
}

private func noRunOutcome(documentation: public_model.DocumentationSet): Bool {
    !hasExampleDiagnostic(documentation, "CJDOC3030") &&
        !hasExampleDiagnostic(documentation, "CJDOC3034") &&
        !hasExampleDiagnostic(documentation, "CJDOC3035") &&
        !hasExampleDiagnostic(documentation, "CJDOC3036") &&
        !hasExampleDiagnostic(documentation, "CJDOC3037") &&
        !hasExampleDiagnostic(documentation, "CJDOC3039")
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
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3034",
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
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3034", "Other failure"))
            @Expect(!hasExampleDiagnosticAbout(documentation, "CJDOC3034", "Named failure"))
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
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3034",
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
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3034"))
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3038"))
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
            @Expect(noRunOutcome(pinned) || hasExampleDiagnostic(pinned, "CJDOC3038"), true)
            @Expect(runOutcomeAccepted(unpinned, "CJDOC3035"), true)
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
            @Expect(noRunOutcome(pinned) || hasExampleDiagnostic(pinned, "CJDOC3038"), true)
            let mismatched = DocumentationEngine().generate(exampleRequest(differing, true))
            @Expect(runOutcomeAccepted(mismatched, "CJDOC3036"), true)
        } finally {
            let _ = removeIfExists(matching, recursive: true)
            let _ = removeIfExists(differing, recursive: true)
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
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3035", "exit code 3") ||
                hasExampleDiagnostic(documentation, "CJDOC3038"), true)
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
            @Expect(runOutcomeAccepted(documentation, "CJDOC3035"), true)
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
            @Expect(hasExampleDiagnosticAbout(documentation, "CJDOC3034", "was not checked"))
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
            @Expect(!hasExampleDiagnostic(documentation, "CJDOC3034"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
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
            @Expect(hasExampleDiagnostic(cold, "CJDOC3034"))
            let warm = DocumentationEngine().generate(cachedExampleRequest(root, cache.toString()))
            @Expect(hasExampleDiagnostic(warm, "CJDOC3034"))
        } finally {
            let _ = removeIfExists(root, recursive: true)
            let _ = removeIfExists(cache, recursive: true)
        }
    }
}
