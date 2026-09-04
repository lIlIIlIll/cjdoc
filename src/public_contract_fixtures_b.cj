package cjdoc

import cjdoc.model as api_model
import cjdoc.provider as api_provider
import std.collection.*
import std.fs.*

@When[os != "Linux"]
import std.posix.*

internal class InvalidBatchSession <: api_provider.SemanticProviderSession {
    private let mode: String
    private let lifecycle: ProviderLifecycle

    init(mode: String, lifecycle: ProviderLifecycle) {
        this.mode = mode
        this.lifecycle = lifecycle
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        let canonicalTypeMode = mode == "empty-canonical-type" || mode == "blank-canonical-type"
        let canonicalSignatureMode = mode == "empty-canonical-signature" ||
            mode == "blank-canonical-signature" || mode == "unavailable-canonical-signature"
        let capabilities = api_model.SemanticCapabilities(true, false, false, canonicalTypeMode, canonicalSignatureMode,
            annotations: mode == "annotation" || mode == "relationship-annotation-budget")
        if (mode == "annotation") {
            return api_provider.SemanticBatch(capabilities,
                declarations: [api_provider.SemanticDeclaration(declarations[0].id, "partial", annotations: [""],
                    annotationsProvided: true)])
        }
        if (mode == "relationship-annotation-budget") {
            let annotations = ArrayList<String>()
            var index: Int64 = 0
            while (index < 16385) {
                annotations.add("@ProviderMeta");
                index++
            }
            return api_provider.SemanticBatch(capabilities,
                declarations: [api_provider.SemanticDeclaration(declarations[0].id, "partial",
                    annotations: annotations.toArray(), annotationsProvided: true)])
        }
        if (mode == "type") {
            for (declaration in declarations) {
                if (declaration.parameters.isEmpty()) {
                    continue
                }
                let parameters = ArrayList<api_provider.SemanticParameter>()
                var index: Int64 = 0
                while (index < declaration.parameters.size) {
                    let sourceParameter = declaration.parameters[index]
                    let typeRef = api_model.TypeRef(if (index == 0) {
                        ""
                    } else {
                        "source"
                    }, sourceParameter.typeSpelling, api_model.SemanticType("partial"))
                    parameters.add(api_provider.SemanticParameter(sourceParameter.name, typeRef))
                    index++
                }
                return api_provider.SemanticBatch(capabilities,
                    declarations: [api_provider.SemanticDeclaration(declaration.id, "partial",
                        parameters: parameters.toArray())])
            }
        }
        if (canonicalTypeMode) {
            let invalidCanonical = if (mode == "empty-canonical-type") {
                ""
            } else {
                " \t "
            }
            for (declaration in declarations) {
                if (declaration.parameters.isEmpty()) {
                    continue
                }
                let parameters = ArrayList<api_provider.SemanticParameter>()
                for (parameter in declaration.parameters) {
                    parameters.add(
                        api_provider.SemanticParameter(parameter.name,
                            api_model.TypeRef("semantic", parameter.typeSpelling,
                                api_model.SemanticType("partial", canonical: Some(invalidCanonical),
                                    provider: Some("invalid-${mode}-test")))))
                }
                return api_provider.SemanticBatch(capabilities,
                    declarations: [api_provider.SemanticDeclaration(declaration.id, "partial",
                        parameters: parameters.toArray())])
            }
        }
        if (canonicalSignatureMode) {
            let invalidCanonical = if (mode == "empty-canonical-signature") {
                ""
            } else if (mode == "blank-canonical-signature") {
                " \t "
            } else {
                "public func hostile(): Unit"
            }
            let state = if (mode == "unavailable-canonical-signature") { "unavailable" } else { "partial" }
            return api_provider.SemanticBatch(capabilities,
                declarations: [api_provider.SemanticDeclaration(declarations[0].id, state,
                    canonicalSignature: Some(invalidCanonical))])
        }
        if (mode == "deep-type") {
            return api_provider.SemanticBatch(capabilities,
                declarations: [api_provider.SemanticDeclaration(declarations[0].id, "partial",
                    returnType: Some(deeplyNestedProviderType()))])
        }
        if (mode == "foreign-provider") {
            let nested = api_model.TypeRef("semantic", "Outer<Inner>", api_model.SemanticType("partial"),
                arguments: [api_model.TypeRef("semantic", "Inner",
                    api_model.SemanticType("partial", provider: Some("foreign-provider")))])
            return api_provider.SemanticBatch(capabilities,
                declarations: [api_provider.SemanticDeclaration(declarations[0].id, "partial", returnType: Some(nested))])
        }
        if (mode == "type-budget") {
            let arguments = ArrayList<api_model.TypeRef>()
            var index: Int64 = 0
            while (index < 16385) {
                arguments.add(api_model.TypeRef("semantic", "Leaf", api_model.SemanticType("partial")))
                index++
            }
            let wide = api_model.TypeRef("semantic", "Wide", api_model.SemanticType("partial"),
                arguments: arguments.toArray())
            return api_provider.SemanticBatch(capabilities,
                declarations: [api_provider.SemanticDeclaration(declarations[0].id, "partial", returnType: Some(wide))])
        }

        if (mode == "declaration-budget") {
            let excessive = ArrayList<api_provider.SemanticDeclaration>()
            var index: Int64 = 0
            while (index <= declarations.size) {
                excessive.add(api_provider.SemanticDeclaration(declarations[0].id, "partial"))
                index++
            }
            return api_provider.SemanticBatch(capabilities, declarations: excessive.toArray())
        }

        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        if (mode == "diagnostic-budget") {
            let diagnostics = ArrayList<api_model.Diagnostic>()
            var index: Int64 = 0
            while (index < 4097) {
                diagnostics.add(api_model.Diagnostic("warning", "CJDOC2998", "provider diagnostic ${index}"))
                index++
            }
            return api_provider.SemanticBatch(capabilities, declarations: converted.toArray(),
                diagnostics: diagnostics.toArray())
        }
        let diagnostic = if (mode == "range") {
            api_model.Diagnostic("warning", "CJDOC2998", "invalid range",
                source: Some(
                    api_model.SourceRange("../outside.cj", api_model.SourcePosition(1, 1, 0),
                        api_model.SourcePosition(1, 2, 1))))
        } else if (mode == "out-of-bounds") {
            api_model.Diagnostic("warning", "CJDOC2998", "out-of-bounds range",
                source: Some(
                    api_model.SourceRange(declarations[0].source.path, api_model.SourcePosition(1, 1, 999999),
                        api_model.SourcePosition(1, 2, 1000000))))
        } else if (mode == "text-budget") {
            api_model.Diagnostic("warning", "CJDOC2998", String.fromUtf8(Array<Byte>(16 * 1024 * 1024 + 1, repeat: b'x')))
        } else {
            api_model.Diagnostic("warning", "CJDOC2998", "")
        }
        api_provider.SemanticBatch(capabilities, declarations: converted.toArray(), diagnostics: [diagnostic])
    }

