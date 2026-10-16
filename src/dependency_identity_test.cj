package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.fs.*
import std.env.*
import std.unittest.*
import std.unittest.testmacro.*

private func identityTestProject(root: Path, name: String): Unit {
    Directory.create(root.join("src"), recursive: true)
    File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"" + name + "\"\nversion = \"1.0.0\"\n").toArray())
    File.writeTo(root.join("src/api.cj"), ("package " + name + "\npublic func answer(): Int64 { 1 }\n").toArray())
}

private func identityTestGenerate(root: Path, receipt!: ?String = None,
    inputs!: Array<DependencySourceInput> = [], cfg!: Array<CfgValue> = []): api_model.DocumentationSet {
    DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off", buildContext: receipt,
        dependencySources: inputs, cfgValues: cfg))
}

private func identityTestDependency(documentation: api_model.DocumentationSet, name: String,
    kind!: String = "source", owner!: String = "cjdoc:module:v1:root"): api_model.DependencyInstance {
    for (dependency in documentation.dependencies) {
        if (dependency.moduleId == owner && dependency.name == name && dependency.kind == kind) { return dependency }
    }
    throw IllegalArgumentException("expected public dependency snapshot entry is missing")
}

private func identityTestReceipt(sourceIdentity: String, artifactIdentity: String): String {
    let jsonString = api_render.escapeJsonString
    "{\"schemaVersion\":\"cjdoc.build-context/1\",\"project\":{\"path\":\".\",\"identity\":" + jsonString(sourceIdentity) +
    "},\"target\":\"example-target\",\"cfg\":\"\",\"modules\":[{\"name\":\"identity_app\",\"path\":\".\",\"identity\":" +
    jsonString(sourceIdentity) + ",\"dependencies\":[{\"name\":\"native\",\"kind\":\"binary\",\"path\":\"native.bin\",\"identity\":" +
    jsonString(artifactIdentity) + "},{\"name\":\"std\",\"kind\":\"std\",\"path\":\"std.bin\",\"identity\":" + jsonString(artifactIdentity) +
    "},{\"name\":\"stdx\",\"kind\":\"stdx\",\"path\":\"stdx.bin\",\"identity\":" + jsonString(artifactIdentity) +
    "},{\"name\":\"toolchain\",\"kind\":\"toolchain\",\"path\":\"compiler.bin\",\"identity\":" + jsonString(artifactIdentity) + "}]}]}"
}

private func identityTestUnchangedGraph(actual: api_model.DocumentationSet, expected: api_model.DocumentationSet): Unit {
    @Expect(actual.dependencies.size, expected.dependencies.size)
    for (index in 0..expected.dependencies.size) {
        let left = actual.dependencies[index]
        let right = expected.dependencies[index]
        @Expect(left.moduleId, right.moduleId)
        @Expect(left.name, right.name)
        @Expect(left.kind, right.kind)
        @Expect(left.instanceId, right.instanceId)
        @Expect(left.identity, right.identity)
        @Expect(left.state, right.state)
        @Expect(left.target, right.target)
        @Expect(left.cfg, right.cfg)
        @Expect(left.version, right.version)
        @Expect(left.revision, right.revision)
    }
}


