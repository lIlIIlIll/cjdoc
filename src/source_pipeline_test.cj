package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.process.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Windows"]
import std.posix.*

private let FIXTURES = "tests/fixtures/projects/"
private let TEST_AST_PREFLIGHT = Some("target/release/bin/main")

private func generateFixture(name: String, lintProfile!: String = "off",
    includePathDependencies!: Bool = false, includeCachedDependencies!: Bool = false,
    dependencySources!: Array<DependencySourceInput> = [], cfgValues!: Array<CfgValue> = [],
    cacheDirectory!: ?String = None, cjpmCacheRoot!: ?String = None,
    jobs!: Int64 = 1): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(FIXTURES + name,
        lintProfile: lintProfile, audience: "all",
        includePathDependencies: includePathDependencies,
        includeCachedDependencies: includeCachedDependencies,
        dependencySources: dependencySources, cfgValues: cfgValues,
        cacheDirectory: cacheDirectory, cacheFingerprint: Some("source-pipeline-regressions-v1"),
        cjpmCacheRoot: cjpmCacheRoot,
        jobs: jobs,
        astPreflightExecutable: TEST_AST_PREFLIGHT))
}

private func containsDiagnostic(documentation: api_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { return true }
    }
    false
}

private func declarationNamed(documentation: api_model.DocumentationSet,
    name: String): api_model.SymbolDoc {
    for (declaration in documentation.declarations) {
        if (declaration.name == name) { return declaration }
    }
    throw IllegalStateException("fixture declaration '${name}' not found")
}

private func markdownNodeNamed(node: api_model.MarkdownNode,
    kind: String): ?api_model.MarkdownNode {
    if (node.kind == kind) { return Some(node) }
    for (child in node.children) {
        if (let Some(found) <- markdownNodeNamed(child, kind)) { return Some(found) }
    }
    None
}

private func diagnosticCount(documentation: api_model.DocumentationSet, code: String): Int64 {
    var count: Int64 = 0
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) { count++ }
    }
    count
}

private func testCjpmTarget(): String {
    let (exitCode, output, _) = executeWithOutput("cjc", ["--version"])
    if (exitCode != 0) { throw IllegalStateException("cjc --version failed") }
    for (line in String.fromUtf8(output).split("\n")) {
        let trimmed = line.trimAscii()
        if (trimmed.startsWith("Target:")) {
            return trimmed.removePrefix("Target:").trimAscii()
        }
    }
    throw IllegalStateException("cjc --version did not report Target")
}

@Test
class SourcePipelineTest {
    @TestCase
    func extractsSupportedLanguageStructures(): Unit {
        let documentation = generateFixture("basic")
        @Expect(documentation.declarations.size, 25)
        let kinds = HashSet<String>()
        for (declaration in documentation.declarations) { kinds.add(declaration.kind) }
        for (expected in ["class", "struct", "interface", "enum", "extend", "function",
            "property", "constructor", "typeAlias", "enumCase", "variable"]) {
            @Expect(kinds.contains(expected), true)
        }
        @Expect(declarationNamed(documentation, "解析").qualifiedName, "basic.解析")
        @Expect(declarationNamed(documentation, "identity").genericParameters.size, 1)
    }

