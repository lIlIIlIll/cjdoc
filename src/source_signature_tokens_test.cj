package cjdoc

import std.ast.*
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
    func realLexerStringValueDoesNotIncludeSourceQuotes(): Unit {
        let signature = "public func join(separator!: String = \",\"): String"
        let lexed = cangjieLex(signature)
        @Expect(lexed.size, 13)
        @Expect(lexed[9].kind.toString(), "STRING_LITERAL")
        @Expect(lexed[9].value, ",")

        let witness = sourceApiSignatureTokens(signature)
        @Expect(witness.size, 13)
        @Expect(witness[9], "STRING_LITERAL:3:\",\"")
        @Expect(witness[10], "RPAREN:1:)")
        @Expect(witness[12], "IDENTIFIER:6:String")
    }

    @TestCase
    func emptyEscapedAndUtf8StringsRetainExactSourceSpelling(): Unit {
        let raw = "public func sample(empty!: String = \"\", escaped!: String = \"a\\\"b\", " +
            "unicode!: String = \"中文\"): String"
        let tokens = sourceApiSignatureTokens(raw)
        @Expect(tokens.isEmpty(), false)
        @Expect(hasSourceSignatureToken(tokens, "STRING_LITERAL:2:\"\""), true)
        @Expect(hasSourceSignatureToken(tokens, "STRING_LITERAL:6:\"a\\\"b\""), true)
        @Expect(hasSourceSignatureToken(tokens, "STRING_LITERAL:8:\"中文\""), true)
        @Expect(tokens[tokens.size - 1], "IDENTIFIER:6:String")
    }

    @TestCase
    func multilineTriviaAndCommentsDoNotBecomePartOfTokens(): Unit {
        let raw = "public func accept(\n" +
            "    label!: String = \"Token\" /* after literal */,\n" +
            "    item!: Token): Token // trailing comment"
        let tokens = sourceApiSignatureTokens(raw)
        @Expect(tokens.isEmpty(), false)
        @Expect(hasSourceSignatureToken(tokens, "STRING_LITERAL:7:\"Token\""), true)
        @Expect(hasSourceSignatureToken(tokens, "IDENTIFIER:4:item"), true)
        @Expect(tokens[tokens.size - 1], "IDENTIFIER:5:Token")
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
