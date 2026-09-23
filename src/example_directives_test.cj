package cjdoc

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

private func joinedProblems(values: ArrayList<String>): String {
    let out = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { out.append("; ") }
        out.append(value)
        first = false
    }
    out.toString()
}

private func joinedValues(values: Array<String>): String {
    let out = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { out.append("; ") }
        out.append(value)
        first = false
    }
    out.toString()
}

private func joinedOptions(values: Array<String>): String {
    let out = StringBuilder()
    var first = true
    for (value in values) {
        if (!first) { out.append(" ") }
        out.append(value)
        first = false
    }
    out.toString()
}

private func directiveProblems(block: String): String {
    joinedProblems(parseExampleDirectives(block).problems)
}

private func flagProblems(flags: Array<String>): String {
    let (_, problems) = validateExampleFlags(flags)
    joinedValues(problems)
}

private func acceptedFlagText(flags: Array<String>): String {
    let (accepted, problems) = validateExampleFlags(flags)
    @Expect(joinedValues(problems), "")
    joinedOptions(accepted)
}

@Test
class ExampleDirectivesTest {
    @TestCase
    func pinnedExpectationsAndOptionsAreAccepted(): Unit {
        let passing = parseExampleDirectives("{must-pass}")
        @Expect(joinedProblems(passing.problems), "")
        @Expect(!passing.expectsFailure && !passing.execute, true)

        let failing = parseExampleDirectives("{must-fail error=\"unresolved identifier\"}")
        @Expect(joinedProblems(failing.problems), "")
        @Expect(failing.expectsFailure, true)
        match (failing.failureContains) {
            case Some(message) => @Expect(message, "unresolved identifier")
            case None => @Expect(false, true)
        }

        let running = parseExampleDirectives("{run}")
        @Expect(joinedProblems(running.problems), "")
        @Expect(running.execute && !running.expectsFailure, true)

        @Expect(acceptedFlagText(["--cfg", "android=true", "-Woff", "all"]),
            "--cfg android=true -Woff all")
        @Expect(acceptedFlagText(["-Won", "deprecated", "--int-overflow", "wrapping",
            "--experimental", "-Os"]),
            "-Won deprecated --int-overflow wrapping --experimental -Os")
    }

    @TestCase
    func malformedBlocksNameTheOffendingGrammar(): Unit {
        @Expect(directiveProblems("{}"), "the directive block is empty")
        @Expect(directiveProblems("{bogus}"), "unknown directive '<bogus>'")
        @Expect(directiveProblems("{must-pass must-fail}"), "'must-pass' and 'must-fail' conflict")
        @Expect(directiveProblems("{run must-fail}"), "'run' cannot be combined with 'must-fail'")
        @Expect(directiveProblems("{error=\"x\"}"), "'error' requires 'must-fail'")
        @Expect(directiveProblems("{must-fail error=\"\"}"), "'error=\"\"' pins an empty message")
        @Expect(directiveProblems("{must-fail must-fail}"), "duplicate directive '<must-fail>'")
        @Expect(directiveProblems("{run=1}"), "'run' does not take a value")
        @Expect(directiveProblems("{must-fail"), "'{must-fail' is not a '{…}' directive block")
    }

    @TestCase
    func onlyAllowlistedCompilerOptionsReachCjc(): Unit {
        @Expect(flagProblems(["--output-type", "exe"]), "invalid compiler option '--output-type exe'")
        @Expect(flagProblems(["-Woff", "driver-arg"]), "invalid compiler option '-Woff driver-arg'")
        @Expect(flagProblems(["-o", "evil.so"]), "invalid compiler option '-o evil.so'")
        @Expect(flagProblems(["--import-path", "/tmp/evil"]),
            "invalid compiler option '--import-path /tmp/evil'")
        @Expect(flagProblems(["--cfg"]), "compiler option '--cfg' requires a value")
        @Expect(flagProblems(["-Woff"]), "compiler option '-Woff' requires a value")
        @Expect(flagProblems(["--cfg", "os"]), "invalid compiler option '--cfg os'")
        @Expect(flagProblems(["--cfg", "1bad=value"]), "invalid compiler option '--cfg 1bad=value'")
        @Expect(flagProblems(["--cfg", "key=/tmp/evil"]),
            "invalid compiler option '--cfg key=/tmp/evil'")
        @Expect(flagProblems(["@response.cjo"]), "invalid compiler option '@response.cjo'")
        // Built-in `--cfg` keys are deliberately left to `cjc`, which reports them with
        // a file-less driver error, so the gate attributes them as a context failure
        // instead of duplicating a built-in list that drifts with the SDK.
        @Expect(acceptedFlagText(["--cfg", "os=Linux"]), "--cfg os=Linux")
    }
}
