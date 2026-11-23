protected package cjdoc.source.model

import cjdoc.source.Diagnostic
import std.collection.ArrayList

protected func hasFatalSourceDiagnostics(source: SourceSnapshot): Bool {
    for (diagnostic in source.diagnostics) {
        if (diagnostic.severity == "error" && diagnostic.code != "CJDOC1011" &&
            diagnostic.code != "CJDOC1012" && diagnostic.code != "CJDOC1020" &&
            diagnostic.code != "CJDOC1028") { return true }
    }
    return false
}

protected func addSourceLimitDiagnostic(diagnostics: ArrayList<Diagnostic>, message: String): Unit {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == "CJDOC1028") { return }
    }
    diagnostics.add(Diagnostic("error", "CJDOC1028", message))
}

protected func hasSourceLimitDiagnostic(diagnostics: ArrayList<Diagnostic>): Bool {
    for (diagnostic in diagnostics) {
        if (diagnostic.code == "CJDOC1028") { return true }
    }
    false
}