@Test
class DependencyIdentityTest {
    @TestCase
    func sourceIdentityIsPortableAndDetectsSameSizeByteChanges(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let first = temporary.join("first")
            let second = temporary.join("second")
            identityTestProject(first, "identity_app")
            identityTestProject(second, "identity_app")
            let a = identityTestDependency(identityTestGenerate(first), "identity_app")
            let b = identityTestDependency(identityTestGenerate(second), "identity_app")
            @Expect(a.state, "observed")
            @Expect(a.identity, b.identity)
            @Expect(a.instanceId, b.instanceId)
            @Expect(a.identity.startsWith("sha256:"), true)
            File.writeTo(second.join("src/api.cj"), "package identity_app\npublic func answer(): Int64 { 2 }\n".toArray())
            let changed = identityTestDependency(identityTestGenerate(second), "identity_app")
            @Expect(changed.identity != a.identity, true)
            @Expect(changed.instanceId != a.instanceId, true)
            @Expect(identityTestDependency(identityTestGenerate(first), "std", kind: "std").state, "unknown")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func pathAndExplicitInputsAreObservedWithoutRenderingDependencySources(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            let dependency = temporary.join("dep")
            let explicit = temporary.join("explicit")
            identityTestProject(root, "identity_app")
            identityTestProject(dependency, "identity_dep")
            identityTestProject(explicit, "explicit_dep")
            File.writeTo(root.join("cjpm.toml"),
                "[package]\nname = \"identity_app\"\n[dependencies]\nidentity_dep = { path = \"../dep\" }\n".toArray())
            let documentation = identityTestGenerate(root, inputs: [DependencySourceInput("explicit_dep", explicit.toString())])
            @Expect(identityTestDependency(documentation, "identity_dep").state, "observed")
            @Expect(identityTestDependency(documentation, "explicit_dep").state, "observed")
            let before = identityTestDependency(documentation, "identity_dep").identity
            File.writeTo(dependency.join("src/api.cj"), "package identity_dep\npublic func changed(): Unit {}\n".toArray())
            @Expect(identityTestDependency(identityTestGenerate(root), "identity_dep").identity != before, true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func absoluteManifestSourcesAreObservedAndDiscoveredWithoutRebasing(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            let dependency = temporary.join("dep")
            identityTestProject(root, "identity_app")
            identityTestProject(dependency, "identity_dep")
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"identity_app\"\n[dependencies]\nidentity_dep = { path = " +
                api_render.escapeJsonString(dependency.toString()) + " }\n").toArray())
            let documentation = identityTestGenerate(root)
            let selected = identityTestDependency(documentation, "identity_dep")
            @Expect(selected.state, "observed")
            @Expect(selected.identity, identityTestDependency(identityTestGenerate(dependency), "identity_dep").identity)
            @Expect(publicHasDiagnostic(documentation, "CJDOC2302"), false)
            let included = DocumentationEngine().generate(GenerationRequest(root.toString(),
                includePathDependencies: true, lintProfile: "off"))
            var found = false
            for (module in included.modules) {
                if (module.name == "identity_dep" && module.role == "pathDependency") { found = true }
            }
            @Expect(found, true)
            @Expect(publicHasDiagnostic(included, "CJDOC1016"), false)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func interpolatedManifestPathsDoNotTreatLiteralDirectoriesAsSelectedInputs(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            let literal = temporary.join("$SELECTED_SOURCE")
            identityTestProject(root, "identity_app")
            identityTestProject(literal, "identity_dep")
            File.writeTo(root.join("cjpm.toml"),
                "[package]\nname = \"identity_app\"\n[dependencies]\nidentity_dep = { path = \"../$SELECTED_SOURCE\" }\n".toArray())
            let automatic = identityTestGenerate(root)
            @Expect(identityTestDependency(automatic, "identity_dep").state, "declared")
            @Expect(identityTestDependency(automatic, "identity_dep").identity, "")
            @Expect(publicHasDiagnostic(automatic, "CJDOC2302"))
            let explicit = identityTestGenerate(root, inputs: [DependencySourceInput("identity_dep", literal.toString())])
            @Expect(identityTestDependency(explicit, "identity_dep").state, "observed")
            @Expect(identityTestDependency(explicit, "identity_dep").identity.isEmpty(), false)
            @Expect(identityTestDependency(explicit, "identity_dep").evidence.contains("explicit dependency source input"))
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func binaryReceiptAndIndependentStandardLibrariesRequireObservedBytes(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            identityTestProject(root, "identity_app")
            for (name in ["native.bin", "std.bin", "stdx.bin", "compiler.bin"]) { File.writeTo(root.join(name), [1u8, 2u8, 3u8]) }
            let source = identityTestDependency(identityTestGenerate(root), "identity_app").identity
            let artifact = "sha256:" + api_model.contractFingerprintBytes([1u8, 2u8, 3u8])
            let receipt = root.join("build-context.json")
            File.writeTo(receipt, identityTestReceipt(source, artifact).toArray())
            let verified = identityTestGenerate(root, receipt: Some(receipt.toString()))
            @Expect(identityTestDependency(verified, "native", kind: "binary").state, "verified")
            @Expect(identityTestDependency(verified, "std", kind: "std").state, "verified")
            @Expect(identityTestDependency(verified, "stdx", kind: "stdx").state, "verified")
            @Expect(identityTestDependency(verified, "std", kind: "std").version, "")
            @Expect(identityTestDependency(verified, "toolchain", kind: "toolchain").state, "verified")
            @Expect(identityTestDependency(verified, "toolchain", kind: "toolchain").version, "")
            File.writeTo(root.join("stdx.bin"), [1u8, 2u8, 4u8])
            let changed = identityTestGenerate(root, receipt: Some(receipt.toString()))
            @Expect(identityTestDependency(changed, "std", kind: "std").state, "verified")
            @Expect(identityTestDependency(changed, "stdx", kind: "stdx").state, "conflict")
            @Expect(identityTestDependency(changed, "stdx", kind: "stdx").identity != artifact, true)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func receiptConfigAndStaleProjectClaimsCannotUpgradeEvidence(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            identityTestProject(root, "identity_app")
            for (name in ["native.bin", "std.bin", "stdx.bin", "compiler.bin"]) { File.writeTo(root.join(name), [1u8]) }
            let source = identityTestDependency(identityTestGenerate(root), "identity_app").identity
            let receipt = root.join("build-context.json")
            File.writeTo(receipt, identityTestReceipt(source, "sha256:" + api_model.contractFingerprintBytes([1u8])).toArray())
            let configuredBaseline = identityTestGenerate(root, cfg: [CfgValue("feature", "enabled")])
            let configured = identityTestGenerate(root, receipt: Some(receipt.toString()), cfg: [CfgValue("feature", "enabled")])
            identityTestUnchangedGraph(configured, configuredBaseline)
            @Expect(publicHasDiagnostic(configured, "CJDOC2301"), true)
            File.writeTo(root.join("src/api.cj"), "package identity_app\npublic func answer(): Int64 { 9 }\n".toArray())
            let staleBaseline = identityTestGenerate(root)
            let stale = identityTestGenerate(root, receipt: Some(receipt.toString()))
            identityTestUnchangedGraph(stale, staleBaseline)
            @Expect(publicHasDiagnostic(stale, "CJDOC2301"), true)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func lockVersionConflictIsExplicitAndCacheClaimsRemainDeclared(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            let dependency = temporary.join("dep")
            identityTestProject(root, "identity_app")
            identityTestProject(dependency, "identity_dep")
            File.writeTo(root.join("cjpm.toml"),
                "[package]\nname = \"identity_app\"\n[dependencies]\nidentity_dep = { path = \"../dep\" }\n".toArray())
            File.writeTo(root.join("cjpm.lock"),
                "[requires]\nidentity_dep = { version = \"2.0.0\" }\ncached_dep = { version = \"3.0.0\" }\n".toArray())
            let documentation = identityTestGenerate(root)
            @Expect(identityTestDependency(documentation, "identity_dep").state, "conflict")
            @Expect(identityTestDependency(documentation, "cached_dep").state, "declared")
            @Expect(identityTestDependency(documentation, "cached_dep").identity, "")
            @Expect(publicHasDiagnostic(documentation, "CJDOC2301"), true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func malformedReceiptDoesNotLeavePartiallyVerifiedClaims(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            identityTestProject(root, "identity_app")
            let source = identityTestDependency(identityTestGenerate(root), "identity_app").identity
            let receipt = root.join("build-context.json")
            let invalid = identityTestReceipt(source, "sha256:invalid").replace(
                "\"schemaVersion\":\"cjdoc.build-context/1\"",
                "\"schemaVersion\":\"cjdoc.build-context/1\",\"schemaVersion\":\"cjdoc.build-context/1\"")
            File.writeTo(receipt, invalid.toArray())
            let documentation = identityTestGenerate(root, receipt: Some(receipt.toString()))
            @Expect(identityTestDependency(documentation, "identity_app").state, "observed")
            @Expect(identityTestDependency(documentation, "std", kind: "std").state, "unknown")
            @Expect(publicHasDiagnostic(documentation, "CJDOC2300"), true)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func invalidAndStaleReceiptsCannotSelectTargetConditionalDependencies(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            identityTestProject(root, "identity_app")
            identityTestProject(temporary.join("dep"), "identity_dep")
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"identity_app\"\n" +
                "[target.example-target.dependencies]\nidentity_dep = { path = \"../dep\" }\n").toArray())
            let baseline = identityTestGenerate(root)
            let receipt = root.join("invalid.json")
            File.writeTo(receipt, "{\"schemaVersion\":\"cjdoc.build-context/1\",\"target\":\"example-target\",\"modules\":false}".toArray())
            let invalid = identityTestGenerate(root, receipt: Some(receipt.toString()))
            identityTestUnchangedGraph(invalid, baseline)
            @Expect(publicHasDiagnostic(invalid, "CJDOC2300"), true)
            File.writeTo(receipt, identityTestReceipt("sha256:stale", "sha256:stale").toArray())
            let stale = identityTestGenerate(root, receipt: Some(receipt.toString()))
            identityTestUnchangedGraph(stale, baseline)
            @Expect(publicHasDiagnostic(stale, "CJDOC2300"), true)
            @Expect(publicHasDiagnostic(stale, "CJDOC2301"), true)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func publicLinkInputsAreCopiedAndRestrictedToGenerationCommands(): Unit {
        let sources = ["local-catalog.json"]
        let pins = [DocumentInventoryPin("inventory.json", api_model.contractFingerprint("trusted bytes"))]
        let request = GenerationRequest("project", buildContext: Some("build-context.json"),
            documentSources: sources, linkLanguage: "en", linkLanguageFallback: true, linkCompatible: true,
            documentInventoryPins: pins, documentationRevision: "docs-r7")
        @Expect(request.documentationRevision, "docs-r7")
        sources[0] = "changed.json"
        @Expect(request.documentSources[0], "local-catalog.json")
        pins[0] = DocumentInventoryPin("other.json", api_model.contractFingerprint("other bytes"))
        @Expect(request.documentInventoryPins[0].path, "inventory.json")
        @ExpectThrows[IllegalArgumentException](DocumentInventoryPin("inventory.json", "untrusted"))
        @Expect(runCli(["render", "--input", "unused.json", "--doc-inventory-pin", "inventory.json=" + api_model.contractFingerprint("trusted bytes")]), 2)
        @Expect(request.buildContext, Some("build-context.json"))
        @Expect(request.linkLanguage, "en")
        @Expect(request.linkLanguageFallback, true)
        @Expect(request.linkCompatible, true)
        @Expect(runCli(["render", "--input", "unused.json", "--build-context", "record.json"]), 2)
        @Expect(runCli(["diff", "old.json", "new.json", "--doc-source", "catalog.json"]), 2)
        @Expect(runCli(["serve", "--link-compatible"]), 2)
        @ExpectThrows[IllegalArgumentException](GenerationRequest("project", buildContext: Some("")))
        @ExpectThrows[IllegalArgumentException](GenerationRequest("project", documentSources: [" "]))
    }
}
