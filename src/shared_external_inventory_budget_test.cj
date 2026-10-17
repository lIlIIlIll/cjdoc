package cjdoc

import cjdoc.model as api_model
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func inventoryBudgetGenerate(root: Path, sources!: Array<String> = []): api_model.DocumentationSet {
    let binary = getVariable("CJDOC_I18N_BINARY").getOrDefault({ => "target/release/bin/main" })
    let pins = ArrayList<DocumentInventoryPin>()
    let modern = root.join("modern.json")
    if (exists(modern) && FileInfo(modern).size <= 8 * 1024 * 1024) {
        pins.add(DocumentInventoryPin(modern.toString(), api_model.contractFingerprint(readTextBounded(modern, 8 * 1024 * 1024))))
    }
    DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off", documentSources: sources,
        astPreflightExecutable: Some(binary), documentInventoryPins: pins.toArray()))
}

private func inventoryBudgetProject(temporary: Path): Path {
    let root = temporary.join("app")
    let dependency = temporary.join("dep")
    Directory.create(root.join("src"), recursive: true)
    Directory.create(dependency.join("src"), recursive: true)
    File.writeTo(dependency.join("cjpm.toml"), "[package]\nname = \"inventory_dep\"\nversion = \"1.0.0\"\n".toArray())
    File.writeTo(dependency.join("src/api.cj"), "package inventory_dep\n/** Token. */\npublic class Token {}\n".toArray())
    File.writeTo(root.join("cjpm.toml"), ("[package]\nname = \"inventory_app\"\nversion = \"1.0.0\"\n" +
        "[dependencies]\ninventory_dep = { path = \"../dep\" }\n").toArray())
    File.writeTo(root.join("src/api.cj"), ("package inventory_app\nimport inventory_dep\n" +
        "/** {@link inventory_dep.Token} and {@link legacy.Token}. */\n" +
        "public func use(value: inventory_dep.Token): Unit {}\n" +
        "/** Automatic legacy types have no identity evidence. */\n" +
        "public func legacyUse(value: legacy.Token): Unit {}\n").toArray())
    let generated = inventoryBudgetGenerate(dependency)
    let artifacts = api_render.rendererFor("symbol-index").render(generated)
    File.writeTo(root.join("modern.json"), artifacts[0].content.toArray())
    File.writeTo(root.join("catalog.json"), ("{\"schemaVersion\":\"cjdoc.doc-sources/1\",\"documents\":[" +
        "{\"index\":\"modern.json\",\"baseUrl\":\"https://docs.example.test/modern\"}]}").toArray())
    root
}

private func inventoryBudgetLegacyConfig(count: Int64, index!: String = "legacy.json"): String {
    let text = StringBuilder()
    for (number in 0..count) {
        text.append("[external-docs.legacy" + number.toString() + "]\nindex = \"" + index +
            "\"\nbase-url = \"https://docs.example.test/legacy\"\n")
    }
    text.toString()
}

private func inventoryBudgetLegacyIndex(count!: Int64 = 1): String {
    let text = StringBuilder()
    text.append("{\"schemaVersion\":\"cjdoc.symbol-index/1\",\"symbols\":[")
    for (index in 0..count) {
        if (index != 0) { text.append(",") }
        text.append("{\"qualifiedName\":\"legacy.Token\",\"href\":\"symbols/token.html\"}")
    }
    text.append("]}")
    text.toString()
}

private func inventoryBudgetSymbol(value: api_model.DocumentationSet, name: String): api_model.SymbolDoc {
    for (symbol in value.declarations where symbol.name == name) { return symbol }
    throw IllegalStateException("expected generated declaration")
}

private func inventoryBudgetNavigation(value: api_model.DocumentationSet): api_model.TypeNavigation {
    inventoryBudgetSymbol(value, "use").parameters[0].typeRef.navigation.getOrThrow()
}

private func inventoryBudgetLink(node: api_model.MarkdownNode, target: String): ?api_model.TypeNavigation {
    if (let Some(metadata) <- node.metadata) {
        if (metadata.semanticTarget == Some(target)) { return metadata.semanticNavigation }
    }
    for (child in node.children) {
        if (let Some(navigation) <- inventoryBudgetLink(child, target)) { return Some(navigation) }
    }
    None
}

private func inventoryBudgetManual(value: api_model.DocumentationSet): api_model.TypeNavigation {
    inventoryBudgetLink(inventoryBudgetSymbol(value, "use").documentation.getOrThrow().markdown, "legacy.Token").getOrThrow()
}

