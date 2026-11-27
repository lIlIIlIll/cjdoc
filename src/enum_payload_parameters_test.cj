package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

// A positional enum payload has no source identifier. Doc IR therefore stores a
// synthetic `_<index>` placeholder, but every reading surface must publish
// `#<index>` and an author `@param #0` must select the same payload without
// inventing an identifier that source never declared.
private let ENUM_PAYLOAD_SOURCE = """
package enum_payload_fixture

/** A shape with zero, one and two payload parameters. */
public enum Shape {
    /** No payload. */
    | Origin
    /** One payload. */
    | Circle(Float64)
    /**
     * Two payloads.
     * @param #0 width of the rectangle
     * @param #1 height of the rectangle
     */
    | Rect(Float64, Float64)
}

/** A leading-underscore parameter name is an author name, not a position. */
public func named(_0: Int64): Int64 { _0 }
"""

private func enumPayloadProject(): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src"))
    File.writeTo(root.join("cjpm.toml"),
        "[package]\nname = \"enum_payload_fixture\"\nversion = \"0.1.0\"\noutput-type = \"static\"\n".toArray())
    File.writeTo(root.join("src/api.cj"), ENUM_PAYLOAD_SOURCE.toArray())
    root
}

// Localized payload prose addresses the ordinal (`#0`), while the signature
// keeps the collector's `_<index>` placeholder. The projection must join the
// two without letting the ordinal rule reach a named parameter.
private let ENUM_PAYLOAD_LOCALIZED_SOURCE = """
package enum_payload_localized_fixture

/** 本地化形状。 */
public enum Shape {
    /** 无载荷。 */
    | Origin
    /**
     * 矩形。
     * @param #0 宽
     * @param #1 高
     * @param[lang=en] #0 width in English
     * @param[lang=en] _1 height in English
     */
    | Rect(Float64, Float64)
}

/**
 * 作者命名参数。
 * @param _0 作者写下的名字
 * @param[lang=en] _0 the author name
 */
public func named(_0: Int64): Int64 { _0 }

/**
 * 有害选择器。
 * @param[lang=en] #0 this selector names no parameter
 */
public func misplaced(value: Int64): Int64 { value }
"""

private func enumPayloadLocalizedProject(): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src"))
    File.writeTo(root.join("cjpm.toml"),
        "[package]\nname = \"enum_payload_localized_fixture\"\nversion = \"0.1.0\"\noutput-type = \"static\"\n".toArray())
    File.writeTo(root.join("cjdoc.toml"),
        "[i18n]\ndefault-language = \"zh-CN\"\nlanguages = [\"zh-CN\", \"en\"]\n".toArray())
    File.writeTo(root.join("src/api.cj"), ENUM_PAYLOAD_LOCALIZED_SOURCE.toArray())
    root
}

private func enumPayloadGenerate(root: Path, lintProfile: String): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: lintProfile,
        astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
}

private func enumCaseDeclaration(documentation: api_model.DocumentationSet,
    name: String): api_model.SymbolDoc {
    for (declaration in documentation.declarations) {
        if (declaration.kind == "enumCase" && declaration.name == name) { return declaration }
    }
    throw IllegalArgumentException("missing enum case " + name)
}

private func enumPayloadHtml(documentation: api_model.DocumentationSet,
    locale!: String = "en"): HashMap<String, String> {
    let pages = HashMap<String, String>()
    for (artifact in api_render.renderDocumentationFormatsWithOptions(documentation, ["html"],
        locale: locale)) {
        for (name in ["Origin", "Circle", "Rect"]) {
            if (artifact.path.endsWith("/${name}/index.html")) { pages[name] = artifact.content }
        }
    }
    pages
}

