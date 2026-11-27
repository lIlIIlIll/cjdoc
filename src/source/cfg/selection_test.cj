protected package cjdoc.source.cfg

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func profileOf(values: Array<(String, String)>): CfgProfile {
    CfgProfile(values: Array<CfgAssignment>(values.size, { index =>
        let (name, value) = values[index]
        CfgAssignment(name, value)
    }))
}

private func diagnosis(annotations: Array<String>,
    values!: Array<(String, String)> = []): CfgSelectionDiagnosis {
    diagnoseCfgSelection(ArrayList<String>(annotations), profileOf(values))
}

@Test
class CfgSelectionDiagnosisTest {
    @TestCase
    func missingBuiltinConditionNamesTheSelectableValues(): Unit {
        let os = diagnosis(["@When[os == \"Linux\"]"])
        @Expect(os.selected, None<Bool>)
        @Expect(os.reason.contains("no os condition value was provided"), true)
        @Expect(os.reason.contains("available values: Linux, Windows, macOS, iOS"), true)
        @Expect(os.reason.contains("--cfg os=<value>"), true)
        let arch = diagnosis(["@When[arch == \"aarch64\"]"])
        @Expect(arch.reason.contains("available values: x86_64, aarch64, arm"), true)
        let debug = diagnosis(["@When[debug]"])
        @Expect(debug.reason.contains("no debug condition value was provided"), true)
    }

    @TestCase
    func undefinedConditionIsDistinctFromAnUnsetBuiltin(): Unit {
        let feature = diagnosis(["@When[feature == \"extra\"]"])
        @Expect(feature.selected, None<Bool>)
        @Expect(feature.reason.contains("undefined condition 'feature'"), true)
        @Expect(feature.reason.contains("available values"), false)
        let malformed = diagnosis(["@When[os == ]"])
        @Expect(malformed.reason.contains("unsupported or malformed"), true)
        @Expect(malformed.reason.contains("undefined condition"), false)
    }

    @TestCase
    func providedValuesProveSelectionAndFalseDominatesUnknown(): Unit {
        let selected = diagnosis(["@When[os == \"Linux\"]"], values: [("os", "Linux")])
        @Expect(selected.selected, Some(true))
        @Expect(selected.reason, "")
        let excluded = diagnosis(["@When[os != \"Linux\"]"], values: [("os", "Linux")])
        @Expect(excluded.selected, Some(false))
        @Expect(excluded.reason, "")
        let falseThenUnknown = diagnosis(["@When[docs && missing]"], values: [("docs", "false")])
        @Expect(falseThenUnknown.selected, Some(false))
        @Expect(falseThenUnknown.reason, "")
    }

    @TestCase
    func builtinValuesFollowTheCompilerTargetNotUserChoice(): Unit {
        for (name in ["os", "arch", "debug"]) {
            let actual = compilerBuiltinCfgAssignment(name).getOrThrow()
            @Expect(validateCompilerBuiltinCfg(CfgAssignment(name, actual)), true)
            var other = ""
            for (choice in compilerBuiltinCfgChoices(name).getOrThrow()) {
                if (choice != actual) { other = choice; break }
            }
            @Expect(other.isEmpty(), false)
            var message = ""
            try {
                let _ = validateCompilerBuiltinCfg(CfgAssignment(name, other))
            } catch (error: IllegalArgumentException) {
                message = error.message
            }
            @Expect(message.contains("does not match compiler target"), true)
            @Expect(message.contains("${name}=${other}"), true)
            @Expect(message.contains("${name}=${actual}"), true)
        }
    }
}