private func inventoryBudgetLanguageInventories(root: Path): Array<DocumentInventoryPin> {
    let original = readTextBounded(root.join("modern.json"), 8 * 1024 * 1024)
    @Assert(original.contains("\"language\":\"en\""))
    let pins = ArrayList<DocumentInventoryPin>()
    for ((name, language) in [("modern.json", "zh-CN"), ("fallback.json", "en")]) {
        let text = original.replace("\"language\":\"en\"", "\"language\":\"" + language + "\"")
        let path = root.join(name)
        File.writeTo(path, text.toArray())
        pins.add(DocumentInventoryPin(path.toString(), api_model.contractFingerprint(text)))
    }
    pins.toArray()
}

private func inventoryBudgetLanguageEntry(index: String, base: String, priority: Int64): String {
    "{\"index\":\"" + index + "\",\"baseUrl\":\"https://docs.example.test/" + base +
        "\",\"priority\":" + priority.toString() + "}"
}

private func inventoryBudgetLanguageNavigation(root: Path, documents: String, pins: Array<DocumentInventoryPin>,
    fallback!: Bool = true): api_model.TypeNavigation {
    File.writeTo(root.join("catalog.json"),
        ("{\"schemaVersion\":\"cjdoc.doc-sources/1\",\"documents\":[" + documents + "]}").toArray())
    let binary = getVariable("CJDOC_I18N_BINARY").getOrDefault({ => "target/release/bin/main" })
    inventoryBudgetNavigation(DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
        documentSources: ["catalog.json"], documentInventoryPins: pins, linkLanguage: "zh-CN",
        linkLanguageFallback: fallback, astPreflightExecutable: Some(binary))))
}

private func inventoryBudgetSharedOverloadProject(temporary: Path): Path {
    let root = inventoryBudgetProject(temporary)
    let dependency = temporary.join("dep")
    File.writeTo(dependency.join("src/api.cj"), ("package inventory_dep\n" +
        "/** Integer overload. */\npublic func run(value: Int64): Unit {}\n" +
        "/** String overload. */\npublic func run(value: String): Unit {}\n").toArray())
    File.writeTo(root.join("src/api.cj"), ("package inventory_app\nimport inventory_dep\n" +
        "/** {@link inventory_dep.run} and {@link inventory_dep.run(Int64)} and {@link inventory_dep.run(String)}. */\n" +
        "public func use(): Unit {}\n").toArray())
    var text = api_render.rendererFor("symbol-index").render(inventoryBudgetGenerate(dependency))[0].content
    let entries = JsonNode.parse(text).asObject()["entries"].asArray()
    @Assert(entries.size(), 2)
    for (index in 0..entries.size()) {
        let entry = entries.get(index).getOrThrow().asObject()
        @Assert(entry["qualifiedName"].asString(), "inventory_dep.run")
        // A publisher may put every overload on the same page and anchor.
        text = text.replace(api_render.escapeJsonString(entry["href"].asString()),
            api_render.escapeJsonString("html/run.html#overloads"))
    }
    File.writeTo(root.join("modern.json"), text.toArray())
    root
}

private func inventoryBudgetPad(path: Path, text: String, size: Int64): Unit {
    File.writeTo(path, (text + String.fromUtf8(Array<Byte>(size - text.size, repeat: b' '))).toArray())
}

