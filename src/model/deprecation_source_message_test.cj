package cjdoc.model

import std.unittest.*
import std.unittest.testmacro.*

private func sourceMessageSymbol(annotations: Array<AnnotationDoc>): SymbolDoc {
    let source = SourceRange("src/api.cj", SourcePosition(1, 1, 0), SourcePosition(1, 24, 23))
    SymbolDoc("source-message", "function", "oldParse", "fixture.oldParse", "fixture",
        "cjdoc:module:v1:source-message", "public", source,
        "public func oldParse(text: String): Int64", SemanticInfo("partial", "ast"),
        annotations: annotations)
}

private func sourceAnnotation(spelling: String, provenance!: String = "source"): AnnotationDoc {
    AnnotationDoc(spelling, provenance: provenance,
        provider: if (provenance == "provider") { Some("ast") } else { None<String> })
}

private func sourceMessage(spelling: String): ?String {
    sourceDeprecationMessage(sourceMessageSymbol([sourceAnnotation(spelling)]))
}

@Test
class SourceDeprecationMessageTest {
    @TestCase
    func positionalAndNamedLiteralsAreReadable(): Unit {
        @Expect(sourceMessage("@Deprecated[\"Use parse instead.\"]"), Some("Use parse instead."))
        @Expect(sourceMessage("@Deprecated[message: \"Use parse instead.\"]"), Some("Use parse instead."))
        // Whitespace between the name, the colon and the bracket keeps pairing.
        @Expect(sourceMessage("@Deprecated [ message : \"Reason\" ]"), Some("Reason"))
        @Expect(sourceMessage("@Deprecated[  \"Reason\"  ]"), Some("Reason"))
    }

    @TestCase
    func ordinaryCangjieEscapesAreDecoded(): Unit {
        @Expect(sourceMessage("@Deprecated[\"line\\nquote \\\" back \\\\ tab\\t\"]"),
            Some("line\nquote \" back \\ tab\t"))
        @Expect(sourceMessage("@Deprecated[\"\\u{4e2d}\\u{1F600}\"]"), Some("中\u{1F600}"))
        @Expect(sourceMessage("@Deprecated[\"\\0\"]"), Some("\u{0}"))
        // `\$` is a legal string escape and never interpolation evidence.
        @Expect(sourceMessage("@Deprecated[\"cost \\$5\"]"), Some("cost " + "$" + "5"))
        @Expect(sourceMessage("@Deprecated[\"\\$" + "{literal}\"]"),
            Some("$" + "{literal}"))
    }

    @TestCase
    func bothOrdinaryQuoteDelimitersAreLiterals(): Unit {
        @Expect(sourceMessage("@Deprecated['Use the single-quoted reason.']"),
            Some("Use the single-quoted reason."))
        @Expect(sourceMessage("@Deprecated[message: 'Named single quotes.']"),
            Some("Named single quotes."))
        @Expect(sourceMessage("@Deprecated['It\\'s escaped.']"), Some("It's escaped."))
        @Expect(sourceMessage("@Deprecated['Say \"hi\".']"), Some("Say \"hi\"."))
        for (spelling in ["@Deprecated['''raw''']", "@Deprecated['unterminated]",
            "@Deprecated[\"\"\"raw\"\"\"]"]) {
            @Expect(sourceMessage(spelling), None<String>)
        }
    }

    @TestCase
    func oversizedAnnotationStaysSourceSpelling(): Unit {
        let body = String(Array<Rune>(70 * 1024, repeat: r'a'))
        @Expect(sourceMessage("@Deprecated[\"" + body + "\"]"), None<String>)
        @Expect(declarationIsDeprecated(sourceMessageSymbol(
            [sourceAnnotation("@Deprecated[\"" + body + "\"]")])), true)
    }

    @TestCase
    func ambiguousOrDynamicConstructsAreRejected(): Unit {
        let interpolation = "@Deprecated[\"a" + "$" + "{" + "value}\"]"
        for (spelling in [
            "@Deprecated",
            "@Deprecated[]",
            "@Deprecated[  ]",
            "@Deprecated[\"\"]",
            "@Deprecated[message: \"   \"]",
            "@Deprecated[reason: \"Reason\"]",
            "@Deprecated[message]",
            "@Deprecated[variable]",
            "@Deprecated[message: variable]",
            "@Deprecated[\"a\" + \"b\"]",
            "@Deprecated[\"a\", \"b\"]",
            "@Deprecated[\"a\" \"b\"]",
            "@Deprecated[\"\"\"raw\"\"\"]",
            "@Deprecated[\"unterminated]",
            "@Deprecated[message: \"x\"] extra",
            interpolation,
            "@DeprecatedSoon[\"Reason\"]",
            "@DeprecatedName[\"Reason\"]"
        ]) {
            @Expect(sourceMessage(spelling), None<String>)
        }
    }

    @TestCase
    func provenanceAndMarkerPairingStillGateStatus(): Unit {
        @Expect(!declarationIsDeprecated(sourceMessageSymbol(
            [sourceAnnotation("@Deprecated[\"Reason\"]", provenance: "provider")])))
        @Expect(!declarationIsDeprecated(sourceMessageSymbol(
            [sourceAnnotation("@DeprecatedSoon[\"Reason\"]")])))
        @Expect(declarationIsDeprecated(sourceMessageSymbol([sourceAnnotation("@Deprecated")])))
        @Expect(declarationIsDeprecated(sourceMessageSymbol(
            [sourceAnnotation("@Deprecated [ \"Reason\" ]")])))
        @Expect(sourceDeprecationMessage(sourceMessageSymbol(
            [sourceAnnotation("@Deprecated[\"Reason\"]", provenance: "provider")])), None<String>)
    }

    @TestCase
    func repeatedReasonsMustAgree(): Unit {
        @Expect(sourceDeprecationMessage(sourceMessageSymbol([
            sourceAnnotation("@Deprecated[\"Same\"]"), sourceAnnotation("@Deprecated[message: \"Same\"]")
        ])), Some("Same"))
        @Expect(sourceDeprecationMessage(sourceMessageSymbol([
            sourceAnnotation("@Deprecated[\"One\"]"), sourceAnnotation("@Deprecated[\"Two\"]")
        ])), None<String>)
        // A marker without readable text does not invent a second reason.
        @Expect(sourceDeprecationMessage(sourceMessageSymbol([
            sourceAnnotation("@Deprecated"), sourceAnnotation("@Deprecated[\"Only\"]")
        ])), Some("Only"))
    }
}
