package cjdoc

import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Linux"]
import std.posix.*

@Test
class PublicApiContractsSuite8 {
    @TestCase
    func genericBindingPositionsKeepOverloadsUniqueAndRenamesStable(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "generic_identity"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let sourcePath = temporary.join("src/api.cj")
            File.writeTo(sourcePath,
                """
                package generic_identity

                public class Box<T> {
                    public func pair<U>(outer: T, local: U): Unit {}
                }

                public func f<X, Y>(left: X, right: Y): Unit {}
                public func f<Y, X>(left: X, right: Y): Unit {}

                extend<E> Box<E> {
                    public func extensionValue(value: E): E { value }
                }
                """
                    .toArray())
            let before = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(before, "CJDOC2006"))
            let beforeIds = HashSet<String>()
            let overloadIds = HashSet<String>()
            var overloads: Int64 = 0
            var sawLexicalOwnerBindings = false
            var sawGenericExtendTarget = false
            for (declaration in before.declarations) {
                let _ = beforeIds.add(declaration.id)
                if (declaration.name == "f") {
                    overloads++
                    let _ = overloadIds.add(declaration.id)
                }
                if (declaration.name == "pair") {
                    @Expect(declaration.id.contains("@g0"))
                    @Expect(declaration.id.contains("@g1"))
                    sawLexicalOwnerBindings = true
                }
                if (declaration.kind == "extend" || declaration.name == "extensionValue") {
                    @Expect(declaration.id.contains("@g0"))
                    sawGenericExtendTarget = true
                }
            }
            @Expect(overloads, 2)
            @Expect(overloadIds.size, 2)
            @Expect(sawLexicalOwnerBindings)
            @Expect(sawGenericExtendTarget)
            @Expect(beforeIds.size, before.declarations.size)

            File.writeTo(sourcePath,
                """
                package generic_identity

                public class Box<OuterRenamed> {
                    public func pair<LocalRenamed>(outer: OuterRenamed,
                        local: LocalRenamed): Unit {}
                }

                public func f<First, Second>(left: First, right: Second): Unit {}
                public func f<Second, First>(left: First, right: Second): Unit {}

                extend<ExtensionRenamed> Box<ExtensionRenamed> {
                    public func extensionValue(value: ExtensionRenamed): ExtensionRenamed { value }
                }
                """
                    .toArray())
            let after = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(after, "CJDOC2006"))
            let afterIds = HashSet<String>()
            for (declaration in after.declarations) {
                let _ = afterIds.add(declaration.id)
            }
            @Expect(afterIds.size, beforeIds.size)
            for (id in beforeIds) {
                @Expect(afterIds.contains(id))
            }
            let encoded = api_render.encodeDocIr(after)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func extensionLocalPrivateAndEmptyBlocksHaveStableUniqueIdentities(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "extension_block_identity"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let sourcePath = temporary.join("src/api.cj")
            let compact = """
                package extension_block_identity

                public class Box<T> {
                    public init() {}
                }

                extend<T> Box<T> {
                    public func first(value: T): T { value }
                    private func hidden(value: T): T { value }
                }
                extend<U> Box<U> {
                    public func second(value: U): U { value }
                    private func hidden(value: U): U { value }
                }
                extend<V> Box<V> {}
                extend<W> Box<W> {}
                """
            File.writeTo(sourcePath, compact.toArray())
            let before = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off", audience: "all",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(before, "CJDOC2006"))
            let beforeIds = HashSet<String>()
            let extendIds = HashSet<String>()
            let referencedExtendIds = HashSet<String>()
            let hiddenIds = HashSet<String>()
            let hiddenOwnerIds = HashSet<String>()
            var extendCount: Int64 = 0
            var hiddenCount: Int64 = 0
            for (declaration in before.declarations) {
                let _ = beforeIds.add(declaration.id)
                if (declaration.kind == "extend") {
                    extendCount++
                    let _ = extendIds.add(declaration.id)
                }
                if (let Some(ownerId) <- declaration.ownerId) {
                    let _ = referencedExtendIds.add(ownerId)
                }
                if (declaration.name == "hidden") {
                    hiddenCount++
                    let _ = hiddenIds.add(declaration.id)
                    @Expect(declaration.id.contains("extension-block"))
                    @Expect(declaration.ownerId.isSome())
                    let _ = hiddenOwnerIds.add(declaration.ownerId.getOrThrow())
                }
                if (declaration.name == "first" || declaration.name == "second") {
                    @Expect(!declaration.id.contains("extension-block"))
                }
            }
            @Expect(extendCount, 4)
            @Expect(extendIds.size, 4)
            @Expect(hiddenCount, 2)
            @Expect(hiddenIds.size, 2)
            @Expect(hiddenOwnerIds.size, 2)
            for (ownerId in hiddenOwnerIds) {
                @Expect(extendIds.contains(ownerId))
            }
            var emptyOwners: Int64 = 0
            for (extendId in extendIds) {
                if (!referencedExtendIds.contains(extendId)) {
                    emptyOwners++
                    @Expect(extendId.contains("extension-block"))
                }
            }
            @Expect(emptyOwners, 2)

            File.writeTo(sourcePath,
                compact
                    .replace("\nextend<U>", "\n\n\n\nextend<U>")
                    .replace("\nextend<V>", "\n\n\nextend<V>")
                    .replace("\nextend<W>", "\n\n\n\nextend<W>")
                    .toArray())
            let after = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off", audience: "all",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(after, "CJDOC2006"))
            let afterIds = HashSet<String>()
            for (declaration in after.declarations) {
                let _ = afterIds.add(declaration.id)
            }
            @Expect(afterIds.size, beforeIds.size)
            for (id in beforeIds) {
                @Expect(afterIds.contains(id))
            }
            let encoded = api_render.encodeDocIr(after)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func largeExtensionSetKeepsUniqueOwnerIdentities(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "identity_scale"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let source = StringBuilder()
            source.append("package identity_scale\n\n")
            source.append("public class Box<T> {\n    public init() {}\n}\n")
            var index: Int64 = 0
            while (index < 512) {
                source.append("\nextend Box<String> {\n")
                source.append("    public func member${index}(value: Int64): Int64 { value }\n")
                source.append("}\n")
                index++
            }
            File.writeTo(temporary.join("src/api.cj"), source.toString().toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2006"))
            let allIds = HashSet<String>()
            let extendIds = HashSet<String>()
            var extendCount: Int64 = 0
            var memberCount: Int64 = 0
            for (declaration in documentation.declarations) {
                let _ = allIds.add(declaration.id)
                if (declaration.kind == "extend") {
                    extendCount++
                    let _ = extendIds.add(declaration.id)
                }
                if (declaration.name.startsWith("member")) {
                    memberCount++
                }
            }
            @Expect(extendCount, 512)
            @Expect(extendIds.size, 512)
            @Expect(memberCount, 512)
            for (declaration in documentation.declarations) {
                if (!declaration.name.startsWith("member")) {
                    continue
                }
                @Expect(declaration.ownerId.isSome())
                @Expect(allIds.contains(declaration.ownerId.getOrThrow()))
                @Expect(declaration.qualifiedName,
                    "identity_scale.Box < String >.${declaration.name}")
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }
}
