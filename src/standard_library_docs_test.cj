package cjdoc

import cjdoc.model as standard_library_model
import cjdoc.render as standard_library_render
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let STANDARD_LIBRARY_ARRAY_LIST_URL =
    "https://cj-docs.gitcode.com/zh/1.2.0/libs/std/collection/collection_package_api/collection_package_class.html#class-arraylistt"
private let STANDARD_LIBRARY_STRING_URL =
    "https://cj-docs.gitcode.com/zh/1.2.0/libs/std/core/core_package_api/core_package_structs.html#struct-string"
private let STANDARD_LIBRARY_ARRAY_URL =
    "https://cj-docs.gitcode.com/zh/1.2.0/libs/std/core/core_package_api/core_package_structs.html#struct-arrayt"
private let STANDARD_LIBRARY_HASH_MAP_110_URL =
    "https://docs.cangjie-lang.cn/docs/1.1.0-beta.25/libs/std/collection/collection_package_api/" +
    "collection_package_class.html#class-hashmapk-v-where-k--hashable--equatablek"

private func standardLibraryLinkProject(root: Path, source: String, name!: String = "stdlib_link_fixture"): Unit {
    Directory.create(root.join("src"), recursive: true)
    File.writeTo(root.join("cjpm.toml"),
        ("[package]\nname = \"" + name + "\"\nversion = \"1.0.0\"\n").toArray())
    File.writeTo(root.join("src/api.cj"), source.toArray())
}

private func standardLibraryLinkGenerate(root: Path,
    standardLibraryDocsVersion!: ?String = None,
    standardLibraryDocsBaseUrl!: ?String = None): standard_library_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
        astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
        standardLibraryDocsVersion: standardLibraryDocsVersion,
        standardLibraryDocsBaseUrl: standardLibraryDocsBaseUrl))
}

private func standardLibraryLinkFunction(documentation: standard_library_model.DocumentationSet,
    name: String): standard_library_model.SymbolDoc {
    for (symbol in documentation.declarations where symbol.kind == "function" && symbol.name == name) {
        return symbol
    }
    throw IllegalArgumentException("expected generated function is missing")
}

