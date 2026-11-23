protected package cjdoc.source

protected class SourceLocation {
    protected let path: String
    protected let startLine: Int64
    protected let startColumn: Int64
    protected let endLine: Int64
    protected let endColumn: Int64

    protected init(path: String, startLine: Int64, startColumn: Int64, endLine: Int64, endColumn: Int64) {
        this.path = path
        this.startLine = startLine
        this.startColumn = startColumn
        this.endLine = endLine
        this.endColumn = endColumn
    }
}
