package cjdoc

import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private func externalTestResponse(source: String, spans: String): String {
    "{\"protocol\":\"cjdoc-highlight/1\",\"id\":\"test\",\"language\":\"python\"," +
    "\"engine\":{\"id\":\"highlight.js\",\"revision\":\"11.11.1/cjdoc-map-1\"}," +
    "\"state\":\"complete\",\"byteLength\":${source.size},\"sourceHash\":\"${Sha256Digest.digest(source)}\",\"spans\":${spans}}\n"
}

private func externalTestNode(): ?String {
    if (let Some(path) <- getVariable("CJDOC_HIGHLIGHT_NODE")) { return Some(path) }
    if (let Some(paths) <- getVariable("PATH")) {
        for (path in paths.split(":")) {
            let candidate = Path(path).join("node")
            if (exists(candidate)) { return Some(canonicalize(candidate).toString()) }
        }
    }
    None
}

private func externalTestBlocks(node: JsonNode, result: ArrayList<JsonObject>): Unit {
    if (node.kind() == JsonKind.Object) {
        let object = node.asObject()
        if (let Some(kind) <- object.get("kind")) {
            if (kind.kind() == JsonKind.String && kind.asString() == "code_block") { result.add(object) }
        }
        for (index in 0..object.size()) { externalTestBlocks(object.valueAt(index), result) }
    } else if (node.kind() == JsonKind.Array) {
        let array = node.asArray()
        for (index in 0..array.size()) { externalTestBlocks(array.get(index).getOrThrow(), result) }
    }
}

@Test
class CodeHighlightExternalTest {
    @TestCase
    func responseValidationRejectsWholePayload(): Unit {
        let source = "True中"
        let valid = externalTestResponse(source, "[{\"startByte\":0,\"endByte\":4,\"kind\":\"literal\"}]")
        @Expect(validateExternalHighlightResponse(source, "python", "test", valid).spans().size, 1)
        let badRanges = [
            "[{\"startByte\":4,\"endByte\":7,\"kind\":\"string\"},{\"startByte\":0,\"endByte\":4,\"kind\":\"literal\"}]",
            "[{\"startByte\":0,\"endByte\":4,\"kind\":\"literal\"},{\"startByte\":3,\"endByte\":7,\"kind\":\"string\"}]",
            "[{\"startByte\":0,\"endByte\":8,\"kind\":\"string\"}]",
            "[{\"startByte\":0,\"endByte\":5,\"kind\":\"string\"}]",
            "[{\"startByte\":0,\"endByte\":4,\"kind\":\"html\"}]"
        ]
        let invalid = ArrayList<String>([
            valid.replace("cjdoc-highlight/1", "wrong"), valid.replace("\"test\"", "\"other\""),
            valid.replace("cjdoc-map-1", "cjdoc-map-2"), valid.replace("highlight.js", "other"),
            valid.replace("\"python\"", "\"json\""), valid.replace("\"complete\"", "\"partial\""),
            valid.replace("\"state\":\"complete\"", "\"state\":\"plain\",\"reason\":\"unknown\""),
            valid.replace("\"state\":\"complete\"", "\"state\":\"plain\",\"reason\":\"backend-unavailable\""),
            valid.replace(Sha256Digest.digest(source), Sha256Digest.digest("other")),
            valid.replace("\"byteLength\":7", "\"byteLength\":8"),
            valid.replace("\"id\":\"test\"", "\"id\":\"test\",\"id\":\"test\""),
            valid.replace("\"state\"", "\"html\":\"unsafe\",\"state\""), valid + valid,
            valid.removeSuffix("\n")
        ])
        for (ranges in badRanges) { invalid.add(externalTestResponse(source, ranges)) }
        for (payload in invalid) {
            let result = validateExternalHighlightResponse(source, "python", "test", payload)
            @Expect(match (result.state) { case CodeHighlightState.Plain => true; case _ => false })
            @Expect(result.spans().size, 0)
        }
    }

    @TestCase
    func plainResponsesMapOnlyFixedReasons(): Unit {
        let complete = externalTestResponse("True", "[]")
        for ((wire, reason) in [("unsupported-language", "unsupported"), ("resource-limit", "resource-limit"),
            ("invalid-spans", "invalid-spans"),
            ("malformed-json", "backend-unavailable"), ("invalid-request", "backend-unavailable")]) {
            let payload = complete.replace("\"state\":\"complete\"", "\"state\":\"plain\",\"reason\":\"" + wire + "\"")
            let result = validateExternalHighlightResponse("True", "python", "test", payload)
            @Expect(result.reason, Some(reason))
            @Expect(result.spans().size, 0)
        }
    }