@Test
class StandardLibraryDocsTest {
    @TestCase
    func importedTypesLinkInHtmlAndMarkdown(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                import std.collection.ArrayList
                public func accept(values: ArrayList<String>): String { "ok" }
                public func acceptQualified(values: std.collection.ArrayList<String>): std.core.String { "ok" }
                """)
            let documentation = standardLibraryLinkGenerate(temporary)
            let symbol = standardLibraryLinkFunction(documentation, "accept")
            let listType = symbol.parameters[0].typeRef
            @Expect(listType.navigation.getOrThrow().url, STANDARD_LIBRARY_ARRAY_LIST_URL)
            @Expect(listType.arguments[0].navigation.getOrThrow().url, STANDARD_LIBRARY_STRING_URL)
            @Expect(symbol.returnType.getOrThrow().navigation.getOrThrow().url, STANDARD_LIBRARY_STRING_URL)
            let qualified = standardLibraryLinkFunction(documentation, "acceptQualified")
            @Expect(qualified.parameters[0].typeRef.navigation.getOrThrow().url, STANDARD_LIBRARY_ARRAY_LIST_URL)
            @Expect(qualified.returnType.getOrThrow().navigation.getOrThrow().url, STANDARD_LIBRARY_STRING_URL)

            let artifacts = standard_library_render.renderDocumentationFormatsWithOptions(
                documentation, ["html", "markdown"], locale: "en")
            var htmlLinksArrayList = false
            var htmlLinksString = false
            var markdownLinksArrayList = false
            var markdownLinksString = false
            for (artifact in artifacts) {
                if (artifact.path.startsWith("html/")) {
                    htmlLinksArrayList = htmlLinksArrayList ||
                        artifact.content.contains("href=\"" + STANDARD_LIBRARY_ARRAY_LIST_URL + "\"")
                    htmlLinksString = htmlLinksString ||
                        artifact.content.contains("href=\"" + STANDARD_LIBRARY_STRING_URL + "\"")
                } else if (artifact.path.startsWith("markdown/")) {
                    markdownLinksArrayList = markdownLinksArrayList || artifact.content.contains(STANDARD_LIBRARY_ARRAY_LIST_URL)
                    markdownLinksString = markdownLinksString || artifact.content.contains(STANDARD_LIBRARY_STRING_URL)
                }
            }
            @Expect(htmlLinksArrayList, true)
            @Expect(htmlLinksString, true)
            @Expect(markdownLinksArrayList, true)
            @Expect(markdownLinksString, true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func selectedDocsVersionUsesItsValidatedTypeRoute(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                import std.collection.HashMap
                public func accept(values: HashMap<String, String>): String { "ok" }
                """)
            let documentation = standardLibraryLinkGenerate(temporary,
                standardLibraryDocsVersion: Some("1.1.0-beta.25"))
            let typeRef = standardLibraryLinkFunction(documentation, "accept").parameters[0].typeRef
            @Expect(typeRef.navigation.getOrThrow().url, STANDARD_LIBRARY_HASH_MAP_110_URL)
            let artifacts = standard_library_render.renderDocumentationFormatsWithOptions(
                documentation, ["html"], locale: "en")
            var linked = false
            for (artifact in artifacts where artifact.path.startsWith("html/")) {
                linked = linked || artifact.content.contains("href=\"" + STANDARD_LIBRARY_HASH_MAP_110_URL + "\"")
            }
            @Expect(linked, true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func localTypeKeepsPrecedenceOverImplicitCoreDocumentation(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                public struct String {}
                public func accept(value: String): String { value }
                """)
            let documentation = standardLibraryLinkGenerate(temporary)
            let typeRef = standardLibraryLinkFunction(documentation, "accept").parameters[0].typeRef
            let navigation = typeRef.navigation.getOrThrow()
            @Expect(navigation.state, "resolved")
            @Expect(navigation.matchLevel, "exact")
            @Expect(navigation.url != STANDARD_LIBRARY_STRING_URL, true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func nonStandardImportConflictDoesNotLinkTheImplicitCoreCandidate(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                import another.String
                public func accept(value: String): Int64 { 1 }
                """)
            let documentation = standardLibraryLinkGenerate(temporary)
            let typeRef = standardLibraryLinkFunction(documentation, "accept").parameters[0].typeRef
            let navigation = typeRef.navigation.getOrThrow()
            @Expect(navigation.state, "unavailable")
            @Expect(navigation.url.isEmpty(), true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }
    @TestCase
    func arbitraryDocsVersionUsesConfiguredDocsBase(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        let baseUrl = "https://cj-docs.gitcode.com/zh/1.1.4/libs/std"
        let expectedUrl = baseUrl +
            "/collection/collection_package_api/collection_package_class.html#class-arraylistt"
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                import std.collection.ArrayList
                public func accept(values: ArrayList<String>): String { "ok" }
                """)
            let documentation = standardLibraryLinkGenerate(temporary,
                standardLibraryDocsVersion: Some("1.1.4"),
                standardLibraryDocsBaseUrl: Some(baseUrl))
            let typeRef = standardLibraryLinkFunction(documentation, "accept").parameters[0].typeRef
            @Expect(typeRef.navigation.getOrThrow().url, expectedUrl)
            @Expect(typeRef.navigation.getOrThrow().reason.contains("not API identity evidence"), true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func rejectsUnsafeOrUnconfiguredDocsVersions(): Unit {
        var unsafeVersionRejected = false
        try {
            let _ = GenerationRequest("project",
                standardLibraryDocsVersion: Some("../1.1.4"),
                standardLibraryDocsBaseUrl: Some("https://docs.example.test/docs/1.1.4/libs/std"))
        } catch (_: IllegalArgumentException) { unsafeVersionRejected = true }
        @Expect(unsafeVersionRejected, true)

        var missingBaseRejected = false
        try {
            let _ = GenerationRequest("project", standardLibraryDocsVersion: Some("1.1.4"))
        } catch (_: IllegalArgumentException) { missingBaseRejected = true }
        @Expect(missingBaseRejected, true)

        for (unsafeBase in [
            "javascript:alert(1)",
            "https://user@example.com/libs/std",
            "https://example.com:99999/libs/std"
        ]) {
            @ExpectThrows[IllegalArgumentException](GenerationRequest("project",
                standardLibraryDocsBaseUrl: Some(unsafeBase)))
        }
    }

    @TestCase
    func publishedNonWhitelistReleaseUsesItsObservedDocsHost(): Unit {
        let navigation = standardLibraryTypeNavigation("1.1.3", ["std.collection.ArrayList"]).getOrThrow()
        @Expect(navigation.url,
            "https://cj-docs.gitcode.com/zh/1.1.3/libs/std/collection/collection_package_api/collection_package_class.html#class-arraylistt")
        @Expect(navigation.reason.contains("unvalidated"), true)
    }

    @TestCase
    func unrelatedWorkspaceTypeDoesNotSuppressStandardLibraryLink(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            File.writeTo(temporary.join("cjpm.toml"),
                "[workspace]\nmembers = [\"app\", \"unrelated\"]\n".toArray())
            standardLibraryLinkProject(temporary.join("app"), """
                package fixture
                import std.collection.ArrayList
                public func accept(values: ArrayList<String>): Unit {}
                """, name: "app")
            standardLibraryLinkProject(temporary.join("unrelated"), """
                package fixture
                public class ArrayList<T> {}
                """, name: "unrelated")
            let documentation = standardLibraryLinkGenerate(temporary)
            let typeRef = standardLibraryLinkFunction(documentation, "accept").parameters[0].typeRef
            @Expect(typeRef.navigation.getOrThrow().url, STANDARD_LIBRARY_ARRAY_LIST_URL)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func unselectedExternalInventoryDoesNotSuppressStandardLibraryLink(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let app = temporary.join("app")
            let unrelated = temporary.join("unrelated")
            standardLibraryLinkProject(app, """
                package fixture
                import std.collection.ArrayList
                public func accept(values: ArrayList<String>): Unit {}
                """)
            standardLibraryLinkProject(unrelated, """
                package fixture
                public class ArrayList<T> {}
                """, name: "fixture")
            let inventory = standard_library_render.rendererFor("symbol-index")
                .render(standardLibraryLinkGenerate(unrelated))[0].content
            File.writeTo(app.join("inventory.json"), inventory.toArray())
            File.writeTo(app.join("catalog.json"),
                ("{\"schemaVersion\":\"cjdoc.doc-sources/1\",\"documents\":[" +
                "{\"index\":\"inventory.json\",\"baseUrl\":\"https://docs.example.test/unrelated\"}]}").toArray())
            let documentation = DocumentationEngine().generate(GenerationRequest(app.toString(),
                lintProfile: "off", astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                documentSources: ["catalog.json"]))
            let typeRef = standardLibraryLinkFunction(documentation, "accept").parameters[0].typeRef
            @Expect(typeRef.navigation.getOrThrow().url, STANDARD_LIBRARY_ARRAY_LIST_URL)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func typeArityAndAudienceStillControlStandardLibraryFallback(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            for ((parameters, expectedUrl, expectedState) in [
                ("T, U", STANDARD_LIBRARY_ARRAY_LIST_URL, "resolved"),
                ("T", "", "unavailable")
            ]) {
                let project = temporary.join(expectedState)
                standardLibraryLinkProject(project, """
                    package fixture
                    import std.collection.ArrayList
                    private class ArrayList<${parameters}> {}
                    public func accept(values: ArrayList<String>): Unit {}
                    """)
                let documentation = standardLibraryLinkGenerate(project)
                let typeRef = standardLibraryLinkFunction(documentation, "accept").parameters[0].typeRef
                @Expect(typeRef.navigation.getOrThrow().url, expectedUrl)
                @Expect(typeRef.navigation.getOrThrow().state, expectedState)
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }
}

@Test
class StandardLibraryWildcardDocsTest {
    @TestCase
    func standardWildcardLinksArrayAndItsImplicitCoreStringArgument(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                import std.collection.*
                public func accept(values: Array<String>): String { "ok" }
                """)
            let symbol = standardLibraryLinkFunction(standardLibraryLinkGenerate(temporary), "accept")
            let array = symbol.parameters[0].typeRef
            @Expect(array.navigation.getOrThrow().url, STANDARD_LIBRARY_ARRAY_URL)
            @Expect(array.arguments[0].navigation.getOrThrow().url, STANDARD_LIBRARY_STRING_URL)
            @Expect(symbol.returnType.getOrThrow().navigation.getOrThrow().url, STANDARD_LIBRARY_STRING_URL)
            @Expect(array.navigation.getOrThrow().matchLevel, "manual")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func unknownExplicitOrWildcardImportsCannotClaimAnImplicitCoreType(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            for ((name, imports) in [
                ("explicit", "import std.collection.*\nimport std.collection.String"),
                ("external", "import std.collection.*\nimport another.*"),
                ("unknown-standard", "import std.unindexed.*"),
                ("conditional", "@When[feature == \"on\"]\nimport std.collection.*"),
                ("documented-alias", "import std.core.StringBuilder as String")
            ]) {
                let project = temporary.join(name)
                standardLibraryLinkProject(project, """
                    package fixture
                    ${imports}
                    public func accept(value: String): Unit {}
                    """)
                let symbol = standardLibraryLinkFunction(standardLibraryLinkGenerate(project), "accept")
                @Expect(symbol.parameters[0].typeRef.navigation.getOrThrow().url.isEmpty(), true)
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func localArrayAndStringKeepPrecedenceOverStandardWildcardDocumentation(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                import std.collection.*
                public struct String {}
                public class Array<T> {}
                public func accept(values: Array<String>, value: String): String { value }
                """)
            let symbol = standardLibraryLinkFunction(standardLibraryLinkGenerate(temporary), "accept")
            let array = symbol.parameters[0].typeRef
            @Expect(array.navigation.getOrThrow().matchLevel, "exact")
            @Expect(array.navigation.getOrThrow().url != STANDARD_LIBRARY_ARRAY_URL, true)
            @Expect(array.arguments[0].navigation.getOrThrow().matchLevel, "exact")
            @Expect(array.arguments[0].navigation.getOrThrow().url != STANDARD_LIBRARY_STRING_URL, true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }
}

@Test
class StandardLibraryMemberSignatureDocsTest {
    @TestCase
    func memberSummariesLinkStringAndNestedArrayTypes(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            standardLibraryLinkProject(temporary, """
                package fixture
                import std.collection.*
                public class Catalog {
                    public func add(value: String): Unit {}
                    public func addAll(values: Array<String>): Unit {}
                }
                """)
            let artifacts = standard_library_render.renderDocumentationFormatsWithOptions(
                standardLibraryLinkGenerate(temporary), ["html"], locale: "en")
            let add = standardLibraryMemberSummary(artifacts, "add")
            @Expect(add.contains("href=\"" + STANDARD_LIBRARY_STRING_URL + "\""), true)
            let addAll = standardLibraryMemberSummary(artifacts, "addAll")
            @Expect(addAll.contains("href=\"" + STANDARD_LIBRARY_ARRAY_URL + "\""), true)
            @Expect(addAll.contains("href=\"" + STANDARD_LIBRARY_STRING_URL + "\""), true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }
}

private func standardLibraryMemberSummary(artifacts: Array<standard_library_render.RenderArtifact>,
    name: String): String {
    let marker = "data-member-name=\"" + name + "\""
    for (artifact in artifacts where artifact.path.startsWith("html/symbols/") &&
        artifact.content.contains(marker)) {
        return artifact.content.split(marker, 2)[1].split("<summary", 2)[1].split("</summary>", 2)[0]
    }
    throw IllegalArgumentException("expected generated member summary is missing")
}