    public func close(): Unit {
        lifecycle.closed++
    }
}

internal class InvalidBatchFactory <: api_provider.SemanticProviderFactory {
    private let mode: String
    private let lifecycle: ProviderLifecycle

    init(mode: String, lifecycle: ProviderLifecycle) {
        this.mode = mode
        this.lifecycle = lifecycle
    }

    public prop name: String {
        get() {
            "invalid-${mode}-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        InvalidBatchSession(mode, lifecycle)
    }
}

internal class LateReferenceSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        var index: Int64 = 0
        while (index < declarations.size) {
            if (index == 0) {
                converted.add(
                    api_provider.SemanticDeclaration(declarations[index].id, "partial",
                        symbolRelationships: [api_provider.SemanticSymbolRelationship("related", "missing", "resolved",
                            targetSymbolId: Some("cjdoc:v2:missing"))]))
            } else {
                converted.add(api_provider.SemanticDeclaration(declarations[index].id, "partial"))
            }
            index++
        }
        api_provider.SemanticBatch(
            api_model.SemanticCapabilities(true, false, false, false, false, relationships: true),
            declarations: converted.toArray(),
            diagnostics: [
                api_model.Diagnostic("warning", "CJDOC2998", "provider diagnostic"),
                api_model.Diagnostic("warning", "CJDOC2999", "late diagnostic identity",
                    symbolId: Some("cjdoc:v2:missing"))
            ]
        )
    }

    public func close(): Unit {}
}

internal class LateReferenceFactory <: api_provider.SemanticProviderFactory {
    public prop name: String {
        get() {
            "late-reference-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        LateReferenceSession()
    }
}

internal class DiagnosticOnlyUnknownReferenceSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "resolved"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray(),
            diagnostics: [api_model.Diagnostic("warning", "CJDOC2999", "diagnostic-only unknown identity",
                symbolId: Some("cjdoc:v2:missing-diagnostic-only"))])
    }

    public func close(): Unit {}
}

internal class DiagnosticOnlyUnknownReferenceFactory <: api_provider.SemanticProviderFactory {
    public prop name: String {
        get() {
            "diagnostic-only-unknown-reference-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        DiagnosticOnlyUnknownReferenceSession()
    }
}

internal class SourceMutationCapture {
    var startOffset: Int64 = 0
    var endOffset: Int64 = 0
}

internal class SourceMutationSession <: api_provider.SemanticProviderSession {
    private let sourcePath: String
    private let capture: SourceMutationCapture

    init(sourcePath: String, capture: SourceMutationCapture) {
        this.sourcePath = sourcePath
        this.capture = capture
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            if (capture.endOffset == 0) {
                capture.startOffset = declaration.source.start.byteOffset
                capture.endOffset = declaration.source.end.byteOffset
            }
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        File.writeTo(Path(sourcePath), "package captured_source\n".toArray())
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {}
}

internal class SourceMutationFactory <: api_provider.SemanticProviderFactory {
    private let sourcePath: String
    private let capture: SourceMutationCapture

    init(sourcePath: String, capture: SourceMutationCapture) {
        this.sourcePath = sourcePath
        this.capture = capture
    }

    public prop name: String {
        get() {
            "source-mutation-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        SourceMutationSession(sourcePath, capture)
    }
}

internal class EnumFactCapture {
    var sawEnum: Bool = false
    var leakedToNonEnum: Bool = false
}

internal class EnumFactSession <: api_provider.SemanticProviderSession {
    private let capture: EnumFactCapture

    init(capture: EnumFactCapture) {
        this.capture = capture
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            if (declaration.kind == "enum" && declaration.enumNonExhaustive == Some(false)) {
                capture.sawEnum = true
            }
            if (declaration.kind != "enum" && declaration.enumNonExhaustive.isSome()) {
                capture.leakedToNonEnum = true
            }
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {}
}

internal class EnumFactFactory <: api_provider.SemanticProviderFactory {
    private let capture: EnumFactCapture

    init(capture: EnumFactCapture) {
        this.capture = capture
    }

    public prop name: String {
        get() {
            "enum-fact-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        EnumFactSession(capture)
    }
}
