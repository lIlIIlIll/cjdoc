package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private func metadataBindingProject(source: String): Path {
    let root = Directory.createTemp(getTempDirectory())
    Directory.create(root.join("src"))
    File.writeTo(root.join("cjpm.toml"), "[package]\nname = \"binding\"\nversion = \"0.1.0\"\n".toArray())
    File.writeTo(root.join("src/api.cj"), source.toArray())
    root
}

private func metadataBindingWriteSource(root: Path, source: String): Unit {
    File.writeTo(root.join("src/api.cj"), source.toArray())
}

private func metadataBindingWriteConfig(root: Path, config: String): Unit {
    File.writeTo(root.join("cjdoc.toml"), config.toArray())
}

private func metadataBindingGenerate(root: Path, cfgValues!: Array<CfgValue> = [],
    audience!: String = "external"): GeneratedDocumentation {
    let request = GenerationRequest(root.toString(), audience: audience, lintProfile: "off",
        cfgValues: cfgValues, astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT)
    generateDocumentationWithSource(request, defaultSemanticProvider())
}

private func metadataBindingDiagnosticCount(documentation: DocumentationSet, code: String): Int64 {
    var count: Int64 = 0
    for (diagnostic in documentation.diagnostics where diagnostic.code == code) { count++ }
    count
}

private func metadataBindingFindSymbol(documentation: DocumentationSet, name: String,
    kind!: ?String = None): SymbolDoc {
    for (symbol in documentation.symbols) {
        if (symbol.name == name && (kind.isNone() || Some(symbol.kind) == kind)) { return symbol }
    }
    throw IllegalStateException("expected metadata binding test declaration")
}

private func metadataBindingFirstExtend(documentation: DocumentationSet): SymbolDoc {
    var selected: ?SymbolDoc = None
    for (symbol in documentation.symbols where symbol.kind == "extend") {
        match (selected) {
            case Some(current) => if (symbol.source.startLine < current.source.startLine) {
                selected = Some(symbol)
            }
            case None => selected = Some(symbol)
        }
    }
    selected.getOrThrow()
}

private func metadataBindingContainsContainer(documentation: DocumentationSet,
    qualifiedName: String): Bool {
    for (container in documentation.metadataInventory.containers) {
        if (container.qualifiedName == qualifiedName) { return true }
    }
    false
}

