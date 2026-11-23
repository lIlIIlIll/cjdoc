protected package cjdoc.source

protected class Diagnostic {
    protected let severity: String
    protected let code: String
    protected let message: String
    protected let source: ?SourceLocation
    protected let symbolId: ?String

    protected init(severity: String, code: String, message: String,
        source!: ?SourceLocation = None, symbolId!: ?String = None) {
        this.severity = severity
        this.code = code
        this.message = message
        this.source = source
        this.symbolId = symbolId
    }
}