    @TestCase
    func defaultAndBuiltinNeverLaunchExternalProcess(): Unit {
        let source = "let 名称 = 1\n"
        let normal = publicCodeHighlight(source, "cj")
        @Expect(normal.state, "complete")
        @Expect(normal.engineId, CANGJIE_HIGHLIGHT_ENGINE)
        @Expect(publicCodeHighlight("True", "python").reason, Some("backend-unavailable"))
        // Even authorized nonexistent executables are ignored by the built-in route.
        let missing = HighlightExternalOptions(getWorkingDirectory().join("missing-cjdoc-node").toString(),
            getWorkingDirectory().join("missing-cjdoc-adapter").toString())
        let builtin = publicCodeHighlight(source, "cj", externalOptions: Some(missing))
        @Expect(builtin.state, normal.state)
        @Expect(builtin.spans.size, normal.spans.size)
    }

    @TestCase
    func publicRequestRequiresAbsolutePairedPaths(): Unit {
        let adapter = getWorkingDirectory().join("adapter.mjs").toString()
        let node = getWorkingDirectory().join("node").toString()
        @ExpectThrows[IllegalArgumentException](GenerationRequest("unused", highlightAdapter: Some(adapter)))
        @ExpectThrows[IllegalArgumentException](GenerationRequest("unused", highlightNode: Some(node)))
        @ExpectThrows[IllegalArgumentException](GenerationRequest("unused", highlightAdapter: Some("relative"), highlightNode: Some(node)))
        @ExpectThrows[IllegalArgumentException](GenerationRequest("unused", highlightAdapter: Some(adapter), highlightNode: Some("")))
        @Expect(GenerationRequest("unused", highlightAdapter: Some(adapter), highlightNode: Some(node)).highlightNode, Some(node))
    }

    @TestCase
    func realBinaryHighlightsPinnedAdapterWhenProvisioned(): Unit {
        let node = externalTestNode()
        if (!exists("tools/highlight/adapter.mjs") || !exists("tools/highlight/node_modules/highlight.js") || node.isNone()) {
            println("SKIPPED / UNVERIFIED: pinned external highlighting requires offline-provisioned tools/highlight/node_modules/highlight.js and Node")
            return
        }
        let root = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(root.join("src"))
            File.writeTo(root.join("cjpm.toml"), "[package]\nname = \"external_test\"\nversion = \"1.0.0\"\noutput-type = \"static\"\n".toArray())
            File.writeTo(root.join("src/lib.cj"), ("package external_test\n/**\n * Examples.\n *\n" +
                " * ```python\n * True\n * ```\n *\n * ```json\n * true\n * ```\n */\npublic func example(): Unit {}\n").toArray())
            let (exitCode, output, _) = executeWithBoundedOutput(canonicalize("target/release/bin/main").toString(),
                ["generate", "--project", root.toString(), "--format", "json", "--stdout", "--no-cache",
                 "--highlight-adapter", canonicalize("tools/highlight/adapter.mjs").toString(),
                 "--highlight-node", node.getOrThrow()], outputLimit: 1024 * 1024)
            @Assert(exitCode, 0)
            let blocks = ArrayList<JsonObject>()
            externalTestBlocks(JsonNode.parse(String.fromUtf8(output)), blocks)
            @Assert(blocks.size, 2)
            for (block in blocks) {
                let code = block["literal"].asString()
                let highlight = block["metadata"].asObject()["codeHighlight"].asObject()
                @Expect(highlight["state"].asString(), "complete")
                @Expect(highlight["engineId"].asString(), EXTERNAL_HIGHLIGHT_ENGINE)
                @Expect(highlight["engineRevision"].asString(), EXTERNAL_HIGHLIGHT_REVISION)
                let spans = highlight["spans"].asArray()
                @Assert(spans.size() > 0)
                let restored = StringBuilder()
                var end: Int64 = 0
                for (index in 0..spans.size()) {
                    let span = spans.get(index).getOrThrow().asObject()
                    let start = span["startByte"].asInt64()
                    let next = span["endByte"].asInt64()
                    restored.append(code[end..start]); restored.append(code[start..next]); end = next
                }
                restored.append(code[end..])
                @Expect(restored.toString().toArray(), code.toArray())
            }
        } finally { let _ = removeIfExists(root, recursive: true) }
    }
}
