package cjdoc

import cjdoc.render as api_render
import std.unittest.*
import std.unittest.testmacro.*

private func hasSourceSignatureToken(tokens: Array<String>, expected: String): Bool {
    for (token in tokens) {
        if (token == expected) { return true }
    }
    false
}

@Test
class SourceSignatureLexemeTest {
    @TestCase
    func literalSourceWitnessSurvivesDocIrJsonRoundTrip(): Unit {
        let original = generateFixture("frontend_regressions")
        let restored = api_render.decodeDocIr(api_render.encodeDocIr(original))
        let declaration = declarationNamed(restored, "defaulted")
        @Expect(declaration.sourceApiSignature.state, "available")
        @Expect(hasSourceSignatureToken(declaration.sourceApiSignature.tokens.toArray(),
            "STRING_LITERAL:7:\"cjdoc\""), true)
    }

    @TestCase
    func sourceWitnessSurvivesBindingAndPublicProjection(): Unit {
        let documentation = generateFixture("frontend_regressions")
        let declaration = declarationNamed(documentation, "defaulted")
        @Expect(declaration.sourceApiSignature.state, "available")
        @Expect(hasSourceSignatureToken(declaration.sourceApiSignature.tokens.toArray(),
            "STRING_LITERAL:7:\"cjdoc\""), true)
    }
}
