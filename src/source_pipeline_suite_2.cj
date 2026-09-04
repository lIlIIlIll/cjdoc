package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*


@Test
class SourcePipelineSuite2 {
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
        @Expect(defaulted.parameters[0].defaultExpression, None<String>)
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
        @Expect(decodedDefaulted.parameters[0].defaultExpression, None<String>)
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


}