private func queryEnumCaseParameters(documentation: api_model.DocumentationSet,
    symbolId: String): JsonArray {
    let session = DocumentationQuerySession(documentation)
    let request = "{\"operation\":\"get_symbol\",\"symbolId\":${JsonNode.string(symbolId).toJson()}," +
        "\"sections\":[\"parameters\"]}"
    let response = JsonNode.parse(session.execute(request)).asObject()
    @Expect(response.get("status").getOrThrow().asString(), "ok")
    let item = response.get("result").getOrThrow().asObject().get("items")
        .getOrThrow().asArray()[0].asObject()
    let sections = item.get("sections").getOrThrow().asArray()
    for (index in 0..sections.size()) {
        let section = sections[index].asObject()
        if (section.get("name").getOrThrow().asString() == "parameters") {
            return section.get("value").getOrThrow().asObject()
                .get("parameters").getOrThrow().asArray()
        }
    }
    throw IllegalArgumentException("missing parameters section")
}

@Test
class EnumPayloadParameterTest {
    @TestCase
    func payloadCountsProjectPositionallyInHtmlMarkdownAndQuery(): Unit {
        let root = enumPayloadProject()
        try {
            let documentation = enumPayloadGenerate(root, "off")
            let origin = enumCaseDeclaration(documentation, "Origin")
            let circle = enumCaseDeclaration(documentation, "Circle")
            let rect = enumCaseDeclaration(documentation, "Rect")
            @Expect(origin.parameters.size, 0)
            @Expect(circle.parameters.size, 1)
            @Expect(rect.parameters.size, 2)
            // The wire keeps the captured placeholder; only reading surfaces rename.
            @Expect(rect.parameters[0].name, "_0")

            let pages = enumPayloadHtml(documentation)
            @Expect(!pages["Origin"].contains("cj-params__name"))
            @Expect(pages["Circle"].contains("cj-params__name\">#0<"))
            @Expect(!pages["Circle"].contains("cj-params__name\">#1<"))
            let html = pages["Rect"]
            @Expect(html.contains("cj-params__name\">#0<"))
            @Expect(html.contains("cj-params__name\">#1<"))
            @Expect(!html.contains("cj-params__name\">_0<"))
            @Expect(html.contains("width of the rectangle"))
            @Expect(html.contains("height of the rectangle"))

            let snapshot = api_render.DocumentationReadSnapshot(documentation, locale: Some("en"))
            let originText = snapshot.renderDeclarationMarkdown(origin.id).getOrThrow()
            let circleText = snapshot.renderDeclarationMarkdown(circle.id).getOrThrow()
            @Expect(!originText.contains("- `#0`: "))
            @Expect(circleText.contains("- `#0`: "))
            @Expect(!circleText.contains("- `#1`: "))
            let markdown = snapshot.renderDeclarationMarkdown(rect.id).getOrThrow()
            @Expect(markdown.contains("- `#0`: "))
            @Expect(markdown.contains("- `#1`: "))
            @Expect(!markdown.contains("- `_0`: "))
            @Expect(markdown.contains("width of the rectangle"))

            let queryParameters = queryEnumCaseParameters(documentation, rect.id)
            @Expect(queryParameters.size(), 2)
            @Expect(queryParameters[0].asObject().get("name").getOrThrow().asString(), "#0")
            @Expect(queryParameters[1].asObject().get("name").getOrThrow().asString(), "#1")
            @Expect(queryEnumCaseParameters(documentation, origin.id).size(), 0)
            let circleParameters = queryEnumCaseParameters(documentation, circle.id)
            @Expect(circleParameters.size(), 1)
            @Expect(circleParameters[0].asObject().get("name").getOrThrow().asString(), "#0")
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func positionalParamBindsWithoutUnknownSubjectDiagnostic(): Unit {
        let root = enumPayloadProject()
        try {
            let documentation = enumPayloadGenerate(root, "strict")
            // No positional selector may be reported as an unknown parameter or
            // a missing documentation field.
            let findings = ArrayList<String>()
            for (diagnostic in documentation.diagnostics) {
                let positionalDiagnostic = ["CJDOC1001", "CJDOC1004", "CJDOC3001", "CJDOC3004",
                    "CJDOC3109"].contains(diagnostic.code)
                if (positionalDiagnostic) { findings.add("${diagnostic.code}: ${diagnostic.message}") }
            }
            @Expect(findings.size, 0)
            let rect = enumCaseDeclaration(documentation, "Rect")
            @Expect(rect.parameters[0].documentation, Some("width of the rectangle"))
            @Expect(rect.parameters[1].documentation, Some("height of the rectangle"))
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func localizedPayloadDescriptionSelectsAnOrdinalTag(): Unit {
        let root = enumPayloadLocalizedProject()
        try {
            let documentation = enumPayloadGenerate(root, "off")
            let rect = enumCaseDeclaration(documentation, "Rect")
            // The wire is unchanged: the payload still stores its placeholder.
            @Expect(rect.parameters[0].name, "_0")
            @Expect(rect.parameters[1].name, "_1")

            let english = api_render.projectDocumentationLanguage(documentation, "en")
            let englishRect = enumCaseDeclaration(english, "Rect")
            // Requested `_1` must win over the author's `#1` in the fallback language.
            @Expect(englishRect.parameters[0].documentation, Some("width in English"))
            @Expect(englishRect.parameters[1].documentation, Some("height in English"))

            let chinese = api_render.projectDocumentationLanguage(documentation, "zh-CN")
            let chineseRect = enumCaseDeclaration(chinese, "Rect")
            @Expect(chineseRect.parameters[0].documentation, Some("宽"))
            @Expect(chineseRect.parameters[1].documentation, Some("高"))

            // The reading surfaces built from the projection carry the prose.
            let romanPages = enumPayloadHtml(documentation)
            @Expect(romanPages["Rect"].contains("width in English"))
            @Expect(romanPages["Rect"].contains("height in English"))
            let localizedPages = enumPayloadHtml(documentation, locale: "zh-CN")
            @Expect(localizedPages["Rect"].contains("宽"))
            @Expect(localizedPages["Rect"].contains("高"))
            @Expect(!localizedPages["Rect"].contains("width in English"))

            // A named parameter keeps its own identity in both languages: the
            // ordinal rule is scoped to enum payloads, so `_0` on a function is
            // still an author name and never matches `#0`.
            for (language in ["en", "zh-CN"]) {
                let projected = api_render.projectDocumentationLanguage(documentation, language)
                let expected = if (language == "en") { "the author name" } else { "作者写下的名字" }
                var namedSeen = false
                for (declaration in projected.declarations where declaration.name == "named") {
                    namedSeen = true
                    @Expect(declaration.parameters[0].name, "_0")
                    @Expect(declaration.parameters[0].documentation, Some(expected))
                }
                @Expect(namedSeen, true)
                // `#0` names no parameter of `misplaced`, so its prose is never
                // adopted as that function's parameter documentation.
                for (declaration in projected.declarations where declaration.name == "misplaced") {
                    @Expect(declaration.parameters[0].name, "value")
                    @Expect(declaration.parameters[0].documentation
                        .getOrDefault({ => "" }).contains("this selector"), false)
                }
            }
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func namedPlaceholderIsNotAPositionOutsideEnumPayloads(): Unit {
        // Model-level guard: `_0` is only a position on an enum case payload, so
        // a function that really is named `_0` keeps requiring its own subject.
        @Expect(api_model.parameterMatchesSubject("enumCase", "_0", "#0"))
        @Expect(api_model.parameterMatchesSubject("enumCase", "_1", "#1"))
        @Expect(api_model.parameterMatchesSubject("enumCase", "_0", "_0"))
        @Expect(!api_model.parameterMatchesSubject("function", "_0", "#0"))
        @Expect(api_model.parameterMatchesSubject("function", "_0", "_0"))
        @Expect(!api_model.parameterMatchesSubject("enumCase", "_0", "#1"))
        @Expect(!api_model.parameterMatchesSubject("enumCase", "_0", "#"))
        @Expect(!api_model.parameterMatchesSubject("enumCase", "_0", "#x"))
        @Expect(!api_model.parameterMatchesSubject("enumCase", "_0", "#00"))
        @Expect(api_model.positionalPayloadIndex("#9223372036854775808").isNone())
        @Expect(api_model.parameterDisplayName("enumCase", "_2"), "#2")
        @Expect(api_model.parameterDisplayName("function", "_2"), "_2")
        @Expect(api_model.parameterDisplayName("enumCase", "value"), "value")
    }
}
