package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.fs.*
import std.env.*
import std.unittest.*
import std.unittest.mock.*
import std.unittest.mock.mockmacro.*
import std.unittest.testmacro.*

// The observed Windows host (STS 1.2 runner with ordinary, non-extended paths)
// refused creation and could not represent the 129-segment fixture path, so only
// platforms that can represent it report the physical boundary; the numeric rule
// is asserted separately with explicit budgets on every platform.
@When[os == "Windows"]
private let identityTestDepthIsRepresentable: Bool = false

@When[os != "Windows"]
private let identityTestDepthIsRepresentable: Bool = true

private let identityTestChainDepth: Int64 = if (identityTestDepthIsRepresentable) { 127 } else { 40 }

// A relative inventory path of exactly `count` segments, used to assert the
// numeric depth rule against the same accounting the inventory applies.
private func identityTestDepthBoundarySample(count: Int64): String {
    let builder = StringBuilder()
    for (index in 0..count) {
        if (index > 0) { builder.append("/") }
        builder.append("n")
    }
    builder.toString()
}

// An observed access violation reproduced when std.fs removed a deep tree
// recursively, while removing each level's leaf and then the directories
// deepest-first completed normally; the deepest-first form is used here so the
// fixture never depends on that recursive call.
private func identityTestRemoveChain(chain: ArrayList<Path>, root: Path): Unit {
    var index = chain.size
    while (index > 0) {
        index--
        let _ = removeIfExists(chain[index].join("leaf.cj"))
    }
    index = chain.size
    while (index > 0) {
        index--
        let _ = removeIfExists(chain[index])
    }
    let _ = removeIfExists(root, recursive: true)
}

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

private func identityTestDiagnosticCount(documentation: api_model.DocumentationSet,
    code: String, message: String): Int64 {
    var count: Int64 = 0
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code && diagnostic.message == message) { count++ }
    }
    count
}

