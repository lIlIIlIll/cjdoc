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
private func apiTestDeclarationWithSignature(id: String, name: String, signature: String): ApiContractDeclaration {
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", "function", name,
        "test." + name, "public", "resolved", sourceApiSignature: [signature],
        documentationFingerprint: contractFingerprint("doc"),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}
private func apiTestOverloadDeclaration(id: String, parameterType: String): ApiContractDeclaration {
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", "function", "call",
        "test.call", "public", "resolved", sourceApiSignature: ["public", "func", "call", parameterType],
        parameters: [ApiContractParameter("value", typeState: "resolved", `type`: Some(parameterType))],
        returnState: "resolved", returnType: Some("Unit"),
        documentationFingerprint: contractFingerprint("doc"),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}

private func apiTestRelationshipDeclaration(id: String, relationships: Array<String>): ApiContractDeclaration {
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", "class", "Widget",
        "test.Widget", "public", "resolved", sourceApiSignature: ["public", "class", "Widget"],
        relationships: relationships, documentationFingerprint: contractFingerprint("doc"),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}
private func apiTestGenericDeclaration(id: String, genericParameters: Array<String>): ApiContractDeclaration {
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", "class", "Box",
        "test.Box", "public", "resolved", sourceApiSignature: ["public", "class", "Box"],
        genericParameters: genericParameters, documentationFingerprint: contractFingerprint("doc"),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}

private func apiTestVisibilityDeclaration(id: String, visibility: String): ApiContractDeclaration {
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", "function", "visible",
        "test.visible", visibility, "resolved", sourceApiSignature: [visibility, "func", "visible"],
        documentationFingerprint: contractFingerprint("doc"),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}
private func apiTestOptionalParameterDeclaration(id: String, withOptionalParameter: Bool): ApiContractDeclaration {
    let parameters: Array<ApiContractParameter> = if (withOptionalParameter) {
        [ApiContractParameter("value", typeState: "resolved", `type`: Some("Int64"),
            defaultState: "resolved", defaultValue: Some("0"))]
    } else {
        []
    }
    let signature = if (withOptionalParameter) {
        ["public", "func", "optional", "value", "=", "0"]
    } else {
        ["public", "func", "optional"]
    }
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", "function", "optional",
        "test.optional", "public", "resolved", sourceApiSignature: signature,
        parameters: parameters, returnState: "resolved", returnType: Some("Unit"),
        documentationFingerprint: contractFingerprint("doc"),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
}
private func apiTestSnapshot(declarations: Array<ApiContractDeclaration>,
    exposures!: Array<ApiContractExposure> = []): ApiContractSnapshot {
    ApiContractSnapshot("api-diff-test", "external", "default", declarations: declarations,
        exposures: exposures)
}

private func apiTestExposure(id: String, exposedName: String, targetId: String): ApiContractExposure {
    ApiContractExposure(id, "cjdoc:module:v1:test", "test", exposedName, [targetId], state: "resolved")
}