@Test
class SharedExternalInventoryBudgetTest {
    @TestCase
    func requestedLanguageOutranksSourcePriorityAtTheSameMatchLevel(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let pins = inventoryBudgetLanguageInventories(root)
            for ((requestedPriority, fallbackPriority) in [(0, 1), (-1000, 1000)]) {
                let requested = inventoryBudgetLanguageEntry("modern.json", "requested", requestedPriority)
                let fallback = inventoryBudgetLanguageEntry("fallback.json", "fallback", fallbackPriority)
                for (documents in [requested + "," + fallback, fallback + "," + requested]) {
                    let navigation = inventoryBudgetLanguageNavigation(root, documents, pins)
                    @Expect(navigation.state, "resolved")
                    @Expect(navigation.matchLevel, "exact")
                    @Expect(navigation.language, "zh-CN")
                    @Expect(navigation.url.startsWith("https://docs.example.test/requested/"))
                }
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func betterMatchLevelOutranksRequestedLanguageAndSourcePriority(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let pins = inventoryBudgetLanguageInventories(root)
            let requested = inventoryBudgetLanguageEntry("modern.json", "requested", 1000)
            let fallback = inventoryBudgetLanguageEntry("fallback.json", "fallback", -1000)
            for (documents in [requested + "," + fallback, fallback + "," + requested]) {
                // Only the other-language inventory is pinned: exact must beat manual.
                let navigation = inventoryBudgetLanguageNavigation(root, documents, [pins[1]])
                @Expect(navigation.state, "resolved")
                @Expect(navigation.matchLevel, "exact")
                @Expect(navigation.language, "en")
                @Expect(navigation.url.startsWith("https://docs.example.test/fallback/"))
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func missingRequestedLanguageRequiresExplicitFallback(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let pins = inventoryBudgetLanguageInventories(root)
            let fallback = inventoryBudgetLanguageEntry("fallback.json", "fallback", 1)
            let blocked = inventoryBudgetLanguageNavigation(root, fallback, pins, fallback: false)
            @Expect(blocked.state != "resolved")
            @Expect(blocked.reason, "selected API identity has no requested language")
            let allowed = inventoryBudgetLanguageNavigation(root, fallback, pins)
            @Expect(allowed.state, "resolved")
            @Expect(allowed.matchLevel, "exact")
            @Expect(allowed.language, "en")
            @Expect(allowed.url.startsWith("https://docs.example.test/fallback/"))
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func equalLanguageAndPriorityTargetsRemainAmbiguous(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let pins = inventoryBudgetLanguageInventories(root)
            let first = inventoryBudgetLanguageEntry("modern.json", "first", 0)
            let second = inventoryBudgetLanguageEntry("modern.json", "second", 0)
            for (documents in [first + "," + second, second + "," + first]) {
                let navigation = inventoryBudgetLanguageNavigation(root, documents, pins)
                @Expect(navigation.state, "ambiguous")
                @Expect(navigation.matchLevel, "none")
                @Expect(navigation.url, "")
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func equalRankedOverloadsSharingAUrlRemainAmbiguous(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetSharedOverloadProject(temporary)
            let result = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            let markdown = inventoryBudgetSymbol(result, "use").documentation.getOrThrow().markdown
            let integer = inventoryBudgetLink(markdown, "inventory_dep.run(Int64)").getOrThrow()
            let string = inventoryBudgetLink(markdown, "inventory_dep.run(String)").getOrThrow()
            @Expect(integer.state, "resolved")
            @Expect(string.state, "resolved")
            @Expect(integer.matchLevel, "exact")
            @Expect(string.matchLevel, integer.matchLevel)
            @Expect(integer.url, "https://docs.example.test/modern/html/run.html#overloads")
            @Expect(string.url, integer.url)
            @Expect(integer.documentSetId.isEmpty(), false)
            @Expect(string.documentSetId, integer.documentSetId)
            @Expect(string.apiIdentity, integer.apiIdentity)
            @Expect(integer.dependencyInstanceId.isEmpty(), false)
            @Expect(string.dependencyInstanceId, integer.dependencyInstanceId)
            @Expect(integer.symbolKey, "inventory_dep.run|function|0(Int64)")
            @Expect(string.symbolKey, "inventory_dep.run|function|0(String)")
            let bare = inventoryBudgetLink(markdown, "inventory_dep.run").getOrThrow()
            @Expect(bare.state, "ambiguous")
            @Expect(bare.matchLevel, "none")
            @Expect(bare.url, "")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func duplicateEqualRankedDeclarationsRemainResolved(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let entry = inventoryBudgetLanguageEntry("modern.json", "shared", 0)
            let text = readTextBounded(root.join("modern.json"), 8 * 1024 * 1024)
            let pins = [DocumentInventoryPin(root.join("modern.json").toString(), api_model.contractFingerprint(text))]
            let navigation = inventoryBudgetLanguageNavigation(root, entry + "," + entry, pins)
            @Expect(navigation.state, "resolved")
            @Expect(navigation.matchLevel, "exact")
            @Expect(navigation.symbolKey, "inventory_dep.Token|class|0()")
            @Expect(navigation.url.startsWith("https://docs.example.test/shared/"))
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func differentDocumentSetsSharingADeclarationAndUrlRemainAmbiguousUnlessRanked(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let original = readTextBounded(root.join("modern.json"), 8 * 1024 * 1024)
            let sets = JsonNode.parse(original).asObject()["documentSets"].asArray()
            @Assert(sets.size(), 1)
            let id = sets.get(0).getOrThrow().asObject()["id"].asString()
            let other = original.replace(api_render.escapeJsonString(id), api_render.escapeJsonString(id + "-other"))
            File.writeTo(root.join("other.json"), other.toArray())
            let pins = [DocumentInventoryPin(root.join("modern.json").toString(), api_model.contractFingerprint(original)),
                DocumentInventoryPin(root.join("other.json").toString(), api_model.contractFingerprint(other))]
            let first = inventoryBudgetLanguageEntry("modern.json", "shared", 0)
            let second = inventoryBudgetLanguageEntry("other.json", "shared", 0)
            let higher = inventoryBudgetLanguageEntry("other.json", "shared", 1)
            let firstOnly = inventoryBudgetLanguageNavigation(root, first, pins)
            let secondOnly = inventoryBudgetLanguageNavigation(root, second, pins)
            @Expect(firstOnly.state, "resolved")
            @Expect(secondOnly.state, "resolved")
            @Expect(firstOnly.matchLevel, "exact")
            @Expect(secondOnly.matchLevel, firstOnly.matchLevel)
            @Expect(secondOnly.url, firstOnly.url)
            @Expect(secondOnly.symbolKey, firstOnly.symbolKey)
            @Expect(secondOnly.apiIdentity, firstOnly.apiIdentity)
            @Expect(secondOnly.dependencyInstanceId, firstOnly.dependencyInstanceId)
            @Expect(secondOnly.documentSetId != firstOnly.documentSetId)
            for (documents in [first + "," + second, second + "," + first]) {
                let navigation = inventoryBudgetLanguageNavigation(root, documents, pins)
                @Expect(navigation.state, "ambiguous")
                @Expect(navigation.matchLevel, "none")
                @Expect(navigation.url, "")
            }
            for (documents in [first + "," + second + "," + higher, higher + "," + first + "," + second]) {
                let navigation = inventoryBudgetLanguageNavigation(root, documents, pins)
                @Expect(navigation.state, "resolved")
                @Expect(navigation.matchLevel, "exact")
                @Expect(navigation.documentSetId, secondOnly.documentSetId)
                @Expect(navigation.symbolKey, secondOnly.symbolKey)
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func brokenUnreferencedSourcesDoNotPoisonExactOrManualReferences(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            File.writeTo(root.join("legacy.json"), inventoryBudgetLegacyIndex().toArray())
            File.writeTo(root.join("broken.json"), "{\"schemaVersion\":\"cjdoc.symbol-index/1\",\"symbols\":[],\"symbols\":[]}".toArray())
            File.writeTo(root.join("cjdoc.toml"), (inventoryBudgetLegacyConfig(1) +
                "[external-docs.missing]\nindex = \"missing.json\"\nbase-url = \"https://docs.example.test/missing\"\n" +
                "[external-docs.broken]\nindex = \"broken.json\"\nbase-url = \"https://docs.example.test/broken\"\n").toArray())
            File.writeTo(root.join("unsafe-catalog.json"), ("{\"schemaVersion\":\"cjdoc.doc-sources/1\",\"documents\":[" +
                "{\"index\":\"../modern.json\",\"baseUrl\":\"https://docs.example.test/unsafe\"}," +
                "{\"index\":\"modern.json\",\"baseUrl\":\"https://docs.example.test/modern\"}]}").toArray())
            let result = inventoryBudgetGenerate(root, sources: ["missing-catalog.json", "unsafe-catalog.json"])
            let exact = inventoryBudgetNavigation(result)
            @Expect(exact.state, "resolved")
            @Expect(exact.matchLevel, "exact")
            @Expect(exact.url.startsWith("https://docs.example.test/modern/"))
            let manual = inventoryBudgetManual(result)
            @Expect(manual.state, "resolved")
            @Expect(manual.matchLevel, "manual")
            @Expect(manual.url, "https://docs.example.test/legacy/symbols/token.html")
            @Expect(inventoryBudgetSymbol(result, "legacyUse").parameters[0].typeRef.navigation.getOrThrow().state != "resolved")
            for (reference in result.externalDocumentation) {
                @Expect(!reference.name.startsWith("source-"))
            }
            var rejected: Int64 = 0
            for (diagnostic in result.diagnostics where diagnostic.code == "CJDOC2312") { rejected++ }
            @Expect(rejected >= 4)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func legacyAndModernIndexesShareTheAggregateByteBudget(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let modern = File.readFrom(root.join("modern.json"))
            let modernText = String.fromUtf8(modern)
            inventoryBudgetPad(root.join("modern.json"), modernText, 8 * 1024 * 1024)
            inventoryBudgetPad(root.join("legacy.json"), inventoryBudgetLegacyIndex(), 8 * 1024 * 1024)
            File.writeTo(root.join("cjdoc.toml"), inventoryBudgetLegacyConfig(3).toArray())
            let limited = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            @Expect(inventoryBudgetNavigation(limited).state != "resolved")
            @Expect(inventoryBudgetManual(limited).matchLevel, "manual")
            @Expect(limited.documentSets.size, 0)
            File.writeTo(root.join("cjdoc.toml"), inventoryBudgetLegacyConfig(2).toArray())
            let admitted = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            @Expect(inventoryBudgetNavigation(admitted).matchLevel, "exact")
            @Expect(admitted.documentSets.size, 1)
            inventoryBudgetPad(root.join("modern.json"), modernText, 8 * 1024 * 1024 + 1)
            let oversized = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            @Expect(inventoryBudgetNavigation(oversized).state != "resolved")
            @Expect(inventoryBudgetManual(oversized).matchLevel, "manual")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func failedInventoryDeclarationsStillConsumeTheCombinedCountBudget(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            File.writeTo(root.join("cjdoc.toml"), inventoryBudgetLegacyConfig(255, index: "missing.json").toArray())
            let boundary = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            @Expect(inventoryBudgetNavigation(boundary).matchLevel, "exact")
            @Expect(boundary.documentSets.size, 1)
            File.writeTo(root.join("cjdoc.toml"), inventoryBudgetLegacyConfig(256, index: "missing.json").toArray())
            let overflow = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            @Expect(inventoryBudgetNavigation(overflow).state != "resolved")
            @Expect(overflow.documentSets.size, 0)
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func legacyEntryLimitIsEnforcedBeforeTargetPopulation(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            File.writeTo(root.join("cjdoc.toml"), inventoryBudgetLegacyConfig(1).toArray())
            File.writeTo(root.join("legacy.json"), inventoryBudgetLegacyIndex(count: 32768).toArray())
            @Expect(inventoryBudgetManual(inventoryBudgetGenerate(root)).matchLevel, "manual")
            File.writeTo(root.join("legacy.json"), inventoryBudgetLegacyIndex(count: 32769).toArray())
            let overflow = inventoryBudgetGenerate(root)
            @Expect(inventoryBudgetManual(overflow).state != "resolved")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func actualModernDocumentSetsShareTheLegacySetLimit(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            File.writeTo(root.join("cjdoc.toml"), inventoryBudgetLegacyConfig(1).toArray())
            File.writeTo(root.join("legacy.json"), inventoryBudgetLegacyIndex().toArray())
            for (count in [255, 256]) {
                let text = StringBuilder()
                text.append("{\"schemaVersion\":\"cjdoc.symbol-index/2\",\"entries\":[],\"documentSets\":[")
                for (index in 0..count) {
                    if (index != 0) { text.append(",") }
                    text.append("{\"id\":\"set-" + index.toString() + "\",\"library\":\"unused\"," +
                        "\"identity\":\"declared-identity\",\"state\":\"declared\",\"source\":\"manual\"}")
                }
                text.append("]}")
                File.writeTo(root.join("modern.json"), text.toString().toArray())
                let result = inventoryBudgetGenerate(root, sources: ["catalog.json"])
                @Expect(result.documentSets.size, if (count == 255) { 255 } else { 0 })
                @Expect(inventoryBudgetManual(result).matchLevel, "manual")
            }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func sourceLimitAccepts64AndRejects65WithoutSilentlyTruncating(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            File.writeTo(root.join("empty-catalog.json"),
                "{\"schemaVersion\":\"cjdoc.doc-sources/1\",\"documents\":[]}".toArray())
            let sources = ArrayList<String>(["catalog.json"])
            for (_ in 0..63) { sources.add("empty-catalog.json") }
            @Expect(inventoryBudgetNavigation(inventoryBudgetGenerate(root, sources: sources.toArray())).matchLevel, "exact")
            sources.add("empty-catalog.json")
            @ExpectThrows[IllegalArgumentException](inventoryBudgetGenerate(root, sources: sources.toArray()))
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func publisherClaimsCannotSelfVerifyAndHostPinsRejectCompletePayloadTampering(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let binary = getVariable("CJDOC_I18N_BINARY").getOrDefault({ => "target/release/bin/main" })
            let path = root.join("modern.json")
            let original = readTextBounded(path, 8 * 1024 * 1024)
            let pin = DocumentInventoryPin(path.toString(), api_model.contractFingerprint(original))
            let forged = original.replace("source-snapshot", "invented author statement only")
                .replace("\"state\":\"observed\"", "\"state\":\"verified\"")
                .replace("\"href\":\"", "\"href\":\"forged/")
            File.writeTo(path, forged.toArray())
            let unpinned = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                documentSources: ["catalog.json"], astPreflightExecutable: Some(binary)))
            @Expect(inventoryBudgetNavigation(unpinned).matchLevel, "manual")
            @Expect(unpinned.documentSets[0].state, "declared")
            let pinned = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                documentSources: ["catalog.json"], documentInventoryPins: [pin], astPreflightExecutable: Some(binary)))
            @Expect(inventoryBudgetNavigation(pinned).state != "resolved")
            @Expect(pinned.documentSets.isEmpty())
            @Expect(publicHasDiagnostic(pinned, "CJDOC2312"))
            File.writeTo(path, original.toArray())
            let trusted = DocumentationEngine().generate(GenerationRequest(root.toString(), lintProfile: "off",
                documentSources: ["catalog.json"], documentInventoryPins: [pin], astPreflightExecutable: Some(binary)))
            @Expect(inventoryBudgetNavigation(trusted).matchLevel, "exact")
            @Expect(trusted.documentSets[0].state, "declared")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func modernDocumentationOnlyReferencesStayManualWithoutInventingDependencies(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            File.writeTo(root.join("cjpm.toml"), "[package]\nname = \"inventory_app\"\nversion = \"1.0.0\"\n".toArray())
            File.writeTo(root.join("src/api.cj"), ("package inventory_app\n" +
                "/** {@link inventory_dep.Token}.\n * @see inventory_dep.Token Documentation-only target.\n */\n" +
                "public func use(value: Int64): Unit {}\n").toArray())
            let result = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            let symbol = inventoryBudgetSymbol(result, "use")
            let navigation = inventoryBudgetLink(symbol.documentation.getOrThrow().markdown, "inventory_dep.Token").getOrThrow()
            @Expect(navigation.state, "resolved")
            @Expect(navigation.matchLevel, "manual")
            @Expect(navigation.dependencyInstanceId, "")
            @Expect(navigation.documentSetId.isEmpty(), false)
            for (dependency in result.dependencies) { @Expect(dependency.name != "inventory_dep") }
            for (tag in symbol.documentation.getOrThrow().tags where tag.name == "see") {
                @Expect(tag.navigation.getOrThrow().matchLevel, "manual")
                @Expect(tag.navigation.getOrThrow().dependencyInstanceId, "")
            }
            if (let Some(decision) <- symbol.parameters[0].typeRef.navigation) { @Expect(decision.state != "resolved") }
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func privateInventoryEntriesCannotBypassThePublishedExternalAudience(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let path = root.join("modern.json")
            let original = readTextBounded(path, 8 * 1024 * 1024)
            let restricted = original.replace("\"visibility\":\"public\"", "\"visibility\":\"private\"")
                .replace("\"visibility\": \"public\"", "\"visibility\": \"private\"")
            @Expect(restricted != original)
            File.writeTo(path, restricted.toArray())
            let result = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            @Expect(inventoryBudgetNavigation(result).state != "resolved")
            @Expect(result.apiCollectionState, "resolved")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }

    @TestCase
    func aMatchingHostPinCannotMakeContradictoryPackageVersionMetadataCoherent(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            let root = inventoryBudgetProject(temporary)
            let path = root.join("modern.json")
            let original = readTextBounded(path, 8 * 1024 * 1024)
            let contradictory = original.replace("\"apiVersion\":\"1.0.0\"", "\"apiVersion\":\"2.0.0\"")
            @Expect(contradictory != original)
            File.writeTo(path, contradictory.toArray())
            let result = inventoryBudgetGenerate(root, sources: ["catalog.json"])
            @Expect(inventoryBudgetNavigation(result).state != "resolved")
            @Expect(publicHasDiagnostic(result, "CJDOC2312"))
            @Expect(result.apiCollectionState, "resolved")
        } finally { let _ = removeIfExists(temporary, recursive: true) }
    }
}
