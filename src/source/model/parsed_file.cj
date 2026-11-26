protected package cjdoc.source.model

import cjdoc.source.Diagnostic
import std.collection.ArrayList

protected class SourceInputFile {
    protected let actualPath: String
    protected let actualRoot: String
    protected let logicalPath: String
    protected let module: SourceModule
    protected let discoveredSize: Int64

    protected init(actualPath: String, actualRoot: String, logicalPath: String, module: SourceModule,
        discoveredSize: Int64) {
        this.actualPath = actualPath
        this.actualRoot = actualRoot
        this.logicalPath = logicalPath
        this.module = module
        this.discoveredSize = discoveredSize
    }
}

protected class ParsedSourceFile {
    protected let input: SourceInputFile
    protected var packageName: ?String = None
    protected var capturedSourceIndex: ?CapturedSourceIndex = None
    protected var capturedSourceFacts: ?CapturedSourceFacts = None
    protected var capturedSource: String = ""
    protected let imports = ArrayList<String>()
    protected let packageImports = ArrayList<String>()
    protected let importFacts = ArrayList<SourceImportFacts>()
    protected let declarations = ArrayList<SourceDeclaration>()
    protected let reExports = ArrayList<SourceReExport>()
    protected let orphanDocComments = ArrayList<OrphanDocComment>()
    protected let macroInvocations = ArrayList<MacroInvocation>()
    protected let unsupportedDeclarations = ArrayList<UnsupportedDeclaration>()
    protected let diagnostics = ArrayList<Diagnostic>()
    protected var cacheStatus = "disabled"

    protected init(input: SourceInputFile) { this.input = input }
}

protected func withCapturedSourceFacts(parsed: ParsedSourceFile,
    facts: CapturedSourceFacts): ParsedSourceFile {
    if (facts.index.available) { parsed.capturedSourceIndex = Some(facts.index) }
    parsed.capturedSourceFacts = Some(facts)
    parsed
}