private func identityTestDuplicateDiagnostics(documentation: api_model.DocumentationSet): Int64 {
    let seen = HashSet<String>()
    var duplicates: Int64 = 0
    for (diagnostic in documentation.diagnostics) {
        if (!seen.add(diagnostic.code + "\n" + diagnostic.message)) { duplicates++ }
    }
    duplicates
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
    func sourceInventoryPairsLengthWithBytesReadAfterReplacement(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let source = root.join("input.cj")
            File.writeTo(source, [b'x'])
            let beforeSize = FileInfo(source).size
            let replacement = "// replacement source has a different length\n".toArray()
            @Expect(beforeSize != replacement.size, true)
            // Replace at the bounded-reader boundary: the old inventory has
            // already captured its outer FileInfo size, but the stable read
            // legitimately observes only the replacement.
            @On(readAuxiliaryFileBounded(source, _, _)).returns({ =>
                @Expect(FileInfo(source).size, beforeSize)
                File.writeTo(source, replacement)
                readFileBounded(source, 64 * 1024 * 1024)
            }).once().then().callsOriginal()
            let expectedInventory = "cjdoc.dependency-inventory/1\n8:input.cj:" +
                replacement.size.toString() + ":" + api_model.contractFingerprintBytes(replacement) + "\n"
            let expected = "sha256:" + api_model.contractFingerprint(expectedInventory)
            let observed = dependencyObservedIdentity(root.toString(), true)
            @Expect(observed, expected)
            @Expect(dependencyObservedIdentity(root.toString(), true), expected)
            @Expect(File.readFrom(source), replacement)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func sourceInventoryRejectsFileAddedAfterEnumeration(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let source = root.join("input.cj")
            File.writeTo(source, [b'x'])
            @On(readAuxiliaryFileBounded(source, _, _)).returns({ =>
                let bytes = readFileBounded(source, 64 * 1024 * 1024)
                File.writeTo(root.join("added.cj"), [b'y'])
                bytes
            }).once()
            @ExpectThrows[IllegalArgumentException](dependencyObservedIdentity(root.toString(), true))
            @Expect(FileInfo(root.join("added.cj")).isRegular(), true)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func sourceInventoryRejectsEarlierFileReplacedDuringLaterRead(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            let earlier = root.join("a.cj")
            let later = root.join("z.cj")
            File.writeTo(earlier, [b'x'])
            File.writeTo(later, [b'y'])
            @On(readAuxiliaryFileBounded(later, _, _)).returns({ =>
                let bytes = readFileBounded(later, 64 * 1024 * 1024)
                let _ = removeIfExists(earlier)
                File.writeTo(earlier, "replacement".toArray())
                bytes
            }).once()
            @ExpectThrows[IllegalArgumentException](dependencyObservedIdentity(root.toString(), true))
            @Expect(File.readFrom(earlier), "replacement".toArray())
        } finally { let _ = removeIfExists(root, recursive: true) }
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
    func targetManifestPathOverridesGeneralPathBeforeObservation(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            let general = temporary.join("general")
            let selected = temporary.join("selected")
            identityTestProject(root, "identity_app")
            identityTestProject(general, "identity_dep")
            identityTestProject(selected, "identity_dep")
            identityTestProject(temporary.join("general-only"), "general_only")
            identityTestProject(temporary.join("target-only"), "target_only")
            File.writeTo(general.join("src/api.cj"), "package identity_dep\npublic func general(): Unit {}\n".toArray())
            let expected = identityTestDependency(identityTestGenerate(selected), "identity_dep").identity
            let common = "[dependencies]\nidentity_dep = { path = \"../general\" }\n" +
                "general_only = { path = \"../general-only\" }\n"
            let target = "[target.example-target.dependencies]\nidentity_dep = { path = \"../selected\" }\n" +
                "target_only = { path = \"../target-only\" }\n"
            let targetTable = "[target.example-target.dependencies.identity_dep]\npath = \"../selected\"\n" +
                "[target.example-target.dependencies.target_only]\npath = \"../target-only\"\n"
            for (tables in [common + target, target + common, common + targetTable, targetTable + common]) {
                File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"identity_app\"\n" + tables).toArray())
                let documentation = identityTestGenerate(root, cfg: [CfgValue("target", "example-target")])
                let dependency = identityTestDependency(documentation, "identity_dep")
                @Expect(dependency.state, "observed")
                @Expect(dependency.identity, expected)
                @Expect(identityTestDependency(documentation, "general_only").state, "observed")
                @Expect(identityTestDependency(documentation, "target_only").state, "observed")
                @Expect(publicHasDiagnostic(documentation, "CJDOC2301"), false)
                @Expect(publicHasDiagnostic(documentation, "CJDOC2302"), false)
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func targetVersionOnlyDeclarationDiscardsGeneralPathAndItsClosure(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            let general = temporary.join("general")
            identityTestProject(root, "identity_app")
            identityTestProject(general, "identity_dep")
            identityTestProject(temporary.join("child"), "unselected_child")
            File.writeTo(general.join("cjpm.toml"), ("[package]\nname = \"identity_dep\"\nversion = \"1.0.0\"\n" +
                "[dependencies]\nunselected_child = { path = \"../child\" }\n").toArray())
            for (version in ["", ", version = \"1.0.0\""]) {
                let common = "[dependencies]\nidentity_dep = { path = \"../general\"" + version + " }\n"
                let target = "[target.example-target.dependencies]\nidentity_dep = { version = \"2.0\" }\n"
                let targetTable = "[target.example-target.dependencies.identity_dep]\nversion = \"2.0\"\n"
                for (tables in [common + target, target + common, common + targetTable, targetTable + common]) {
                    File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"identity_app\"\n" + tables).toArray())
                    let documentation = identityTestGenerate(root, cfg: [CfgValue("target", "example-target")])
                    let dependency = identityTestDependency(documentation, "identity_dep")
                    @Expect(dependency.state, "declared")
                    @Expect(dependency.version, "2.0")
                    @Expect(dependency.identity, "")
                    @Expect(dependency.componentModuleId, "")
                    for (entry in documentation.dependencies) { @Expect(entry.name != "unselected_child", true) }
                    @Expect(publicHasDiagnostic(documentation, "CJDOC2301"), false)
                    @Expect(publicHasDiagnostic(documentation, "CJDOC2302"), false)
                }
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func generalVersionOnlyDeclarationCannotReplaceTargetPath(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = temporary.join("app")
            let selected = temporary.join("selected")
            identityTestProject(root, "identity_app")
            identityTestProject(selected, "identity_dep")
            let expected = identityTestDependency(identityTestGenerate(selected), "identity_dep").identity
            let common = "[dependencies]\nidentity_dep = { version = \"2.0\" }\n"
            let target = "[target.example-target.dependencies]\nidentity_dep = { path = \"../selected\" }\n"
            for (tables in [common + target, target + common]) {
                File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"identity_app\"\n" + tables).toArray())
                let documentation = identityTestGenerate(root, cfg: [CfgValue("target", "example-target")])
                @Expect(identityTestDependency(documentation, "identity_dep").state, "observed")
                @Expect(identityTestDependency(documentation, "identity_dep").identity, expected)
                @Expect(identityTestDependency(documentation, "identity_dep").version, "1.0.0")
                @Expect(publicHasDiagnostic(documentation, "CJDOC2301"), false)
            }
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
    func successfulReceiptDoesNotDuplicateObservedGraphWarnings(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            identityTestProject(root, "identity_app")
            File.writeTo(root.join("cjpm.lock"), "[requires]\nbroken = {".toArray())
            for (name in ["native.bin", "std.bin", "stdx.bin", "compiler.bin"]) {
                File.writeTo(root.join(name), [1u8, 2u8, 3u8])
            }
            let baseline = identityTestGenerate(root)
            let source = identityTestDependency(baseline, "identity_app").identity
            let artifact = "sha256:" + api_model.contractFingerprintBytes([1u8, 2u8, 3u8])
            let receipt = root.join("build-context.json")
            File.writeTo(receipt, identityTestReceipt(source, artifact).toArray())
            let documentation = identityTestGenerate(root, receipt: Some(receipt.toString()))
            @Expect(identityTestDiagnosticCount(baseline, "CJDOC2302", "dependency lock inventory could not be observed"), 1)
            @Expect(identityTestDiagnosticCount(documentation, "CJDOC2302", "dependency lock inventory could not be observed"), 1)
            @Expect(identityTestDuplicateDiagnostics(documentation), 0)
            @Expect(identityTestDependency(documentation, "identity_app").state, "verified")
            @Expect(identityTestDependency(documentation, "native", kind: "binary").state, "verified")
            @Expect(publicHasDiagnostic(documentation, "CJDOC2300"), false)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func ignoredReceiptDiscardsWarningsProducedBeforeALaterInvalidModule(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            identityTestProject(root, "identity_app")
            for (name in ["native.bin", "std.bin", "stdx.bin", "compiler.bin"]) {
                File.writeTo(root.join(name), [1u8, 2u8, 3u8])
            }
            let baseline = identityTestGenerate(root)
            let source = identityTestDependency(baseline, "identity_app").identity
            let artifact = "sha256:" + api_model.contractFingerprintBytes([1u8, 2u8, 3u8])
            let receipt = root.join("build-context.json")
            for (warning in ["conflict", "unavailable"]) {
                let valid = identityTestReceipt(source, artifact)
                let warned = if (warning == "conflict") {
                    valid.replace("\"path\":\".\",\"identity\":" + api_render.escapeJsonString(source) + ",\"dependencies\"",
                        "\"path\":\".\",\"identity\":\"sha256:stale\",\"dependencies\"")
                } else { valid.replace("\"path\":\"native.bin\"", "\"path\":\"missing.bin\"") }
                // Shape validation succeeds. The first module emits a real warning;
                // only the subsequent, unobserved module makes application fail.
                let invalid = warned[..warned.size - 2] +
                    ",{\"name\":\"unobserved\",\"path\":\".\",\"identity\":\"sha256:invalid\",\"dependencies\":[]}]}"
                File.writeTo(receipt, invalid.toArray())
                let documentation = identityTestGenerate(root, receipt: Some(receipt.toString()))
                identityTestUnchangedGraph(documentation, baseline)
                @Expect(publicDiagnosticCount(documentation, "CJDOC2300"), 1)
                @Expect(publicDiagnosticCount(documentation, "CJDOC2301"), 0)
                @Expect(publicDiagnosticCount(documentation, "CJDOC2302"), 0)
                @Expect(identityTestDiagnosticCount(documentation, "CJDOC2300",
                    "build context is invalid or cannot be bound to the observed project graph; record ignored"), 1)
            }
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    @TestCase
    func committedReceiptKeepsNewGraphAndSelectionWarnings(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        let root = temporary.join("app")
        let dependency = temporary.join("selected")
        try {
            identityTestProject(root, "identity_app")
            identityTestProject(dependency, "selected")
            File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"identity_app\"\nversion = \"1.0.0\"\n" +
                "[target.example-target.dependencies]\nselected = { path = \"../selected\" }\n" +
                "unavailable = { path = \"../missing-dependency\" }\n").toArray())
            File.writeTo(root.join("cjpm.lock"), "[requires]\nbroken = {".toArray())
            for (name in ["native.bin", "std.bin", "stdx.bin", "compiler.bin"]) {
                File.writeTo(root.join(name), [1u8, 2u8, 3u8])
            }
            let baseline = identityTestGenerate(root)
            let source = identityTestDependency(baseline, "identity_app").identity
            let artifact = "sha256:" + api_model.contractFingerprintBytes([1u8, 2u8, 3u8])
            let dependencyIdentity = identityTestDependency(identityTestGenerate(dependency), "selected").identity
            let receipt = root.join("build-context.json")
            let selected = identityTestReceipt(source, artifact).replace(
                "\"path\":\"native.bin\",\"identity\":" + api_render.escapeJsonString(artifact),
                "\"path\":\"native.bin\",\"identity\":\"sha256:stale\"").replace(
                "\"path\":\"std.bin\"", "\"path\":\"missing.bin\"")
            let complete = selected[..selected.size - 2] + ",{\"name\":\"selected\",\"path\":\"../selected\",\"identity\":" +
                api_render.escapeJsonString(dependencyIdentity) + ",\"dependencies\":[]}]}"
            File.writeTo(receipt, complete.toArray())
            let documentation = identityTestGenerate(root, receipt: Some(receipt.toString()))
            let project = identityTestDependency(documentation, "identity_app")
            @Expect(project.state, "verified")
            @Expect(project.identity, source)
            @Expect(project.target, "example-target")
            @Expect(identityTestDependency(documentation, "native", kind: "binary").state, "conflict")
            @Expect(identityTestDependency(documentation, "std", kind: "std").state, "unknown")
            @Expect(identityTestDependency(documentation, "stdx", kind: "stdx").state, "verified")
            @Expect(identityTestDependency(documentation, "toolchain", kind: "toolchain").state, "verified")
            let committed = identityTestDependency(documentation, "selected")
            @Expect(committed.componentModuleId.isEmpty(), false)
            @Expect(identityTestDependency(documentation, "selected", owner: committed.componentModuleId).state, "verified")
            @Expect(identityTestDependency(documentation, "selected", owner: committed.componentModuleId).identity, dependencyIdentity)
            @Expect(identityTestDiagnosticCount(baseline, "CJDOC2302",
                "dependency manifest could not be observed within inventory limits"), 0)
            @Expect(identityTestDiagnosticCount(documentation, "CJDOC2302",
                "dependency manifest could not be observed within inventory limits"), 1)
            @Expect(identityTestDiagnosticCount(documentation, "CJDOC2301",
                "build record dependency conflicts with observed target inputs"), 1)
            @Expect(identityTestDiagnosticCount(documentation, "CJDOC2302",
                "build record dependency input is inaccessible or exceeds observation limits"), 1)
            @Expect(identityTestDiagnosticCount(documentation, "CJDOC2302",
                "dependency lock inventory could not be observed"), 1)
            @Expect(identityTestDuplicateDiagnostics(documentation), 0)
            @Expect(publicHasDiagnostic(documentation, "CJDOC2300"), false)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func validReceiptReusesObservedSourceWithinTheAggregateBudget(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        try {
            identityTestProject(root, "identity_app")
            let inventory = root.join("observed")
            Directory.create(inventory)
            // The aggregate must exceed half of MAX_BYTES so a non-caching
            // implementation would re-charge the same bytes and fail, while each
            // file stays small enough that reading one cannot approach the test
            // heap: many bounded files instead of a few near-limit ones.
            let chunk = Array<Byte>(1024 * 1024, repeat: b'x')
            for (index in 0..48) {
                let target = inventory.join("input" + index.toString() + ".cj")
                File.writeTo(target, [])
                let file = File(target, OpenMode.Write)
                try {
                    for (_ in 0..6) { file.write(chunk) }
                } finally { file.close() }
            }
            for (name in ["native.bin", "std.bin", "stdx.bin", "compiler.bin"]) {
                File.writeTo(root.join(name), [1u8, 2u8, 3u8])
            }
            let source = identityTestDependency(identityTestGenerate(root), "identity_app").identity
            let artifact = "sha256:" + api_model.contractFingerprintBytes([1u8, 2u8, 3u8])
            let receipt = root.join("build-context.json")
            File.writeTo(receipt, identityTestReceipt(source, artifact).toArray())
            let verified = identityTestGenerate(root, receipt: Some(receipt.toString()))
            let project = identityTestDependency(verified, "identity_app")
            @Expect(project.state, "verified")
            @Expect(project.identity, source)
            @Expect(project.target, "example-target")
            for (kind in ["binary", "std", "stdx", "toolchain"]) {
                let name = if (kind == "binary") { "native" } else { kind }
                @Expect(identityTestDependency(verified, name, kind: kind).state, "verified")
            }
            @Expect(publicHasDiagnostic(verified, "CJDOC2300"), false)
            @Expect(publicHasDiagnostic(verified, "CJDOC2302"), false)
        } finally { let _ = removeIfExists(root, recursive: true) }
    }

    // The product caps inventory depth at MAX_SOURCE_DIRECTORY_DEPTH and must
    // report a deeper input as unknown instead of overflowing the stack.
    //
    // Evidence is layered by what the host can represent: every platform builds a
    // real chain and runs the public engine over it, and asserts the numeric
    // 128/129 rule against the same depth accounting the inventory uses. Only the
    // platforms whose path limit admits the full 129-segment fixture additionally
    // report the end-to-end physical boundary. This is numeric-plus-integration
    // evidence on the constrained platform, not a physical 129-segment run.
    @TestCase
    func inventoryDepthBoundaryDoesNotDependOnTheRuntimeCallStack(): Unit {
        let root = Directory.createTemp(getTempDirectory())
        let chain = ArrayList<Path>()
        try {
            identityTestProject(root, "identity_app")
            var directory = root
            for (_ in 0..identityTestChainDepth) {
                directory = directory.join("n")
                Directory.create(directory)
                chain.add(directory)
            }
            File.writeTo(directory.join("leaf.cj"), "// selected source bytes\n".toArray())
            let observed = identityTestGenerate(root)
            @Expect(identityTestDependency(observed, "identity_app").state, "observed")
            @Expect(publicHasDiagnostic(observed, "CJDOC2302"), false)

            let atBoundary = SourceDirectoryBudget(maxEntries: 100000,
                maxDepth: MAX_SOURCE_DIRECTORY_DEPTH)
            @Expect(atBoundary.consume(identityTestDepthBoundarySample(MAX_SOURCE_DIRECTORY_DEPTH)), true)
            @Expect(atBoundary.limitReached, false)
            let pastBoundary = SourceDirectoryBudget(maxEntries: 100000,
                maxDepth: MAX_SOURCE_DIRECTORY_DEPTH)
            @Expect(pastBoundary.consume(identityTestDepthBoundarySample(MAX_SOURCE_DIRECTORY_DEPTH + 1)), false)
            @Expect(pastBoundary.limitReached, true)

            let fileDepth = identityTestChainDepth + 1
            let shallowAccepted = dependencyObservedIdentity(root.toString(), true,
                directoryBudget: Some(SourceDirectoryBudget(maxEntries: 100000, maxDepth: fileDepth)))
            @Expect(shallowAccepted.startsWith("sha256:"), true)
            var shallowRefused = false
            try {
                let _ = dependencyObservedIdentity(root.toString(), true,
                    directoryBudget: Some(SourceDirectoryBudget(maxEntries: 100000,
                        maxDepth: fileDepth - 1)))
            } catch (_: Exception) { shallowRefused = true }
            @Expect(shallowRefused, true)

            if (!identityTestDepthIsRepresentable) { return }
            directory = directory.join("n")
            Directory.create(directory)
            chain.add(directory)
            File.writeTo(directory.join("leaf.cj"), "// exceeds the depth limit\n".toArray())
            let rejected = identityTestGenerate(root)
            @Expect(identityTestDependency(rejected, "identity_app").state, "unknown")
            @Expect(publicHasDiagnostic(rejected, "CJDOC2302"), true)
        } finally { identityTestRemoveChain(chain, root) }
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
