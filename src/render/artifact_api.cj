package cjdoc.render

import cjdoc.render.publication.projectDocumentationLanguage
import cjdoc.render.agent.appendSymbolIndexArtifacts
import cjdoc.model.DocumentationSet
import cjdoc.render.codec.docIrFitsEncodedBudget
import cjdoc.render.foundation.{RENDER_ARTIFACT_LIMIT, RenderArtifactCollector, RenderArtifactStore}
public import cjdoc.render.foundation.{RenderArtifact, RenderResourceLimitException}
public import cjdoc.render.routes.documentationSectionAnchor
public import cjdoc.render.reading.isBehaviorContractTag

public interface DocumentationRenderer {
    prop format: String
    func render(documentation: DocumentationSet): Array<RenderArtifact>
}

public class JsonDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "json" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        appendJsonArtifacts(artifacts, documentation)
        artifacts.toArray()
    }
}
public class MarkdownDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "markdown" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let locale = documentation.readingLanguage.getOrDefault({ => "en" })
        renderDocumentationFormatsWithOptions(documentation, ["markdown"], locale: locale)
    }
}

public class SymbolIndexDocumentationRenderer <: DocumentationRenderer {
    public prop format: String { get() { "symbol-index" } }

    public func render(documentation: DocumentationSet): Array<RenderArtifact> {
        let artifacts = RenderArtifactCollector()
        let locale = documentation.readingLanguage.getOrDefault({ => "en" })
        appendSymbolIndexArtifacts(artifacts, projectDocumentationLanguage(documentation, locale))
        artifacts.toArray()
    }
}


internal func appendJsonArtifacts(artifacts: RenderArtifactStore, documentation: DocumentationSet): Unit {
    if (!docIrFitsEncodedBudget(documentation, RENDER_ARTIFACT_LIMIT)) {
        throw RenderResourceLimitException("Doc IR JSON exceeds ${RENDER_ARTIFACT_LIMIT} bytes")
    }
    let _ = artifacts.addText("docs.json", "application/json", encodeDocIr(documentation))
}
