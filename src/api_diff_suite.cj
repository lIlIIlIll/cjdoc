package cjdoc

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

private func apiTestDeclaration(id: String, name: String, visibility!: String = "public",
    documentation!: String = ""): ApiContractDeclaration {
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", "function", name,
        "test." + name, visibility, "unavailable",
        documentationFingerprint: contractFingerprint(documentation),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}

private func apiTestSnapshot(declarations: Array<ApiContractDeclaration>): ApiContractSnapshot {
    ApiContractSnapshot("api-diff-test", "external", "default", declarations: declarations)
}

@Test
class ApiDiffSuite {
    @TestCase
    func unchangedDeclarationsProduceStableZeroExit(): Unit {
        let declaration = apiTestDeclaration("cjdoc:test:one", "one")
        let report = compareApiContracts(apiTestSnapshot([declaration]), apiTestSnapshot([declaration]))
        @Expect(report.summary.unchanged, 1)
        @Expect(report.summary.breaking, 0)
        @Expect(apiDiffExitCode(report, true, true), 0)
    }

    @TestCase
    func visibilityNarrowingIsBreakingAndDenied(): Unit {
        let baseline = apiTestSnapshot([apiTestDeclaration("cjdoc:test:one", "one")])
        let current = apiTestSnapshot([apiTestDeclaration("cjdoc:test:one", "one", visibility: "internal")])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.breaking, 1)
        @Expect(apiDiffExitCode(report, true, false), 1)
    }

    @TestCase
    func documentationChangeIsNonBreaking(): Unit {
        let baseline = apiTestSnapshot([apiTestDeclaration("cjdoc:test:one", "one", documentation: "old")])
        let current = apiTestSnapshot([apiTestDeclaration("cjdoc:test:one", "one", documentation: "new")])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.documentationOnly, 1)
        @Expect(report.summary.breaking, 0)
        @Expect(report.summary.potentiallyBreaking, 0)
        @Expect(apiDiffExitCode(report, true, true), 0)
    }

    @TestCase
    func ambiguousFallbackIsPotentiallyBreaking(): Unit {
        let baseline = apiTestSnapshot([apiTestDeclaration("cjdoc:test:old", "one")])
        let current = apiTestSnapshot([
            apiTestDeclaration("cjdoc:test:new-a", "one"),
            apiTestDeclaration("cjdoc:test:new-b", "one")])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.potentiallyBreaking > 0, true)
        @Expect(apiDiffExitCode(report, false, true), 1)
    }
}
