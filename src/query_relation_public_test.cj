package cjdoc

import cjdoc.model.*
import cjdoc.model as api_model
import cjdoc.render as relation_render
import std.unittest.*
import std.unittest.testmacro.*
import yjson.*

private let RELATION_MODULE = "cjdoc:module:v1:root"
private let RELATION_TARGET = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aroot::fixture::class:Target#g0()"
private let RELATION_ENTRY = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aroot::fixture::function:entry#g0()"

private func relationRange(version: String, line: Int64): SourceRange {
    SourceRange("src/api-${version}.cj", SourcePosition(line, 1, 0), SourcePosition(line, 30, 29))
}

private func relationDocumentation(version: String, navigation: ?TypeNavigation,
    revision!: String = "reference"): api_model.DocumentationSet {
    let target = api_model.SymbolDoc(RELATION_TARGET, "class", "Target", "fixture.Target", "fixture",
        RELATION_MODULE, "public", relationRange(version, 1), "public class Target",
        SemanticInfo("partial", "ast"))
    let tags: Array<api_model.DocTag> = match (navigation) {
        case Some(value) => [api_model.DocTag("see", "fixture.Target", "Captured external target",
            navigation: Some(value))]
        case None => []
    }
    let entry = api_model.SymbolDoc(RELATION_ENTRY, "function", "entry", "fixture.entry", "fixture",
        RELATION_MODULE, "public", relationRange(version, 4), "public func entry(): Unit",
        SemanticInfo("partial", "ast"), documentation: Some(api_model.DocComment("", "Entry", "",
            MarkdownNode("document"), tags: tags)))
    api_model.DocumentationSet(GeneratorInfo("cjdoc", "test"), "complete", ProjectInfo("relation-fixture"),
        ConfigurationSnapshot(lintProfile: "off"), documentationRevision: revision,
        providers: [ProviderInfo("ast", "builtin", RELATION_MODULE, "partial",
            api_model.SemanticCapabilities(false, false, false, false, false))],
        modules: [api_model.ModuleDoc(RELATION_MODULE, "fixture", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", RELATION_MODULE, sourceFiles: ["src/api-${version}.cj"],
            symbolIds: [RELATION_TARGET, RELATION_ENTRY])],
        files: [FileDoc("src/api-${version}.cj", RELATION_MODULE, "fixture")],
        declarations: [target, entry], dependencies: [DependencyInstance(RELATION_MODULE,
            "fixture", "captured-root-${version}", "source", "sha256:" + contractFingerprint(version),
            "observed", "controlled captured-source fixture", version: version,
            componentModuleId: RELATION_MODULE)])
}

private func capturedTargetNavigation(target: api_model.DocumentationSet): TypeNavigation {
    let snapshot = relation_render.DocumentationReadSnapshot(target)
    let identity = snapshot.documentSetForModule(RELATION_MODULE).getOrThrow()
    TypeNavigation("resolved", "manual", "Explicit captured API identity and portable key",
        documentSetId: "producer-local-dependency-context",
        apiIdentity: identity.identity,
        symbolKey: portableSymbolKey("fixture", "fixture.Target", "class", 0),
        url: "dependencies/fixture.html")
}

private func relatedRequest(root: String, related: Array<String>): JsonObject {
    let request = JsonNode.object()
    request.put("operation", JsonNode.string("get_symbol"))
    request.put("snapshotId", JsonNode.string(root))
    request.put("symbolId", JsonNode.string(RELATION_ENTRY))
    let snapshots = JsonNode.array()
    for (id in related) { snapshots.add(JsonNode.string(id)) }
    request.put("relatedSnapshotIds", snapshots)
    let sections = JsonNode.array()
    sections.add(JsonNode.string("relations"))
    request.put("sections", sections)
    let relations = JsonNode.object()
    relations.put("direction", JsonNode.string("outgoing"))
    relations.put("depth", JsonNode.int64(1))
    relations.put("limit", JsonNode.int64(10))
    request.put("relations", relations)
    request
}

@Test
class DocumentationQueryRelationPublicTest {
    @TestCase
    func sameLocalTargetIdDoesNotOverrideTheCapturedExternalSnapshot(): Unit {
        let dependency = relationDocumentation("0.2.0", Option<TypeNavigation>.None)
        let host = relationDocumentation("0.1.0", Some(capturedTargetNavigation(dependency)))
        let hostId = relation_render.documentationSnapshotId(host)
        let dependencyId = relation_render.documentationSnapshotId(dependency)
        let session = DocumentationQuerySession([host, dependency])
        let request = relatedRequest(hostId, [dependencyId])
        let response = JsonNode.parse(session.execute(request.toJson())).asObject()
        @Expect(response.get("status").getOrThrow().asString(), "ok")
        let rows = response.get("result").getOrThrow().asObject().get("relations").getOrThrow().asArray()
        @Expect(rows.size(), 1)
        let edge = rows[0].asObject()
        let target = edge.get("to").getOrThrow().asObject()
        @Expect(target.get("symbolId").getOrThrow().asString(), RELATION_TARGET)
        @Expect(target.get("snapshotId").getOrThrow().asString(), dependencyId)
        @Expect(edge.get("from").getOrThrow().asObject().get("snapshotId").getOrThrow().asString(), hostId)
        @Expect(edge.get("navigation").getOrThrow().asObject().get("matchLevel").getOrThrow().asString(), "manual")
        @Expect(edge.get("source").getOrThrow().asObject().get("range").getOrThrow()
            .asObject().get("path").getOrThrow().asString(), "src/api-0.2.0.cj")
        let page = response.get("completeness").getOrThrow().asObject().get("query").getOrThrow().asObject()
        @Expect(page.get("scope").getOrThrow().asString(), "relations")
        @Expect(page.get("returned").getOrThrow().asInt64(), rows.size())
        @Expect(page.get("total").getOrThrow().isNull, true)
    }

    @TestCase
    func multipleCapturedEditionsDoNotChooseTheFirstRelatedTarget(): Unit {
        let dependency = relationDocumentation("0.2.0", Option<TypeNavigation>.None)
        let alternate = relationDocumentation("0.2.0", Option<TypeNavigation>.None, revision: "other-edition")
        let host = relationDocumentation("0.1.0", Some(capturedTargetNavigation(dependency)))
        let session = DocumentationQuerySession([host, dependency, alternate])
        let request = relatedRequest(relation_render.documentationSnapshotId(host),
            [relation_render.documentationSnapshotId(dependency), relation_render.documentationSnapshotId(alternate)])
        let response = JsonNode.parse(session.execute(request.toJson())).asObject()
        let rows = response.get("result").getOrThrow().asObject().get("relations").getOrThrow().asArray()
        @Expect(rows.size(), 1)
        let edge = rows[0].asObject()
        @Expect(edge.get("state").getOrThrow().asString(), "ambiguous")
        @Expect(edge.get("to").getOrThrow().isNull, true)
        @Expect(edge.get("source").getOrThrow().isNull, true)
        let missing = relatedRequest(relation_render.documentationSnapshotId(host), ["cjdoc:snapshot:v1:absent"])
        let refused = JsonNode.parse(session.execute(missing.toJson())).asObject()
        @Expect(refused.get("status").getOrThrow().asString(), "scope_mismatch")
    }
}
