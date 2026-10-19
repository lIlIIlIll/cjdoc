package dependency_public_api

import cjdoc.*
import cjdoc.render.{encodeDocIr}
import std.collection.*
import std.env.*
import std.fs.*

private func optionalPath(value: String): ?String {
    if (value == "-") { None } else { Some(value) }
}

// This program is compiled as a separate package. It imports only exported API;
// it cannot call cjdoc's internal request adapter, CLI parser or identity helpers.
main(): Int64 {
    let arguments = getCommandLine()
    if (arguments.size != 13) {
        throw IllegalArgumentException("expected project/output/preflight/receipt/catalog/pin/digest/language/fallback/compatible/revision/extra-catalog")
    }
    let sources = ArrayList<String>()
    for (index in [5, 12]) {
        if (arguments[index] != "-") { sources.add(arguments[index]) }
    }
    let pins = ArrayList<DocumentInventoryPin>()
    if (arguments[6] != "-") { pins.add(DocumentInventoryPin(arguments[6], arguments[7])) }
    let request = GenerationRequest(arguments[1], lintProfile: "off",
        astPreflightExecutable: Some(arguments[3]), buildContext: optionalPath(arguments[4]),
        documentSources: sources.toArray(), documentInventoryPins: pins.toArray(),
        linkLanguage: if (arguments[8] == "-") { "" } else { arguments[8] },
        linkLanguageFallback: arguments[9] == "true", linkCompatible: arguments[10] == "true",
        documentationRevision: arguments[11])
    let documentation = DocumentationEngine().generate(request)
    File.writeTo(Path(arguments[2]), encodeDocIr(documentation).toArray())
    0
}
