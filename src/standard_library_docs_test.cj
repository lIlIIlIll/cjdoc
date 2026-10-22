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
private let STANDARD_LIBRARY_HASH_MAP_110_URL =
    "https://docs.cangjie-lang.cn/docs/1.1.0-beta.25/libs/std/collection/collection_package_api/" +
    "collection_package_class.html#class-hashmapk-v-where-k--hashable--equatablek"

private func standardLibraryLinkProject(root: Path, source: String): Unit {
    Directory.create(root.join("src"), recursive: true)
    File.writeTo(root.join("cjpm.toml"),
        "[package]\nname = \"stdlib_link_fixture\"\nversion = \"1.0.0\"\n".toArray())
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

        var unsafeBaseRejected = false
        try {
            let _ = GenerationRequest("project",
                standardLibraryDocsBaseUrl: Some("javascript:alert(1)"))
        } catch (_: IllegalArgumentException) { unsafeBaseRejected = true }
        @Expect(unsafeBaseRejected, true)
    }

    @TestCase
    func publishedNonWhitelistReleaseUsesItsObservedDocsHost(): Unit {
        let navigation = standardLibraryTypeNavigation("1.1.3", ["std.collection.ArrayList"]).getOrThrow()
        @Expect(navigation.url,
            "https://cj-docs.gitcode.com/zh/1.1.3/libs/std/collection/collection_package_api/collection_package_class.html#class-arraylistt")
        @Expect(navigation.reason.contains("unvalidated"), true)
    }
}