@Test
class MetadataBindingContracts {
    @TestCase
    func configurationBindsBeforeCfgAndAudienceProjectionAndAcceptsDefinedShorthand(): Unit {
        let root = metadataBindingProject("""
            package binding
            @When[os == "Windows"]
            public class CfgOwner {
                public func hiddenByCfg(): Unit {}
            }
            public class AudienceOwner {
                /**
                 * @group audience-only
                 */
                internal func hiddenByAudience(): Unit {}
            }
            """)
        try {
            metadataBindingWriteConfig(root, """
                [[metadata.groups]]
                package = "binding"
                owner = "binding.CfgOwner"
                id = "cfg-only"
                title = "CFG only"
                [[metadata.groups]]
                package = "binding"
                owner = "binding.AudienceOwner"
                id = "audience-only"
                title = "Audience only"
                """)
            let generated = metadataBindingGenerate(root, cfgValues: [CfgValue("os", "Linux")])
            let internalDocumentation = generated.internalDocumentation
            @Expect(metadataBindingContainsContainer(internalDocumentation, "binding.CfgOwner"), true)
            @Expect(metadataBindingContainsContainer(internalDocumentation, "binding.AudienceOwner"), true)
            @Expect(metadataBindingFindSymbol(internalDocumentation, "hiddenByAudience").ownerId.isSome(), true)
            @Expect(internalDocumentation.metadata.groups.size, 1)
            @Expect(internalDocumentation.metadata.groups[0].id, "audience-only")
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3134"), 0)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3135"), 0)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3137"), 0)
            @Expect(generated.publicDocumentation.metadata.groups.size, 0)
            let directRequest = GenerationRequest(root.toString(), audience: "external", lintProfile: "off",
                cfgValues: [CfgValue("os", "Linux")], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT)
            let direct = DocumentationEngine().generate(directRequest)
            @Expect(publicHasDiagnostic(direct, "CJDOC3137"), false)
            @Expect(direct.metadata.groups.size, 0)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func exactOwnerIdSelectsAmbiguousExtendAndEmitsItsCurrentBinderId(): Unit {
        let initialSource = """
            package binding
            public class Widget {}
            extend Widget {
                @When[os == "Windows"]
                public func windowsOnly(): Unit {}
                public func live(): Unit {}
            }
            @When[os == "Windows"]
            extend Widget {
                public func windowsOwnerOnly(): Unit {}
            }
            """
        let root = metadataBindingProject(initialSource)
        try {
            let complete = metadataBindingGenerate(root, cfgValues: [CfgValue("os", "Windows")])
            let fullSourceOwner = metadataBindingFirstExtend(complete.internalDocumentation)
            var extendCount: Int64 = 0
            for (symbol in complete.internalDocumentation.symbols where symbol.kind == "extend") {
                extendCount++
                @Expect(symbol.qualifiedName, fullSourceOwner.qualifiedName)
            }
            @Expect(extendCount, 2)

            metadataBindingWriteSource(root, """
                package binding
                public class Widget {}
                extend Widget {
                    @When[os == "Windows"]
                    public func windowsOnly(): Unit {}
                    /**
                     * @group exact-owner
                     */
                    public func live(): Unit {}
                }
                @When[os == "Windows"]
                extend Widget {
                    public func windowsOwnerOnly(): Unit {}
                }
                """)
            metadataBindingWriteConfig(root,
                "[[metadata.groups]]\npackage = \"binding\"\nowner = \"${fullSourceOwner.qualifiedName}\"\n" +
                "id = \"ambiguous-name\"\ntitle = \"Name selector\"\n" +
                "[[metadata.groups]]\npackage = \"binding\"\nowner-id = \"${fullSourceOwner.id}\"\n" +
                "id = \"exact-owner\"\ntitle = \"Exact owner\"\n")

            let generated = metadataBindingGenerate(root, cfgValues: [CfgValue("os", "Linux")])
            let internalDocumentation = generated.internalDocumentation
            let live = metadataBindingFindSymbol(internalDocumentation, "live")
            let currentOwnerId = live.ownerId.getOrThrow()
            @Expect(currentOwnerId != fullSourceOwner.id, true)
            @Expect(internalDocumentation.metadata.groups.size, 1)
            @Expect(internalDocumentation.metadata.groups[0].id, "exact-owner")
            @Expect(internalDocumentation.metadata.groups[0].ownerId, Some(currentOwnerId))
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3135"), 1)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3134"), 0)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3137"), 0)
            var activeExtendCount: Int64 = 0
            for (symbol in internalDocumentation.symbols where symbol.kind == "extend") {
                activeExtendCount++
            }
            @Expect(activeExtendCount, 1)
            for (diagnostic in internalDocumentation.diagnostics where diagnostic.code == "CJDOC3135") {
                @Expect(diagnostic.symbolId.isNone(), true)
                @Expect(!diagnostic.message.contains(fullSourceOwner.qualifiedName), true)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func duplicateOwnerNameAndIdDefinitionsInvalidateEveryCompetitorAndKeep3131(): Unit {
        let root = metadataBindingProject(
            "package binding\npublic class Sibling {}\npublic class Owner {}\n")
        try {
            let baseline = metadataBindingGenerate(root)
            let sibling = metadataBindingFindSymbol(baseline.internalDocumentation, "Sibling",
                kind: Some("class"))
            let owner = metadataBindingFindSymbol(baseline.internalDocumentation, "Owner",
                kind: Some("class"))
            metadataBindingWriteSource(root, """
                package binding
                public class Sibling {}
                public class Owner {
                    /**
                     * @group duplicate
                     */
                    public func shorthand(): Unit {}
                    /**
                     * @group conflict First inline title
                     */
                    public func first(): Unit {}
                    /**
                     * @group conflict Second inline title
                     */
                    public func second(): Unit {}
                }
                """)
            metadataBindingWriteConfig(root,
                "[[metadata.groups]]\npackage = \"binding\"\nowner = \"${owner.qualifiedName}\"\n" +
                "id = \"duplicate\"\ntitle = \"Name competitor\"\n" +
                "[[metadata.groups]]\npackage = \"binding\"\nowner-id = \"${owner.id}\"\n" +
                "id = \"duplicate\"\ntitle = \"ID competitor\"\n" +
                "[[metadata.groups]]\npackage = \"binding\"\nowner = \"${owner.qualifiedName}\"\n" +
                "id = \"conflict\"\ntitle = \"Configured title\"\n" +
                "[[metadata.groups]]\npackage = \"binding\"\nowner-id = \"${sibling.id}\"\n" +
                "id = \"conflict\"\ntitle = \"Sibling title\"\n" +
                "[[metadata.tags]]\nid = \"shared\"\ntitle = \"First tag\"\n" +
                "[[metadata.tags]]\nid = \"shared\"\ntitle = \"Second tag\"\n")

            let generated = metadataBindingGenerate(root)
            let internalDocumentation = generated.internalDocumentation
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3136"), 4)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3137"), 1)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3131"), 1)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3130"), 0)
            @Expect(internalDocumentation.metadata.groups.size, 2)
            var ownerGroupFound = false
            var siblingGroupFound = false
            for (group in internalDocumentation.metadata.groups) {
                if (group.id == "conflict" && group.ownerId == Some(owner.id)) {
                    ownerGroupFound = true
                }
                if (group.id == "conflict" && group.ownerId == Some(sibling.id)) {
                    siblingGroupFound = true
                }
            }
            @Expect(ownerGroupFound, true)
            @Expect(siblingGroupFound, true)
            @Expect(internalDocumentation.metadata.tags.size, 0)
            @Expect(internalDocumentation.symbols.size > 1, true)
            @Expect(internalDocumentation.apiCollectionState, baseline.internalDocumentation.apiCollectionState)
            for (diagnostic in internalDocumentation.diagnostics where diagnostic.code == "CJDOC3136") {
                @Expect(diagnostic.symbolId.isNone(), true)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func missingPackageAndOwnerDiagnoseWithoutDroppingApiOrLeakingTargets(): Unit {
        let root = metadataBindingProject("package binding\npublic class Owner {}\n")
        try {
            let baseline = metadataBindingGenerate(root)
            let generatedBaseline = baseline.internalDocumentation
            metadataBindingWriteConfig(root,
                "[[metadata.groups]]\npackage = \"binding\"\nowner = \"binding.Missing\"\n" +
                "id = \"missing-owner\"\ntitle = \"Missing owner\"\n" +
                "[[metadata.groups]]\npackage = \"absent-package\"\nid = \"missing-package\"\n" +
                "title = \"Missing package\"\n")
            let generated = metadataBindingGenerate(root)
            let internalDocumentation = generated.internalDocumentation
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3134"), 2)
            @Expect(internalDocumentation.metadata.groups.size, 0)
            @Expect(internalDocumentation.symbols.size, generatedBaseline.symbols.size)
            @Expect(internalDocumentation.apiCollectionState, generatedBaseline.apiCollectionState)
            for (diagnostic in internalDocumentation.diagnostics where diagnostic.code == "CJDOC3134") {
                @Expect(diagnostic.symbolId.isNone(), true)
                @Expect(!diagnostic.message.contains("Missing"), true)
                @Expect(!diagnostic.message.contains("absent-package"), true)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func emptyModuleRootsLoadTheirOwnMetadataWithoutWorkspaceInheritance(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(root.join("src"))
            Directory.create(root.join("packages"))
            Directory.create(root.join("packages/empty"))
            Directory.create(root.join("packages/empty/src"))
            File.writeTo(root.join("cjpm.toml"), """
                [package]
                name = "metadata_root"
                version = "0.1.0"
                [workspace]
                members = ["packages/empty"]
                """.toArray())
            File.writeTo(root.join("packages/empty/cjpm.toml"),
                "[package]\nname = \"metadata_member\"\nversion = \"0.1.0\"\n".toArray())
            metadataBindingWriteConfig(root,
                "[[metadata.tags]]\nid = \"root-only\"\ntitle = \"Root\"\n" +
                "[[metadata.tags]]\nid = \"shared\"\ntitle = \"Root shared\"\n")
            metadataBindingWriteConfig(root.join("packages/empty"),
                "[[metadata.tags]]\nid = \"member-only\"\ntitle = \"Member\"\n" +
                "[[metadata.tags]]\nid = \"shared\"\ntitle = \"Member shared\"\n")

            let generated = metadataBindingGenerate(root)
            let internalDocumentation = generated.internalDocumentation
            @Expect(internalDocumentation.metadataInventory.moduleConfigurations.size, 2)
            @Expect(internalDocumentation.metadataInventory.containers.size, 0)
            @Expect(internalDocumentation.metadata.tags.size, 4)
            @Expect(metadataBindingDiagnosticCount(internalDocumentation, "CJDOC3136"), 0)
            var rootModuleId = ""
            var memberModuleId = ""
            for (module in internalDocumentation.modules) {
                if (module.role == "root") { rootModuleId = module.id }
                if (module.role == "workspace") { memberModuleId = module.id }
            }
            @Expect(rootModuleId.isEmpty(), false)
            @Expect(memberModuleId.isEmpty(), false)
            for (tag in internalDocumentation.metadata.tags) {
                if (tag.id == "root-only") { @Expect(tag.moduleId, rootModuleId) }
                if (tag.id == "member-only") { @Expect(tag.moduleId, memberModuleId) }
                if (tag.id == "shared" && tag.title == "Root shared") {
                    @Expect(tag.moduleId, rootModuleId)
                }
                if (tag.id == "shared" && tag.title == "Member shared") {
                    @Expect(tag.moduleId, memberModuleId)
                }
            }

            metadataBindingWriteConfig(root.join("packages/empty"),
                "[[metadata.tags]]\nid = \"malformed-empty-module\"\n")
            let error = @AssertThrows[IllegalArgumentException](metadataBindingGenerate(root))
            @Expect(error.message.contains("CJDOC3133"), true)
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }

    @TestCase
    func publicMetadataDiagnosticsRetainRootWorkspaceAndDependencyConfigOrigins(): Unit {
        let root = metadataBindingProject("package binding\npublic class Owner {}\n")
        try {
            Directory.create(root.join("packages"))
            let scopes = [
                ("", "binding", "cjdoc.toml"),
                ("packages/member", "binding_member", "packages/member/cjdoc.toml"),
                ("vendor", "binding_peer", "dependencies/peer/cjdoc.toml")
            ]
            for ((relative, packageName, _) in scopes) {
                let moduleRoot = if (relative.isEmpty()) { root } else { root.join(relative) }
                if (!relative.isEmpty()) {
                    Directory.create(moduleRoot)
                    Directory.create(moduleRoot.join("src"))
                }
                File.writeTo(moduleRoot.join("cjpm.toml"),
                    "[package]\nname = \"${packageName}\"\nversion = \"0.1.0\"\n".toArray())
                File.writeTo(moduleRoot.join("src/api.cj"),
                    "package ${packageName}\npublic class Owner {}\n".toArray())
                metadataBindingWriteConfig(moduleRoot,
                    "[[metadata.groups]]\npackage = \"${packageName}\"\n" +
                    "owner = \"${packageName}.Missing\"\nid = \"missing\"\ntitle = \"Missing\"\n" +
                    "[[metadata.tags]]\nid = \"duplicate\"\ntitle = \"First\"\n" +
                    "[[metadata.tags]]\nid = \"duplicate\"\ntitle = \"Second\"\n")
            }
            File.writeTo(root.join("cjpm.toml"),
                ("[package]\nname = \"binding\"\nversion = \"0.1.0\"\n" +
                "[workspace]\nmembers = [\"packages/member\"]\n").toArray())
            let documentation = DocumentationEngine().generate(GenerationRequest(root.toString(),
                lintProfile: "off", astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT,
                dependencySources: [DependencySourceInput("peer", root.join("vendor").toString())]))
            let locations = HashSet<String>()
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code != "CJDOC3134" && diagnostic.code != "CJDOC3136") { continue }
                let source = diagnostic.source.getOrThrow()
                let key = "${diagnostic.code}:${source.path}:${source.start.line}"
                @Expect(locations.add(key), true)
            }
            @Expect(locations.size, 9)
            for ((_, _, path) in scopes) {
                @Expect(locations.contains("CJDOC3134:${path}:1"), true)
                @Expect(locations.contains("CJDOC3136:${path}:6"), true)
                @Expect(locations.contains("CJDOC3136:${path}:9"), true)
            }
        } finally {
            let _ = removeIfExists(root, recursive: true)
        }
    }
}