private func apiTestEnumDeclaration(id: String, kind: String, name: String,
    ownerId!: ?String = None, enumNonExhaustive!: ?Bool = None): ApiContractDeclaration {
    ApiContractDeclaration(id, "cjdoc:module:v1:test", "test", kind, name,
        "test." + name, "public", "unavailable", ownerId: ownerId,
        enumNonExhaustive: enumNonExhaustive,
        documentationFingerprint: contractFingerprint("doc"),
        sourceFingerprint: contractFingerprint("source"),
        metadataFingerprint: contractFingerprint("metadata"))
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
    func overloadsUseSourceSignatureForFallbackMatching(): Unit {
        let baseline = apiTestSnapshot([
            apiTestDeclarationWithSignature("cjdoc:test:old-int", "overloaded", "Int64"),
            apiTestDeclarationWithSignature("cjdoc:test:old-string", "overloaded", "String")])
        let current = apiTestSnapshot([
            apiTestDeclarationWithSignature("cjdoc:test:new-int", "overloaded", "Int64"),
            apiTestDeclarationWithSignature("cjdoc:test:new-string", "overloaded", "String")])
        let report = compareApiContracts(baseline, current)
        var fallbackMatches: Int64 = 0
        for (entry in report.entries) {
            if (entry.matchState == "fallback") { fallbackMatches++ }
        }
        @Expect(fallbackMatches, 2)
        @Expect(report.summary.unchanged, 2)
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
    @TestCase
    func overloadFallbackIgnoresMatchedCandidates(): Unit {
        let baseline = apiTestSnapshot([
            apiTestOverloadDeclaration("call-int", "Int64"),
            apiTestOverloadDeclaration("call-string", "String")])
        let current = apiTestSnapshot([
            apiTestOverloadDeclaration("call-int", "Int64"),
            apiTestOverloadDeclaration("call-bool", "Bool")])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.breaking, 1)
        @Expect(report.summary.potentiallyBreaking, 0)
        @Expect(apiDiffExitCode(report, true, false), 1)
    }

    @TestCase
    func resolvedRelationshipReplacementIsBreaking(): Unit {
        let baseline = apiTestSnapshot([
            apiTestRelationshipDeclaration("widget", ["extends:OldBase"])])
        let current = apiTestSnapshot([
            apiTestRelationshipDeclaration("widget", ["extends:NewBase"])])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.breaking, 1)
        @Expect(apiDiffExitCode(report, true, false), 1)
    }

    @TestCase
    func resolvedGenericArityRemovalIsBreaking(): Unit {
        let baseline = apiTestSnapshot([apiTestGenericDeclaration("box", ["T"])])
        let current = apiTestSnapshot([apiTestGenericDeclaration("box", [])])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.breaking, 1)
        @Expect(apiDiffExitCode(report, true, false), 1)
    }

    @TestCase
    func visibilityWideningIsNotPotentiallyBreaking(): Unit {
        let baseline = apiTestSnapshot([apiTestVisibilityDeclaration("visible", "protected")])
        let current = apiTestSnapshot([apiTestVisibilityDeclaration("visible", "public")])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.breaking, 0)
        @Expect(report.summary.potentiallyBreaking, 0)
        @Expect(apiDiffExitCode(report, true, true), 0)
    }

    @TestCase
    func newEnumAndCasesAreAdditive(): Unit {
        let enumDeclaration = apiTestEnumDeclaration("enum", "enum", "Choice", enumNonExhaustive: Some(false))
        let caseDeclaration = apiTestEnumDeclaration("case", "enumCase", "Ready", ownerId: Some("enum"))
        let report = compareApiContracts(apiTestSnapshot([]),
            apiTestSnapshot([enumDeclaration, caseDeclaration]))
        @Expect(report.summary.additive, 2)
        @Expect(report.summary.potentiallyBreaking, 0)
        @Expect(apiDiffExitCode(report, true, true), 0)
    }

    @TestCase
    func resolvedDefaultedParameterAdditionIsAdditive(): Unit {
        let baseline = apiTestSnapshot([apiTestOptionalParameterDeclaration("optional", false)])
        let current = apiTestSnapshot([apiTestOptionalParameterDeclaration("optional", true)])
        let report = compareApiContracts(baseline, current)
        @Expect(report.summary.breaking, 0)
        @Expect(report.summary.potentiallyBreaking, 0)
        @Expect(report.summary.additive, 1)
        @Expect(apiDiffExitCode(report, true, true), 0)
    }

    @TestCase
    func exposureRemovalAndRetargetAreReported(): Unit {
        let baselineExposure = apiTestExposure("exp", "PublicName", "target-old")
        let removed = compareApiContracts(
            apiTestSnapshot([], exposures: [baselineExposure]), apiTestSnapshot([]))
        @Expect(removed.summary.breaking, 1)
        @Expect(apiDiffExitCode(removed, true, false), 1)
        let retargeted = compareApiContracts(
            apiTestSnapshot([], exposures: [baselineExposure]),
            apiTestSnapshot([], exposures: [apiTestExposure("exp", "PublicName", "target-new")]))
        @Expect(retargeted.summary.breaking, 1)
        @Expect(retargeted.entries[0].kind, "exposure")
    }

    @TestCase
    func sharedReExportIdsMatchBindingNames(): Unit {
        let baseline = apiTestSnapshot([], exposures: [
            apiTestExposure("shared", "foo", "target-foo"),
            apiTestExposure("shared", "bar", "target-bar")])
        let report = compareApiContracts(baseline, baseline)
        @Expect(report.summary.unchanged, 2)
        @Expect(report.summary.breaking, 0)
    }
    @TestCase
    func overloadExposuresMatchByBindingIdentity(): Unit {
        let baseline = apiTestSnapshot([], exposures: [
            apiTestExposure("overload-a", "call", "target-a"),
            apiTestExposure("overload-b", "call", "target-b")])
        let report = compareApiContracts(baseline, baseline)
        @Expect(report.summary.unchanged, 2)
        @Expect(report.summary.potentiallyBreaking, 0)
        @Expect(report.entries[0].matchState, "exact")
        @Expect(report.entries[1].matchState, "exact")
    }

    @TestCase
    func renamedExposureUsesUniquePackageFallback(): Unit {
        let report = compareApiContracts(
            apiTestSnapshot([], exposures: [apiTestExposure("old", "OldName", "target")]),
            apiTestSnapshot([], exposures: [apiTestExposure("new", "NewName", "target")]))
        @Expect(report.summary.breaking, 1)
        @Expect(report.entries[0].matchState, "fallback")
    }

    @TestCase
    func exhaustiveEnumCaseAdditionIsBreaking(): Unit {
        let owner = apiTestEnumDeclaration("enum", "enum", "Choice", enumNonExhaustive: Some(false))
        let addedCase = apiTestEnumDeclaration("case", "enumCase", "NewCase", ownerId: Some("enum"))
        let report = compareApiContracts(apiTestSnapshot([owner]), apiTestSnapshot([owner, addedCase]))
        @Expect(report.summary.breaking, 1)
        @Expect(apiDiffExitCode(report, true, false), 1)
    }

    @TestCase
    func unknownLegacyFingerprintsDoNotCreateFalseChanges(): Unit {
        let legacy = ApiContractDeclaration("cjdoc:test:one", "cjdoc:module:v1:test", "test",
            "function", "one", "test.one", "public", "unavailable")
        let current = apiTestDeclaration("cjdoc:test:one", "one", documentation: "new docs")
        let report = compareApiContracts(apiTestSnapshot([legacy]), apiTestSnapshot([current]))
        @Expect(report.summary.unchanged, 1)
        @Expect(report.summary.documentationOnly, 0)
        @Expect(report.summary.metadataOnly, 0)
    }

}
