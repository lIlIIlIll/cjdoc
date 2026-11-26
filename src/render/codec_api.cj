package cjdoc.render

public import cjdoc.render.codec.{
    decodeDocIr, encodeDocIr, escapeJsonString, validateDocumentationArtifactJson, validateDocumentationSet}

public import cjdoc.render.search.searchTextExcerpt
public import cjdoc.render.html.{
    HtmlFontOptions, attachReportEvidence, escapeStandaloneHtml, isValidHtmlFontFamilyList,
    renderStandaloneMarkdownHtml, standaloneMarkdownFragment}
public import cjdoc.render.publication.{SourceReference, sourceReferenceJson, projectPublicationDocumentation,
    projectDocumentationLanguage}
public import cjdoc.render.agent.{
    DocumentationReadSnapshot, DocumentationReportAttachment, documentationSnapshotId, renderAgentReadableArtifacts}