    @TestCase
    func overloadsHaveStableDistinctSymbolIds(): Unit {
        let documentation = generateFixture("basic")
        let overloadIds = ArrayList<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse") { overloadIds.add(declaration.id) }
            @Expect(!declaration.id.contains("src/"), true)
            @Expect(!declaration.id.contains(":1:"), true)
        }
        @Expect(overloadIds.size, 2)
        @Expect(overloadIds[0] != overloadIds[1], true)
        @Expect(overloadIds[0].contains("Array<UInt8>") || overloadIds[1].contains("Array<UInt8>"), true)
        @Expect(overloadIds[0].contains("String") || overloadIds[1].contains("String"), true)
    }

    @TestCase
    func filePrivateTopLevelDeclarationsHaveInjectiveSymbolIds(): Unit {
        let documentation = generateFixture("private_file_scope")
        let helperIds = ArrayList<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "sameHelper") { helperIds.add(declaration.id) }
        }
        @Expect(helperIds.size, 2)
        @Expect(helperIds[0] != helperIds[1], true)
        @Expect(helperIds[0].contains("::file:src/"), true)
        @Expect(helperIds[1].contains("::file:src/"), true)
    }

    @TestCase
    func parsesStructuredCommentsAndMarkdownAst(): Unit {
        let documentation = generateFixture("basic")
        var selected: ?api_model.SymbolDoc = None
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse" && declaration.parameters.size == 1 &&
                declaration.parameters[0].typeRef.spelling == "String") { selected = Some(declaration) }
        }
        let declaration = selected.getOrThrow()
        let comment = declaration.documentation.getOrThrow()
        @Expect(comment.summary, "从文本解析值。")
        @Expect(comment.markdown.kind, "document")
        @Expect(comment.markdown.children.size >= 3, true)
        @Expect(comment.markdown.children[0].kind, "paragraph")
        var tagNames = HashSet<String>()
        for (tag in comment.tags) { tagNames.add(tag.name) }
        for (name in ["param", "return", "throws", "see", "since"]) {
            @Expect(tagNames.contains(name), true)
        }
    }

    @TestCase
    func keepsStructuredTagsInsideGfmFencesAndParsesSpacedSeeTargets(): Unit {
        let comment = parseDocComment("""
            /**
            * Summary.
            *
            * ~~~~text
            * @param notATag preserved
            * ~~~
            * ~~~~
            * ````text
            * @throws NotAType preserved
            * ```
            * ````
            * @see sample.target(String, Bool) related overload
            * @see sample.transform<(String) -> Bool>(Int64) arrow target
            */
            """)
        @Expect(comment.params.size, 0)
        @Expect(comment.throwsTags.size, 0)
        @Expect(comment.descriptionMarkdown.contains("@param notATag preserved"), true)
        @Expect(comment.descriptionMarkdown.contains("@throws NotAType preserved"), true)
        @Expect(comment.see.size, 2)
        @Expect(comment.see[0].subject, "sample.target(String, Bool)")
        @Expect(comment.see[0].description, "related overload")
        @Expect(comment.see[1].subject, "sample.transform<(String) -> Bool>(Int64)")
        @Expect(comment.see[1].description, "arrow target")
    }

    @TestCase
    func trimsManyLeadingDocCommentLinesWithoutChangingMarkdown(): Unit {
        let raw = StringBuilder("/**\n")
        var index: Int64 = 0
        while (index < 20000) {
            raw.append(" *\n")
            index++
        }
        raw.append(" * Summary.\n */")
        let comment = parseDocComment(raw.toString())
        @Expect(comment.summaryMarkdown, "Summary.")
        @Expect(comment.descriptionMarkdown, "")
    }

    @TestCase
    func treatsFourSpaceMarkdownAsCodeAndAllowsOnlyThreeSpaceFences(): Unit {
        let comment = parseDocComment("""
            /**
            * Summary.
            *
            *     @param indented not a tag
            *     ``` not a fence
            *     @throws Indented also not a tag
            *    ```text
            * @param fenced still not a tag
            *     ``` four-space closing does not close
            * @return still fenced
            *    ```
            * @see sample.target real tag
            */
            """)
        @Expect(comment.params.size, 0)
        @Expect(comment.throwsTags.size, 0)
        @Expect(comment.returns.isNone(), true)
        @Expect(comment.see.size, 1)
        @Expect(comment.see[0].subject, "sample.target")
        @Expect(comment.descriptionMarkdown.contains("@param indented not a tag"), true)
        @Expect(comment.descriptionMarkdown.contains("@return still fenced"), true)
    }

    @TestCase
    func derivesStructuredTagsAndSummaryFromGfmBlockStructure(): Unit {
        let comment = parseDocComment("""
            /**
            * Summary.
            *
            * - list item
            *   ```cj
            *   @param nested hidden in list-item fence
            *
            *   @throws Nested hidden after a blank code line
            *   ```
            *
            * ```bad`info
            * @param visible parsed from the paragraph because the info string is invalid
            * ```
            * @see hidden.inside.unclosed.fence
            */
            """)
        @Expect(comment.summaryMarkdown, "Summary.")
        @Expect(comment.params.size, 1)
        @Expect(comment.params[0].subject, "visible")
        @Expect(comment.throwsTags.size, 0)
        @Expect(comment.see.size, 0)
        @Expect(comment.descriptionMarkdown.contains("@param nested hidden"), true)
        @Expect(comment.descriptionMarkdown.contains("@throws Nested hidden"), true)
        @Expect(comment.descriptionMarkdown.contains("@see hidden.inside.unclosed.fence"), true)
        @Expect(comment.descriptionMarkdown.contains("```bad`info"), true)
    }

    @TestCase
    func selectsFirstParagraphAsSummaryAndRetainsOtherBlocksAsDescription(): Unit {
        let comment = parseDocComment("""
            /**
            * # API heading
            *
            * Paragraph summary.
            *
            * - Additional detail
            */
            """)
        @Expect(comment.summaryMarkdown, "Paragraph summary.")
        @Expect(comment.descriptionMarkdown.contains("# API heading"), true)
        @Expect(comment.descriptionMarkdown.contains("- Additional detail"), true)

        let blocksOnly = parseDocComment("""
            /**
            * # Heading only
            *
            * - Detail only
            */
            """)
        @Expect(blocksOnly.summaryMarkdown, "")
        @Expect(blocksOnly.descriptionMarkdown.contains("# Heading only"), true)
    }

    @TestCase
    func bindsAdjacentEnumCaseAndTupleDocumentationThroughPublicApi(): Unit {
        let documentation = generateFixture("frontend_regressions")
        @Expect(documentation.status, "complete")
        @Expect(declarationNamed(documentation, "adjacent").documentation.getOrThrow().summary,
            "A declaration with no byte gap after its comment.")

        let first = declarationNamed(documentation, "first")
        let second = declarationNamed(documentation, "second")
        @Expect(first.documentation.getOrThrow().summary,
            "Both tuple bindings share this documentation.")
        @Expect(second.documentation.getOrThrow().summary,
            "Both tuple bindings share this documentation.")
        @Expect(first.id != second.id, true)
        for (declaration in documentation.declarations) {
            @Expect(!declaration.name.isEmpty(), true)
            @Expect(declaration.name != "<pattern>", true)
        }

        @Expect(declarationNamed(documentation, "Closed").documentation.getOrThrow().summary,
            "A compact enum-case comment.")
        @Expect(declarationNamed(documentation, "ClosedStatus").enumNonExhaustive, Some(false))
        @Expect(declarationNamed(documentation, "OpenStatus").enumNonExhaustive, Some(true))

        let defaulted = declarationNamed(documentation, "defaulted")
        @Expect(defaulted.parameters.size, 3)
        @Expect(defaulted.parameters[0].name, "required")
        @Expect(defaulted.parameters[0].defaultExpression, None)
        @Expect(defaulted.parameters[1].name, "count")
        @Expect(defaulted.parameters[1].defaultExpression, Some("40 + 2"))
        @Expect(defaulted.parameters[2].name, "label")
        @Expect(defaulted.parameters[2].defaultExpression, Some("\"cjdoc\""))

        let fenced = declarationNamed(documentation, "fenced").documentation.getOrThrow()
        @Expect(fenced.description.contains("@param insideTilde not a tag"), true)
        @Expect(fenced.description.contains("@throws InsideBacktick not a tag"), true)
        var sawSee = false
        for (tag in fenced.tags) {
            @Expect(tag.name != "param", true)
            @Expect(tag.name != "throws", true)
            if (tag.name == "see") {
                sawSee = true
                @Expect(tag.subject, "frontend_regressions.target(String, Bool)")
                @Expect(tag.referenceState, "resolved")
                @Expect(tag.targetSymbolId.isSome(), true)
            }
        }
        @Expect(sawSee, true)
    }

    @TestCase
    func generatedMarkdownPreservesClosedStructuralMetadata(): Unit {
        let documentation = generateFixture("frontend_regressions")
        let markdown = declarationNamed(documentation, "richMarkdown")
            .documentation.getOrThrow().markdown

        let heading = markdownNodeNamed(markdown, "heading").getOrThrow()
            .metadata.getOrThrow()
        @Expect(heading.headingLevel, Some(2))

        let list = markdownNodeNamed(markdown, "list").getOrThrow()
            .metadata.getOrThrow()
        @Expect(list.listKind, Some("ordered"))
        @Expect(list.listStart, Some(3))
        @Expect(list.listDelimiter, Some("parenthesis"))
        let item = markdownNodeNamed(markdown, "list_item").getOrThrow()
            .metadata.getOrThrow()
        @Expect(item.taskState, Some("notTask"))

        let code = markdownNodeNamed(markdown, "code_block").getOrThrow()
            .metadata.getOrThrow()
        @Expect(code.codeKind, Some("fenced"))
        @Expect(code.fenceCharacter, Some("~"))
        @Expect(code.fenceLength, Some(4))
        @Expect(code.infoRaw, Some("cj {#sample}"))
        @Expect(code.language, Some("cj"))
        // The pinned Markdown parser preserves the complete fence suffix in
        // infoRaw but does not split attributes into attributesRaw.
        @Expect(code.attributesRaw, Some(""))

        let table = markdownNodeNamed(markdown, "table").getOrThrow()
            .metadata.getOrThrow()
        @Expect(table.tableAlignments.size, 2)
        @Expect(table.tableAlignments[0], "left")
        @Expect(table.tableAlignments[1], "right")
        let row = markdownNodeNamed(markdown, "table_row").getOrThrow()
            .metadata.getOrThrow()
        @Expect(row.tableHeader, Some(true))
        let cell = markdownNodeNamed(markdown, "table_cell").getOrThrow()
            .metadata.getOrThrow()
        @Expect(cell.tableAlignment, Some("left"))

        let encoded = api_render.encodeDocIr(documentation)
        let decoded = api_render.decodeDocIr(encoded)
        let decodedDefaulted = declarationNamed(decoded, "defaulted")
        @Expect(decodedDefaulted.parameters[0].defaultExpression, None)
        @Expect(decodedDefaulted.parameters[1].defaultExpression, Some("40 + 2"))
        @Expect(decodedDefaulted.parameters[2].defaultExpression, Some("\"cjdoc\""))
        @Expect(api_render.encodeDocIr(decoded), encoded)
    }

    @TestCase
    func preservesEnumExhaustivenessAcrossColdAndWarmSourceCache(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        let cache = temporary.join("cache")
        try {
            let cold = generateFixture("frontend_regressions", cacheDirectory: Some(cache.toString()))
            @Expect(declarationNamed(cold, "OpenStatus").enumNonExhaustive, Some(true))
            @Expect(declarationNamed(cold, "ClosedStatus").enumNonExhaustive, Some(false))
            @Expect(declarationNamed(cold, "defaulted").parameters[1].defaultExpression,
                Some("40 + 2"))
            @Expect(declarationNamed(cold, "defaulted").parameters[2].defaultExpression,
                Some("\"cjdoc\""))
            @Expect(Directory.readFrom(cache).size, 1)

            let warm = generateFixture("frontend_regressions", cacheDirectory: Some(cache.toString()))
            @Expect(declarationNamed(warm, "OpenStatus").enumNonExhaustive, Some(true))
            @Expect(declarationNamed(warm, "ClosedStatus").enumNonExhaustive, Some(false))
            @Expect(declarationNamed(warm, "defaulted").parameters[1].defaultExpression,
                Some("40 + 2"))
            @Expect(declarationNamed(warm, "defaulted").parameters[2].defaultExpression,
                Some("\"cjdoc\""))
            @Expect(api_render.encodeDocIr(warm), api_render.encodeDocIr(cold))
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func preservesPrimaryConstructorMembersAcrossCacheAndJobCounts(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("primary-members")
            let cache = temporary.join("cache")
            Directory.create(root.join("src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"),
                "[package]\nname = \"primary_members\"\n".toArray())
            File.writeTo(root.join("src/api.cj"), """
                package primary_members

                /** A record with constructor-declared members. */
                public class Record {
                    /** Creates a record. */
                    public Record(label: String, public let immutable: Int64,
                        public var mutable: String) {}
                }
                """.toArray())

            let cold = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("primary-members-v1"), jobs: 1,
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            let warm = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("primary-members-v1"), jobs: 4,
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(cold.status, "complete")
            @Expect(api_render.encodeDocIr(warm), api_render.encodeDocIr(cold))

            var ownerId: ?String = None
            for (declaration in cold.declarations) {
                if (declaration.kind == "class" && declaration.name == "Record") {
                    ownerId = Some(declaration.id)
                }
            }
            @Expect(ownerId.isSome(), true)
            let immutable = declarationNamed(cold, "immutable")
            let mutable = declarationNamed(cold, "mutable")
            @Expect(immutable.kind, "variable")
            @Expect(mutable.kind, "variable")
            @Expect(immutable.visibility, "public")
            @Expect(mutable.visibility, "public")
            @Expect(immutable.ownerId, ownerId)
            @Expect(mutable.ownerId, ownerId)
            @Expect(immutable.headerSpelling.contains("public let immutable"), true)
            @Expect(mutable.headerSpelling.contains("public var mutable"), true)
            var constructorParameters: Int64 = -1
            for (declaration in cold.declarations) {
                if (declaration.kind == "constructor" && declaration.name == "Record") {
                    constructorParameters = declaration.parameters.size
                }
            }
            @Expect(constructorParameters, 3)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func acceptsTomlTableHeadersWithTrailingComments(): Unit {
        let manifest = parseCjpmManifest("""
            [package] # package metadata
            name = "sample"
            [workspace] # workspace metadata
            members = ["member"]
            [dependencies] # dependency metadata
            dep = { path = "../dep" }
            """)
        @Expect(manifest.packageName, Some("sample"))
        @Expect(manifest.workspaceMembers.size, 1)
        @Expect(manifest.workspaceMembers[0], "member")
        @Expect(manifest.pathDependencies.size, 1)
        @Expect(manifest.pathDependencies[0], "../dep")

        let locked = parseCjpmLock("""
            [requires] # lock metadata
            dep = { git = "https://example.invalid/dep.git", commitId = "abc123" }
            """)
        @Expect(locked.dependencies.size, 1)
        @Expect(locked.dependencies[0].name, "dep")
    }

    @TestCase
    func parsesDottedPackageMetadataAndSupportedDependencyTables(): Unit {
        let dotted = parseCjpmManifest("""
            package.name = "dotted_package"
            package.src-dir = "source/仓颉"
            """)
        @Expect(dotted.invalid, false)
        @Expect(dotted.packageName, Some("dotted_package"))
        @Expect(dotted.packageSrcDir, Some("source/仓颉"))

        let table = parseCjpmPackageNameChecked("""
            [package]
            name = "table_package"
            src-dir = "code"
            """)
        @Expect(table.invalid, false)
        @Expect(table.value, Some("table_package"))
        @Expect(table.sourceDirectory, Some("code"))

        let paths = parseCjpmPathDependencies("""
            [dependencies.direct]
            path = "deps/direct"

            [target.x86_64-unknown-linux-gnu.dependencies]
            inline = { path = "deps/target-inline" }

            [target.x86_64-unknown-linux-gnu.dependencies.target_table]
            path = "deps/target-table"

            [target.aarch64-unknown-linux-gnu.dependencies.ignored]
            path = "deps/other-target"
            """, 10, selectedTarget: Some("x86_64-unknown-linux-gnu"))
        @Expect(paths.invalid, false)
        @Expect(paths.partial, false)
        @Expect(paths.values.size, 3)
        @Expect(paths.values[0], "deps/direct")
        @Expect(paths.values[1], "deps/target-inline")
        @Expect(paths.values[2], "deps/target-table")

        let profileSpecific = parseCjpmPathDependencies("""
            [target.x86_64-unknown-linux-gnu.debug.dependencies.dep]
            path = "deps/profile-specific"
            """, 10, selectedTarget: Some("x86_64-unknown-linux-gnu"))
        @Expect(profileSpecific.invalid, false)
        @Expect(profileSpecific.partial, true)
        @Expect(profileSpecific.values.size, 0)

        let unavailableTarget = parseCjpmPathDependencies("""
            [target.x86_64-unknown-linux-gnu.dependencies.dep]
            path = "deps/unknown-target"
            """, 10)
        @Expect(unavailableTarget.invalid, false)
        @Expect(unavailableTarget.partial, true)
        @Expect(unavailableTarget.values.size, 0)

        let dottedDependency = parseCjpmPathDependencies("""
            dependencies.direct = { path = "deps/dotted" }
            """, 10, selectedTarget: Some("x86_64-unknown-linux-gnu"))
        @Expect(dottedDependency.invalid, false)
        @Expect(dottedDependency.partial, true)
        @Expect(dottedDependency.values.size, 0)
    }

    @TestCase
    func decodesUnicodeAndBasicTomlEscapesWithoutPerByteUtf8Conversion(): Unit {
        let manifest = parseCjpmManifest(
            "[package]\nname = \"根包\"\n" +
            "[workspace]\nmembers = [\"成员\", \"成\\u5458二\"]\n" +
            "[dependencies]\ndep = { path = \"依\\u8d56\\t目录\" }\n")
        @Expect(manifest.invalid, false)
        @Expect(manifest.limitReached, false)
        @Expect(manifest.packageName, Some("根包"))
        @Expect(manifest.workspaceMembers.size, 2)
        @Expect(manifest.workspaceMembers[0], "成员")
        @Expect(manifest.workspaceMembers[1], "成员二")
        @Expect(manifest.pathDependencies[0], "依赖\t目录")

        let escapes = parseCjpmWorkspaceMembers(
            "[workspace]\nmembers = [\"quote\\\"d\", \"slash\\\\d\", " +
            "\"back\\bd\", \"line\\nd\", \"form\\fd\", \"return\\rd\"]\n", 6)
        @Expect(escapes.invalid, false)
        @Expect(escapes.values[0], "quote\"d")
        @Expect(escapes.values[1], "slash\\d")
        @Expect(escapes.values[2], "back\bd")
        @Expect(escapes.values[3], "line\nd")
        @Expect(escapes.values[4], "form\fd")
        @Expect(escapes.values[5], "return\rd")

        let lock = parseCjpmLock(
            "[requires]\n\"依\\u8d56\" = { git = \"https://example.invalid/依赖.git\", " +
            "commitId = \"abc\\t123\" }\n")
        @Expect(lock.invalid, false)
        @Expect(lock.dependencies.size, 1)
        @Expect(lock.dependencies[0].name, "依赖")
        @Expect(lock.dependencies[0].git,
            Some("https://example.invalid/依赖.git"))
        @Expect(lock.dependencies[0].commitId, Some("abc\t123"))

        let invalidManifest = parseCjpmManifest(
            "[package]\nname = \"bad\\q\"\n")
        @Expect(invalidManifest.invalid, true)
        @Expect(invalidManifest.packageName.isNone(), true)
        let invalidLock = parseCjpmLock(
            "[requires]\ndep = { version = \"1\\q\" }\n")
        @Expect(invalidLock.invalid, true)
        @Expect(invalidLock.dependencies.size, 0)
    }

    @TestCase
    func rejectsWorkspaceMemberArraysWithoutCommaSeparators(): Unit {
        let missingComma = parseCjpmWorkspaceMembers(
            "[workspace]\nmembers = [\"first\" \"second\"]\n", 10)
        @Expect(missingComma.invalid, true)

        let doubleComma = parseCjpmWorkspaceMembers(
            "[workspace]\nmembers = [\"first\",, \"second\"]\n", 10)
        @Expect(doubleComma.invalid, true)

        let validTrailingComma = parseCjpmWorkspaceMembers(
            "[workspace]\nmembers = [\"first\",\n\"second\",\n]\n", 10)
        @Expect(validTrailingComma.invalid, false)
        @Expect(validTrailingComma.values.size, 2)
        @Expect(validTrailingComma.values[0], "first")
        @Expect(validTrailingComma.values[1], "second")
    }

    @TestCase
    func rejectsStructurallyInvalidInlineDependencyAndLockTables(): Unit {
        for (manifest in [
            "[dependencies]\ndep = { path = \"dep\", garbage }\n",
            "[dependencies]\ndep = { path = \"dep\" output-type = \"static\" }\n",
            "[dependencies]\ndep = { path = \"dep\", path = \"other\" }\n"
        ]) {
            @Expect(parseCjpmPathDependencies(manifest, 10).invalid, true)
        }

        let validManifest = parseCjpmPathDependencies("""
            [dependencies]
            dep = {
                path = "dep", # retained path
                output-type = "static",
                package-configuration = { feature = true }
            }
            """, 10)
        @Expect(validManifest.invalid, false)
        @Expect(validManifest.values.size, 1)
        @Expect(validManifest.values[0], "dep")

        for (lock in [
            "[requires]\ndep = { version = \"1\", garbage }\n",
            "[requires]\ndep = { version = \"1\" output-type = \"static\" }\n",
            "[requires]\ndep = { version = \"1\", version = \"2\" }\n"
        ]) {
            @Expect(parseCjpmLock(lock).invalid, true)
        }

        let validLock = parseCjpmLock("""
            [requires]
            dep = {
                git = "https://example.invalid/dep.git",
                commitId = "abc123", # pinned revision
                output-type = "static"
            }
            """)
        @Expect(validLock.invalid, false)
        @Expect(validLock.dependencies.size, 1)
        @Expect(validLock.dependencies[0].name, "dep")
    }

    @TestCase
    func sharesTomlByteAndWorkLimitsAcrossAllParsedArrays(): Unit {
        let text = "[package]\nname = \"sample\"\n" +
            "[workspace]\nmembers = [\"a\", \"b\"]\n" +
            "[dependencies]\ndep = { path = \"../dep\" }\n"
        let byteLimited = parseCjpmManifest(text, maxBytes: text.size - 1)
        @Expect(byteLimited.limitReached, true)
        @Expect(byteLimited.workspaceMembers.size, 0)
        @Expect(byteLimited.pathDependencies.size, 0)

        let workLimited = parseCjpmManifest(text, maxWork: text.size + 1)
        @Expect(workLimited.limitReached, true)
        let lockText = "[requires]\na = { version = \"1\" }\nb = { version = \"2\" }\n"
        let lockLimited = parseCjpmLock(lockText, maxWork: lockText.size - 1)
        @Expect(lockLimited.limitReached, true)
    }

    @TestCase
    func ignoresTomlHeadersInsideMultilineStringsAndBoundsAdapterEntries(): Unit {
        let basicFence = "\"\"\""
        let literalFence = "'''"
        let manifest = parseCjpmManifest(
            "[package]\nname = \"sample\"\ndescription = ${basicFence}\n" +
            "[workspace] # example only\nmembers = [\"ghost\"]\n${basicFence}\n" +
            "notes = ${literalFence}\n[dependencies] # example only\n" +
            "ghost = { path = \"../ghost\" }\n${literalFence}\n" +
            "[workspace] # real\nmembers = [\"member\"]\n" +
            "[dependencies] # real\ndep = { path = \"../dep\" }\n")
        @Expect(manifest.packageName, Some("sample"))
        @Expect(manifest.workspaceMembers.size, 1)
        @Expect(manifest.workspaceMembers[0], "member")
        @Expect(manifest.pathDependencies.size, 1)
        @Expect(manifest.pathDependencies[0], "../dep")

        let lock = parseCjpmLock(
            "notes = ${basicFence}\n[requires] # example only\n" +
            "ghost = { version = \"0.0.0\" }\n${basicFence}\n" +
            "[requires] # real\ndep = { version = \"1.0.0\" }\n")
        @Expect(lock.dependencies.size, 1)
        @Expect(lock.dependencies[0].name, "dep")

        let members = parseCjpmWorkspaceMembers(
            "[workspace]\nmembers = [\"a\", \"b\", \"c\"]\n", 2)
        @Expect(members.values.size, 2)
        @Expect(members.values[0], "a")
        @Expect(members.values[1], "b")
        @Expect(members.entryCount, 2)
        @Expect(members.limitReached, true)

        let paths = parseCjpmPathDependencies(
            "[dependencies]\na = { path = \"a\" }\nb = { path = \"b\" }\n", 1)
        @Expect(paths.values.size, 1)
        @Expect(paths.values[0], "a")
        @Expect(paths.limitReached, true)

        let boundedLock = parseCjpmLock(
            "[requires]\na = { version = \"1\" }\nb = { version = \"2\" }\n",
            maxEntries: 1)
        @Expect(boundedLock.dependencies.size, 1)
        @Expect(boundedLock.entryCount, 1)
        @Expect(boundedLock.limitReached, true)
    }

    @TestCase
    func boundsCacheEncodingAndCapturedSourceOffsets(): Unit {
        let exact = SourceCacheWriter(maxBytes: 3)
        exact.add("a")
        @Expect(exact.result().getOrThrow(), "1:a".toArray())

        let exceeded = SourceCacheWriter(maxBytes: 2)
        exceeded.add("a")
        @Expect(exceeded.result().isNone(), true)

        let aggregateWriter = SourceCacheWriter(maxItems: 2)
        @Expect(aggregateWriter.addCount(1), true)
        @Expect(aggregateWriter.addCount(1), true)
        @Expect(aggregateWriter.addCount(1), false)
        @Expect(aggregateWriter.result().isNone(), true)

        let aggregateReader = SourceCacheReader("1:21:1".toArray(), maxItems: 2)
        @Expect(aggregateReader.nextCount(), 2)
        @ExpectThrows[IllegalArgumentException](aggregateReader.nextCount())

        let defaultSignature =
            "public func sample(required: Int64, count!: Int64 = 40  + /*note*/ 2, " +
            "label!: String = \"cjdoc\"): Unit"
        let exactDefaults = SourceDeclaration("exact-defaults", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        exactDefaults.parameters.add(SourceParameter("required", "Int64"))
        exactDefaults.parameters.add(SourceParameter("count", "Int64",
            defaultExpression: Some("40 + 2")))
        exactDefaults.parameters.add(SourceParameter("label", "String",
            defaultExpression: Some("\"cjdoc\"")))
        validateCachedParameterDefaults(exactDefaults)

        let swappedDefaults = SourceDeclaration("swapped-defaults", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        swappedDefaults.parameters.add(SourceParameter("required", "Int64"))
        swappedDefaults.parameters.add(SourceParameter("count", "Int64",
            defaultExpression: Some("\"cjdoc\"")))
        swappedDefaults.parameters.add(SourceParameter("label", "String",
            defaultExpression: Some("40 + 2")))
        @ExpectThrows[IllegalArgumentException](validateCachedParameterDefaults(swappedDefaults))

        let missingDefault = SourceDeclaration("missing-default", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        missingDefault.parameters.add(SourceParameter("required", "Int64"))
        missingDefault.parameters.add(SourceParameter("count", "Int64"))
        missingDefault.parameters.add(SourceParameter("label", "String",
            defaultExpression: Some("\"cjdoc\"")))
        @ExpectThrows[IllegalArgumentException](validateCachedParameterDefaults(missingDefault))

        let missingParameters = SourceDeclaration("missing-parameters", "function", "sample",
            "pkg", "module", "public", SourceLocation("src/api.cj", 1, 1, 1, 1),
            defaultSignature)
        @ExpectThrows[IllegalArgumentException](validateCachedParameterDefaults(missingParameters))

        let captured = CapturedSourceIndex("a\nβ")
        @Expect(captured.available, true)
        @Expect(captured.byteOffset(1, 1), Some(0))
        @Expect(captured.byteOffset(1, 2), Some(1))
        @Expect(captured.byteOffset(1, 3), None)
        @Expect(captured.byteOffset(2, 1), Some(2))
        @Expect(captured.byteOffset(2, 3), Some(4))
        @Expect(captured.byteOffset(2, 4), None)
        @Expect(captured.positionMatches(2, 3, 4), true)
        @Expect(captured.positionMatches(2, 3, 3), false)
        @Expect(sourceCacheLocationMatchesCaptured(
            SourceLocation("src/api.cj", 1, 1, 2, 3), "src/api.cj", captured), true)
        @Expect(sourceCacheLocationMatchesCaptured(
            SourceLocation("src/api.cj", 1, 1, 2, 4), "src/api.cj", captured), false)
        @Expect(sourceCacheLocationMatchesCaptured(
            SourceLocation("src/other.cj", 1, 1, 2, 3), "src/api.cj", captured), false)

        let tooManyLines = CapturedSourceIndex("a\nb\nc", maxLines: 2)
        @Expect(tooManyLines.available, false)
        @Expect(tooManyLines.byteOffset(1, 1), None)

        let owner = SourceDeclaration("owner", "class", "Owner", "pkg", "module",
            "public", SourceLocation("src/api.cj", 1, 1, 3, 2), "public class Owner",
            isContainer: true)
        let child = SourceDeclaration("child", "function", "child", "pkg", "module",
            "public", SourceLocation("src/api.cj", 2, 1, 2, 22),
            "public func child(): Unit")
        child.ownerSourceKey = Some(owner.sourceKey)
        let ownerGraph = ArrayList<SourceDeclaration>()
        ownerGraph.add(owner)
        ownerGraph.add(child)
        validateSourceCacheOwnerGraph(ownerGraph, maxDepth: 2)
        @ExpectThrows[IllegalArgumentException](
            validateSourceCacheOwnerGraph(ownerGraph, maxDepth: 1))
        owner.ownerSourceKey = Some(child.sourceKey)
        @ExpectThrows[IllegalArgumentException](validateSourceCacheOwnerGraph(ownerGraph))
    }

    @TestCase
    func discoversCommentedManifestHeadersThroughPublicApi(): Unit {
        let documentation = generateFixture("manifest_headers",
            includePathDependencies: true, includeCachedDependencies: true,
            cjpmCacheRoot: Some("tests/fixtures/cjpm_cache"))
        @Expect(documentation.status, "complete")
        @Expect(documentation.project.name, "manifest_headers")
        @Expect(documentation.modules.size, 5)
        for (name in ["rootApi", "memberApi", "pathApi", "cachedApi", "transitiveApi"]) {
            @Expect(declarationNamed(documentation, name).documentation.isSome(), true)
        }
        @Expect(documentation.diagnostics.size, 0)
    }

    @TestCase
    func reportsLintWithoutDroppingDeclarations(): Unit {
        let documentation = generateFixture("lint", lintProfile: "standard")
        @Expect(documentation.declarations.size, 3)
        @Expect(documentation.status, "complete")
        for (code in ["CJDOC3001", "CJDOC3002", "CJDOC3003", "CJDOC3005", "CJDOC3008"]) {
            @Expect(containsDiagnostic(documentation, code), true)
        }
    }

    @TestCase
    func unsupportedAndBrokenSourcesProducePartialIr(): Unit {
        let unsupported = generateFixture("unsupported")
        @Expect(unsupported.status, "partial")
        @Expect(unsupported.unsupportedDeclarations.size, 1)
        @Expect(containsDiagnostic(unsupported, "CJDOC1009"), true)

        let recovery = generateFixture("recovery")
        @Expect(recovery.status, "partial")
        @Expect(recovery.declarations.size, 1)
        @Expect(containsDiagnostic(recovery, "CJDOC1011"), true)
    }

    @TestCase
    func recordsFrontendGapsWithoutTraversingFunctionBodies(): Unit {
        let documentation = generateFixture("frontend_gaps")
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 1)
        @Expect(documentation.declarations[0].name, "outer")
        @Expect(documentation.declarations[0].documentation.isSome())
        @Expect(documentation.orphanDocComments.size, 2)
        @Expect(documentation.macroInvocations.size, 1)
        @Expect(documentation.macroInvocations[0].name, "missing.Generate")
        @Expect(documentation.unsupportedDeclarations.size, 1)
        @Expect(containsDiagnostic(documentation, "CJDOC1009"), true)
        @Expect(containsDiagnostic(documentation, "CJDOC1014"), true)
    }

    @TestCase
    func rejectsChecksumTamperingAndOversizedSourceCacheEntries(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let cache = temporary.join("cache")
            Directory.create(cache)
            let provider = AstSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("source-cache-contract-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT)
            let first = provider.collect(FIXTURES + "basic")
            @Expect(first.declarations.size, 25)
            @Expect(provider.cacheStats.writes, 1)
            let entries = Directory.readFrom(cache)
            @Expect(entries.size, 1)
            let cachePath = entries[0].path
            let corrupted = File.readFrom(cachePath)
            let last = corrupted.size - 1
            corrupted[last] = if (corrupted[last] == b'0') { b'1' } else { b'0' }
            File.writeTo(cachePath, corrupted)

            let reparsed = provider.collect(FIXTURES + "basic")
            @Expect(reparsed.declarations.size, 25)
            @Expect(provider.cacheStats.hits, 0)
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)

            let oversizedEntry = File(cachePath, OpenMode.ReadWrite)
            try {
                oversizedEntry.setLength(64 * 1024 * 1024 + 1)
            } finally {
                oversizedEntry.close()
            }
            let oversized = provider.collect(FIXTURES + "basic")
            @Expect(oversized.declarations.size, 25)
            @Expect(provider.cacheStats.hits, 0)
            @Expect(provider.cacheStats.corruptEntries, 1)
            @Expect(provider.cacheStats.writes, 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func rejectsOversizedManifestAndSourceThroughPublicApi(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let manifestRoot = temporary.join("manifest")
            Directory.create(manifestRoot.join("src"), recursive: true)
            File.writeTo(manifestRoot.join("cjpm.toml"),
                Array<Byte>(32 * 1024 * 1024 + 1, repeat: b' '))
            let manifestResult = DocumentationEngine().generate(GenerationRequest(
                manifestRoot.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(manifestResult.status, "partial")
            @Expect(containsDiagnostic(manifestResult, "CJDOC1010"), true)
            for (diagnostic in manifestResult.diagnostics) {
                @Expect(diagnostic.message.contains(temporary.toString()), false)
            }

            let sourceRoot = temporary.join("source")
            Directory.create(sourceRoot.join("src"), recursive: true)
            File.writeTo(sourceRoot.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "oversized_source"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(sourceRoot.join("src/api.cj"),
                Array<Byte>(32 * 1024 * 1024 + 1, repeat: b' '))
            let sourceResult = DocumentationEngine().generate(GenerationRequest(
                sourceRoot.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(sourceResult.status, "partial")
            @Expect(containsDiagnostic(sourceResult, "CJDOC1026"), true)
            for (diagnostic in sourceResult.diagnostics) {
                @Expect(diagnostic.message.contains(temporary.toString()), false)
                if (diagnostic.code == "CJDOC1026") {
                    let range = diagnostic.source.getOrThrow()
                    @Expect(range.start.byteOffset, 0)
                    @Expect(range.end.byteOffset, 0)
                }
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func publicEngineFailsClosedWithoutParserWorker(): Unit {
        let documentation = DocumentationEngine().generate(GenerationRequest(
            FIXTURES + "basic", lintProfile: "off", audience: "all"))
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(containsDiagnostic(documentation, "CJDOC1020"), true)
    }

    @TestCase
    func scansWorkspaceAndOptInPathDependencies(): Unit {
        let workspace = generateFixture("workspace")
        @Expect(workspace.modules.size, 2)
        @Expect(workspace.packages.size, 2)
        @Expect(workspace.declarations.size, 2)

        let dependencies = generateFixture("path_dependencies", includePathDependencies: true)
        @Expect(dependencies.modules.size, 3)
        @Expect(dependencies.packages.size, 3)
        @Expect(dependencies.declarations.size, 3)
        @Expect(dependencies.diagnostics.size, 0)
        @Expect(declarationNamed(dependencies, "alphaApi").source.start.byteOffset > 0, true)
        @Expect(declarationNamed(dependencies, "betaApi").source.start.byteOffset > 0, true)
    }

    @TestCase
    func honorsCustomSourceDirectoriesAcrossEveryModuleDiscoveryPath(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("custom-source-roots")
            let explicit = temporary.join("explicit")
            let cache = temporary.join("cjpm-cache")
            Directory.create(root.join("code/root"), recursive: true)
            Directory.create(root.join("member/member-code"), recursive: true)
            Directory.create(root.join("dep/lib"), recursive: true)
            Directory.create(explicit.join("generated"), recursive: true)
            Directory.create(cache.join("git/cached/abc123/cache-code"), recursive: true)

            File.writeTo(root.join("cjpm.toml"), """
                package.name = "custom_root"
                package.src-dir = "code/root"

                [workspace]
                members = ["member"]

                [dependencies.dep]
                path = "dep"
                """.toArray())
            File.writeTo(root.join("cjpm.lock"), """
                [requires]
                cached = { git = "https://example.invalid/cached.git", commitId = "abc123" }
                """.toArray())
            File.writeTo(root.join("member/cjpm.toml"), """
                [package]
                name = "custom_member"
                src-dir = "member-code"
                """.toArray())
            File.writeTo(root.join("dep/cjpm.toml"), """
                [package]
                name = "custom_dep"
                src-dir = "lib"
                """.toArray())
            File.writeTo(explicit.join("cjpm.toml"), """
                [package]
                name = "custom_explicit"
                src-dir = "generated"
                """.toArray())
            File.writeTo(cache.join("git/cached/abc123/cjpm.toml"), """
                [package]
                name = "custom_cached"
                src-dir = "cache-code"
                """.toArray())
            File.writeTo(root.join("code/root/root.cj"),
                "package custom_root\npublic func rootCustom(): Unit {}\n".toArray())
            File.writeTo(root.join("member/member-code/member.cj"),
                "package custom_member\npublic func memberCustom(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/lib/dep.cj"),
                "package custom_dep\npublic func pathCustom(): Unit {}\n".toArray())
            File.writeTo(explicit.join("generated/explicit.cj"),
                "package custom_explicit\npublic func explicitCustom(): Unit {}\n".toArray())
            File.writeTo(cache.join("git/cached/abc123/cache-code/cached.cj"),
                "package custom_cached\npublic func cachedCustom(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, includeCachedDependencies: true,
                dependencySources: [DependencySourceInput("explicit", explicit.toString())],
                cjpmCacheRoot: Some(cache.toString()), astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "complete")
            @Expect(documentation.modules.size, 5)
            @Expect(declarationNamed(documentation, "rootCustom").source.path,
                "code/root/root.cj")
            @Expect(declarationNamed(documentation, "memberCustom").source.path,
                "member/member-code/member.cj")
            @Expect(declarationNamed(documentation, "pathCustom").source.path,
                "dependencies/custom_dep/lib/dep.cj")
            @Expect(declarationNamed(documentation, "explicitCustom").source.path,
                "dependencies/explicit/generated/explicit.cj")
            @Expect(declarationNamed(documentation, "cachedCustom").source.path,
                "dependencies/cached/cache-code/cached.cj")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func attachesPureWorkspaceRootPathDependenciesToMembers(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("pure-workspace")
            Directory.create(root.join("member/src"), recursive: true)
            Directory.create(root.join("shared/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [workspace]
                members = ["member"]

                [dependencies.shared]
                path = "shared"
                """.toArray())
            File.writeTo(root.join("member/cjpm.toml"),
                "[package]\nname = \"workspace_member\"\n".toArray())
            File.writeTo(root.join("shared/cjpm.toml"),
                "[package]\nname = \"workspace_shared\"\n".toArray())
            File.writeTo(root.join("member/src/member.cj"),
                "package workspace_member\npublic func memberApi(): Unit {}\n".toArray())
            File.writeTo(root.join("shared/src/shared.cj"),
                "package workspace_shared\npublic func sharedApi(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "complete")
            @Expect(documentation.modules.size, 2)
            @Expect(documentation.declarations.size, 2)
            var workspaceEdges: Int64 = -1
            for (module in documentation.modules) {
                if (module.role == "workspace") { workspaceEdges = module.dependencyIds.size }
            }
            @Expect(workspaceEdges, 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func selectsCurrentTargetDependenciesAndMarksUnsupportedProfilesPartial(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let target = testCjpmTarget()
            let root = temporary.join("target-dependencies")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("dep/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), ("""
                [package]
                name = "target_root"

                [target.${target}.dependencies.dep]
                path = "dep"
                """).toArray())
            File.writeTo(root.join("dep/cjpm.toml"),
                "[package]\nname = \"target_dep\"\n".toArray())
            File.writeTo(root.join("src/root.cj"),
                "package target_root\npublic func targetRoot(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/dep.cj"),
                "package target_dep\npublic func selectedTargetDep(): Unit {}\n".toArray())

            let selected = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(selected.status, "complete")
            @Expect(selected.modules.size, 2)
            @Expect(declarationNamed(selected, "selectedTargetDep").kind, "function")

            File.writeTo(root.join("cjpm.toml"), ("""
                [package]
                name = "target_root"

                [target.${target}.debug.dependencies.dep]
                path = "dep"
                """).toArray())
            let profileSpecific = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(profileSpecific.status, "partial")
            @Expect(profileSpecific.modules.size, 1)
            @Expect(profileSpecific.declarations.size, 1)
            @Expect(containsDiagnostic(profileSpecific, "CJDOC1016"), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func rejectsDriveLikePackageSourceDirectoriesBeforeHostPathResolution(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("drive-like-source")
            Directory.create(root.join("src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                package.name = "drive_like_source"
                package.src-dir = "C:/source"
                """.toArray())
            File.writeTo(root.join("src/must_not_scan.cj"),
                "package drive_like_source\npublic func mustNotScan(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "partial")
            @Expect(documentation.modules.size, 1)
            @Expect(documentation.declarations.size, 0)
            @Expect(containsDiagnostic(documentation, "CJDOC1010"), true)
            @Expect(relativePathFromResolved("/project",
                "/project/C:/source/api.cj").isNone(), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func keepsRootWhenWorkspaceMemberIsBadAndScansSrcTarget(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("root")
            Directory.create(root.join("src/target"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "root_kept"
                version = "0.1.0"
                output-type = "static"

                [workspace]
                members = ["missing"]
                """.toArray())
            File.writeTo(root.join("src/root.cj"), """
                package root_kept

                public func rootApi(): Unit {}
                """.toArray())
            File.writeTo(root.join("src/target/kept.cj"), """
                package root_kept

                public func targetApi(): Unit {}
                """.toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "partial")
            @Expect(containsDiagnostic(documentation, "CJDOC1010"), true)
            @Expect(documentation.modules.size, 1)
            @Expect(documentation.declarations.size, 2)
            @Expect(declarationNamed(documentation, "rootApi").kind, "function")
            @Expect(declarationNamed(documentation, "targetApi").kind, "function")
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func skipsSelfAndCyclicDependencyEdgesAsPartialSource(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("cycle")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("dep/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "cycle_root"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                self = { path = "." }
                dep = { path = "dep" }
                """.toArray())
            File.writeTo(root.join("dep/cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "cycle_dep"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                root = { path = ".." }
                """.toArray())
            File.writeTo(root.join("src/root.cj"),
                "package cycle_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/dep.cj"),
                "package cycle_dep\npublic func depApi(): Unit {}\n".toArray())

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(documentation.status, "partial")
            @Expect(diagnosticCount(documentation, "CJDOC1016"), 1)
            @Expect(documentation.modules.size, 2)
            @Expect(documentation.declarations.size, 2)
            var rootEdges: Int64 = -1
            var dependencyEdges: Int64 = -1
            for (module in documentation.modules) {
                if (module.role == "root") { rootEdges = module.dependencyIds.size }
                if (module.role == "pathDependency") {
                    dependencyEdges = module.dependencyIds.size
                }
            }
            @Expect(rootEdges, 1)
            @Expect(dependencyEdges, 0)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func failsClosedOnModuleAndLogicalPathCollisions(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let nested = temporary.join("nested")
            Directory.create(nested.join("src/member/src"), recursive: true)
            File.writeTo(nested.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "nested_root"
                version = "0.1.0"
                output-type = "static"

                [workspace]
                members = ["src/member"]
                """.toArray())
            File.writeTo(nested.join("src/member/cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "nested_member"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(nested.join("src/root.cj"),
                "package nested_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(nested.join("src/member/src/member.cj"),
                "package nested_member\npublic func memberApi(): Unit {}\n".toArray())

            let nestedResult = DocumentationEngine().generate(GenerationRequest(
                nested.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(nestedResult.status, "partial")
            @Expect(containsDiagnostic(nestedResult, "CJDOC1010"), true)
            @Expect(nestedResult.modules.size, 1)
            @Expect(nestedResult.declarations.size, 0)

            let duplicate = temporary.join("duplicate")
            Directory.create(duplicate.join("src"), recursive: true)
            Directory.create(duplicate.join("deps/a/src"), recursive: true)
            Directory.create(duplicate.join("deps/b/src"), recursive: true)
            File.writeTo(duplicate.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "duplicate_root"
                version = "0.1.0"
                output-type = "static"

                [dependencies]
                a = { path = "deps/a" }
                b = { path = "deps/b" }
                """.toArray())
            for (name in ["a", "b"]) {
                File.writeTo(duplicate.join("deps/${name}/cjpm.toml"), """
                    [package]
                    cjc-version = "1.1.0"
                    name = "duplicate_dep"
                    version = "0.1.0"
                    output-type = "static"
                    """.toArray())
                File.writeTo(duplicate.join("deps/${name}/src/api.cj"),
                    "package duplicate_dep\npublic func ${name}Api(): Unit {}\n".toArray())
            }
            File.writeTo(duplicate.join("src/root.cj"),
                "package duplicate_root\npublic func rootApi(): Unit {}\n".toArray())
            let duplicateResult = DocumentationEngine().generate(GenerationRequest(
                duplicate.toString(), lintProfile: "off", audience: "all",
                includePathDependencies: true, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(duplicateResult.status, "partial")
            @Expect(containsDiagnostic(duplicateResult, "CJDOC1016"), true)
            @Expect(duplicateResult.modules.size, 2)
            @Expect(duplicateResult.declarations.size, 2)

            @Expect(relativePathFromResolved("/project",
                "/project/src/a\\b.cj").isNone(), true)
            @Expect(relativePathFromResolved("/project\\root",
                "/project\\root/src/a.cj"), Some("src/a.cj"))
            @Expect(relativePathFromResolved("/", "/src/a.cj"), Some("src/a.cj"))
            @Expect(relativePathFromResolved("C:\\project",
                "C:\\project\\src\\a.cj"), Some("src/a.cj"))

            let posix = temporary.join("posix-backslash")
            Directory.create(posix.join("src/a"), recursive: true)
            if (canonicalize(posix).toString().startsWith("/")) {
                File.writeTo(posix.join("cjpm.toml"), """
                    [package]
                    cjc-version = "1.1.0"
                    name = "posix_backslash"
                    version = "0.1.0"
                    output-type = "static"
                    """.toArray())
                File.writeTo(posix.join("src/a/b.cj"),
                    "package posix_backslash\npublic func slashApi(): Unit {}\n".toArray())
                File.writeTo(Path(posix.join("src").toString() + "/a\\b.cj"),
                    "package posix_backslash\npublic func backslashApi(): Unit {}\n".toArray())
                let posixResult = DocumentationEngine().generate(GenerationRequest(
                    posix.toString(), lintProfile: "off", audience: "all",
                    astPreflightExecutable: TEST_AST_PREFLIGHT))
                @Expect(posixResult.status, "partial")
                @Expect(containsDiagnostic(posixResult, "CJDOC1010"), true)
                @Expect(posixResult.modules.size, 1)
                @Expect(posixResult.declarations.size, 0)
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func sharesDirectoryEntryBudgetAcrossWorkspaceModules(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("bounded")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("member/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "bounded_root"
                version = "0.1.0"
                output-type = "static"

                [workspace]
                members = ["member"]
                """.toArray())
            File.writeTo(root.join("member/cjpm.toml"), """
                [package]
                cjc-version = "1.1.0"
                name = "bounded_member"
                version = "0.1.0"
                output-type = "static"
                """.toArray())
            File.writeTo(root.join("src/root.cj"),
                "package bounded_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("member/src/member.cj"),
                "package bounded_member\npublic func memberApi(): Unit {}\n".toArray())

            let snapshot = AstSourceProvider(astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceDirectoryEntryLimit: 1).collect(root.toString())
            var limitDiagnostics: Int64 = 0
            for (diagnostic in snapshot.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { limitDiagnostics++ }
            }
            @Expect(limitDiagnostics, 1)
            @Expect(snapshot.modules.size, 2)
            @Expect(snapshot.declarations.size, 0)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func discoversUnicodeWorkspaceAndPathMetadataAndRejectsInvalidEscapes(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("unicode")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("成员/src"), recursive: true)
            Directory.create(root.join("依赖/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), (
                "[package]\nname = \"unicode_root\"\n" +
                "[workspace]\nmembers = [\"成\\u5458\"]\n" +
                "[dependencies]\ndep = { path = \"依\\u8d56\" }\n").toArray())
            File.writeTo(root.join("成员/cjpm.toml"),
                "[package]\nname = \"member_pkg\"\n".toArray())
            File.writeTo(root.join("依赖/cjpm.toml"),
                "[package]\nname = \"dep_pkg\"\n".toArray())
            File.writeTo(root.join("src/root.cj"),
                "package unicode_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("成员/src/member.cj"),
                "package member_pkg\npublic func memberApi(): Unit {}\n".toArray())
            File.writeTo(root.join("依赖/src/dep.cj"),
                "package dep_pkg\npublic func depApi(): Unit {}\n".toArray())

            let generated = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", includePathDependencies: true,
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(generated.status, "complete")
            @Expect(generated.modules.size, 3)
            @Expect(declarationNamed(generated, "memberApi").packageName, "member_pkg")
            @Expect(declarationNamed(generated, "depApi").packageName, "dep_pkg")

            let invalidRoot = temporary.join("invalid")
            Directory.create(invalidRoot.join("src"), recursive: true)
            File.writeTo(invalidRoot.join("cjpm.toml"),
                "[package]\nname = \"bad\\q\"\n".toArray())
            File.writeTo(invalidRoot.join("src/api.cj"),
                "package invalid\npublic func mustNotParse(): Unit {}\n".toArray())
            let invalid = DocumentationEngine().generate(GenerationRequest(
                invalidRoot.toString(), lintProfile: "off", audience: "all",
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(invalid.status, "partial")
            @Expect(invalid.modules.size, 1)
            @Expect(invalid.declarations.size, 0)
            @Expect(diagnosticCount(invalid, "CJDOC1010"), 1)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func auxiliaryBudgetFailsClosedOnceAcrossMetadataAndCacheWork(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("bounded-auxiliary")
            let cache = temporary.join("cache")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(cache)
            let manifest = "[package]\nname = \"bounded_auxiliary\"\n"
            File.writeTo(root.join("cjpm.toml"), manifest.toArray())
            File.writeTo(root.join("src/api.cj"),
                "package bounded_auxiliary\npublic func api(): Unit {}\n".toArray())

            let metadataLimited = AstSourceProvider(astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceAuxiliaryByteLimit: manifest.size - 1).collect(root.toString())
            @Expect(metadataLimited.modules.size, 1)
            @Expect(metadataLimited.declarations.size, 0)
            var metadataLimits: Int64 = 0
            for (diagnostic in metadataLimited.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { metadataLimits++ }
            }
            @Expect(metadataLimits, 1)

            let workLimited = AstSourceProvider(astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceAuxiliaryWorkLimit: manifest.size).collect(root.toString())
            @Expect(workLimited.modules.size, 1)
            @Expect(workLimited.declarations.size, 0)
            var workLimits: Int64 = 0
            for (diagnostic in workLimited.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { workLimits++ }
            }
            @Expect(workLimits, 1)

            let cacheLimited = AstSourceProvider(cacheDirectory: Some(cache.toString()),
                cacheFingerprint: Some("bounded-cache-work-v1"),
                astPreflightExecutable: TEST_AST_PREFLIGHT,
                sourceAuxiliaryByteLimit: manifest.size + 1).collect(root.toString())
            @Expect(cacheLimited.declarations.size, 1)
            var cacheLimits: Int64 = 0
            for (diagnostic in cacheLimited.diagnostics) {
                if (diagnostic.code == "CJDOC1028") { cacheLimits++ }
            }
            @Expect(cacheLimits, 1)
            @Expect(Directory.readFrom(cache).size, 0)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func headerlessDependencyUsesItsModuleNameForSerialAndParallelJobs(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("headerless")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(root.join("dep/src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"), (
                "[package]\nname = \"headerless_root\"\n" +
                "[dependencies]\ndep = { path = \"dep\" }\n").toArray())
            File.writeTo(root.join("dep/cjpm.toml"),
                "[package]\nname = \"dep_module\"\n".toArray())
            File.writeTo(root.join("src/root.cj"),
                "package headerless_root\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/one.cj"),
                "public func headerlessOne(): Unit {}\n".toArray())
            File.writeTo(root.join("dep/src/two.cj"),
                "public func headerlessTwo(): Unit {}\n".toArray())

            let serial = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", includePathDependencies: true,
                jobs: 1, astPreflightExecutable: TEST_AST_PREFLIGHT))
            let parallel = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", audience: "all", includePathDependencies: true,
                jobs: 4, astPreflightExecutable: TEST_AST_PREFLIGHT))
            @Expect(serial.status, "complete")
            @Expect(declarationNamed(serial, "headerlessOne").packageName, "dep_module")
            @Expect(declarationNamed(serial, "headerlessTwo").packageName, "dep_module")
            @Expect(api_render.encodeDocIr(parallel), api_render.encodeDocIr(serial))
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func punctuationDoesNotTriggerBinaryDepthGuard(): Unit {
        let punctuation = generateFixture("binary_punctuation")
        @Expect(punctuation.status, "complete")
        @Expect(containsDiagnostic(punctuation, "CJDOC1012"), false)
        @Expect(declarationNamed(punctuation, "ManyCases").kind, "enum")
        @Expect(declarationNamed(punctuation, "Nested").kind, "typeAlias")

        let expression = generateFixture("deep_binary")
        @Expect(expression.status, "partial")
        @Expect(containsDiagnostic(expression, "CJDOC1012"), true)
    }

    @TestCase
    func dependencyLogicalNamesAreValidatedBeforePathConstruction(): Unit {
        @ExpectThrows[IllegalArgumentException](DependencySourceInput("../escape",
            FIXTURES + "types"))
        @ExpectThrows[IllegalArgumentException](DependencySourceInput("bad/name",
            FIXTURES + "types"))

        let documentation = generateFixture("basic", dependencySources: [
            DependencySourceInput("vendor.types", FIXTURES + "types")])
        @Expect(documentation.status, "complete")
        @Expect(documentation.modules.size, 2)
        @Expect(declarationNamed(documentation, "State").source.path.startsWith(
            "dependencies/vendor.types/"), true)
    }

    @TestCase
    func explicitCfgSelectsOneConditionalBranch(): Unit {
        let documentation = generateFixture("conditional",
            cfgValues: [CfgValue("os", "Linux")])
        @Expect(documentation.declarations.size, 1)
        @Expect(documentation.declarations[0].name, "platformName")
        @Expect(documentation.declarations[0].headerSpelling.contains("linux"), false)
        @Expect(documentation.diagnostics.size, 0)
    }

    @TestCase
    func missingCfgOmitsConditionalDeclarationsExplicitly(): Unit {
        let documentation = generateFixture("conditional")
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(documentation.unsupportedDeclarations.size, 2)
        @Expect(containsDiagnostic(documentation, "CJDOC1019"), true)
    }

    @TestCase
    func rejectsConflictingCfgFactsAndDeduplicatesIdenticalFacts(): Unit {
        @Expect(isExactWhenAnnotation("@When[os == \"Linux\"]"), true)
        @Expect(isExactWhenAnnotation("  @When [os == \"Linux\"]  "), true)
        @Expect(isExactWhenAnnotation("@Whenever[os == \"Linux\"]"), false)
        @Expect(isExactWhenAnnotation("@WhenEnabled[os == \"Linux\"]"), false)

        @ExpectThrows[IllegalArgumentException](GenerationRequest(FIXTURES + "conditional",
            cfgValues: [CfgValue("os", "Linux"), CfgValue("os", "Windows")]))
        @ExpectThrows[IllegalArgumentException](GenerationRequest(FIXTURES + "conditional",
            cfgValues: [CfgValue("os", "Windows"), CfgValue("os", "Linux")]))

        let single = generateFixture("conditional", cfgValues: [CfgValue("os", "Linux")])
        let duplicate = generateFixture("conditional",
            cfgValues: [CfgValue("os", "Linux"), CfgValue("os", "Linux")])
        @Expect(api_render.encodeDocIr(duplicate), api_render.encodeDocIr(single))
    }

    @TestCase
    func excludedCfgOwnersSuppressChildEvaluationAndFalseDominatesUnknown(): Unit {
        let selected = generateFixture("cfg_owner",
            cfgValues: [CfgValue("os", "Linux"), CfgValue("docs", "false")])
        @Expect(selected.status, "complete")
        @Expect(selected.declarations.size, 0)
        @Expect(selected.unsupportedDeclarations.size, 0)
        @Expect(containsDiagnostic(selected, "CJDOC1019"), false)

        let unresolvedOwner = generateFixture("cfg_owner",
            cfgValues: [CfgValue("docs", "false")])
        @Expect(unresolvedOwner.status, "partial")
        @Expect(unresolvedOwner.declarations.size, 0)
        @Expect(unresolvedOwner.unsupportedDeclarations.size, 1)
        @Expect(unresolvedOwner.unsupportedDeclarations[0].name, "WindowsOnly")
        @Expect(diagnosticCount(unresolvedOwner, "CJDOC1019"), 1)
    }

    @TestCase
    func unresolvedCfgIsReportedAsUnsupportedSource(): Unit {
        let documentation = generateFixture("conditional",
            cfgValues: [CfgValue("arch", "x86_64")])
        @Expect(documentation.status, "partial")
        @Expect(documentation.declarations.size, 0)
        @Expect(documentation.unsupportedDeclarations.size, 2)
        @Expect(containsDiagnostic(documentation, "CJDOC1019"), true)
    }

    @TestCase
    func generationAndEncodingAreDeterministic(): Unit {
        let first = generateFixture("types", lintProfile: "standard")
        let second = generateFixture("types", lintProfile: "standard")
        @Expect(declarationNamed(first, "Idle").documentation.isSome(), true)
        @Expect(declarationNamed(first, "Failed").documentation.isSome(), true)
        let firstJson = api_render.encodeDocIr(first)
        @Expect(api_render.encodeDocIr(second), firstJson)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(firstJson)), firstJson)
        @Expect(!firstJson.contains("/home/"), true)
        @Expect(!firstJson.contains("/tmp/"), true)
    }
}

@When[os != "Windows"]
@Test
class CachedDependencyContainmentTest {
    @TestCase
    func rejectsCachedDependencySymlinkThatEscapesCanonicalCacheRoot(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("project")
            let cache = temporary.join("cache")
            let outside = temporary.join("outside-dependency")
            Directory.create(root.join("src"), recursive: true)
            Directory.create(cache.join("git/escaped"), recursive: true)
            Directory.create(outside.join("src"), recursive: true)
            File.writeTo(root.join("cjpm.toml"),
                "[package]\nname = \"cache_containment\"\n".toArray())
            File.writeTo(root.join("cjpm.lock"), """
                [requires]
                escaped = { git = "https://example.invalid/escaped.git", commitId = "abc123" }
                """.toArray())
            File.writeTo(root.join("src/root.cj"),
                "package cache_containment\npublic func rootApi(): Unit {}\n".toArray())
            File.writeTo(outside.join("cjpm.toml"),
                "[package]\nname = \"escaped\"\n".toArray())
            File.writeTo(outside.join("src/api.cj"),
                "package escaped\npublic func escapedApi(): Unit {}\n".toArray())
            @Expect(symlink(outside.toString(),
                cache.join("git/escaped/abc123").toString()), 0)

            let documentation = DocumentationEngine().generate(GenerationRequest(
                root.toString(), lintProfile: "off", audience: "all",
                includeCachedDependencies: true, cjpmCacheRoot: Some(cache.toString()),
                astPreflightExecutable: TEST_AST_PREFLIGHT))
            var escapedFound = false
            for (declaration in documentation.declarations) {
                if (declaration.name == "escapedApi") { escapedFound = true }
            }
            @Expect(escapedFound, false)
            @Expect(containsDiagnostic(documentation, "CJDOC1021"), true)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }
}
