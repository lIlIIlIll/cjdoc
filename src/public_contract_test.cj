package cjdoc

import cjdoc.model as api_model
import cjdoc.provider as api_provider
import cjdoc.render as api_render
import std.collection.*
import std.env.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

private let PUBLIC_FIXTURE_PROJECTS = "tests/fixtures/projects/"
private let PUBLIC_TEST_AST_PREFLIGHT = Some("target/release/bin/main")

@When[os == "Linux"]
private func publicLocalAssetEmbeddingEnabled(): Bool {
    true
}

@When[os != "Linux"]
private func publicLocalAssetEmbeddingEnabled(): Bool {
    false
}

private class ProviderLifecycle {
    var opened: Int64 = 0
    var analyzed: Int64 = 0
    var closed: Int64 = 0
}

private class LifecycleSession <: api_provider.SemanticProviderSession {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) {
        this.lifecycle = lifecycle
    }

    public func analyze(_: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        api_provider.SemanticBatch(api_model.SemanticCapabilities(false, false, false, false, false))
    }

    public func close(): Unit {
        lifecycle.closed++
    }
}

private class LifecycleFactory <: api_provider.SemanticProviderFactory {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) {
        this.lifecycle = lifecycle
    }

    public prop name: String {
        get() {
            "lifecycle-test"
        }
    }
    public prop version: String {
        get() {
            "2026.08-test"
        }
    }

    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        LifecycleSession(lifecycle)
    }
}

private class UnknownIdSession <: api_provider.SemanticProviderSession {
    public func analyze(_: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let foreignIssuer = api_provider.SourceDeclarationIssuer()
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: [api_provider.SemanticDeclaration(foreignIssuer.issue("not-issued-by-cjdoc"), "partial")])
    }

    public func close(): Unit {}
}

private class UnknownIdFactory <: api_provider.SemanticProviderFactory {
    public prop name: String {
        get() {
            "unknown-id-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        UnknownIdSession()
    }
}

private class WorkspaceTransactionSession <: api_provider.SemanticProviderSession {
    private let lifecycle: ProviderLifecycle
    private let fail: Bool

    init(lifecycle: ProviderLifecycle, fail: Bool) {
        this.lifecycle = lifecycle
        this.fail = fail
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        if (fail && !declarations.isEmpty()) {
            let foreignId = api_provider.SourceDeclarationIssuer().issue(declarations[0].id.serialize())
            return api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
                declarations: [api_provider.SemanticDeclaration(foreignId, "partial")])
        }
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {
        lifecycle.closed++
    }
}

private class WorkspaceTransactionFactory <: api_provider.SemanticProviderFactory {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) {
        this.lifecycle = lifecycle
    }

    public prop name: String {
        get() {
            "module-transaction-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }

    public func open(module: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        WorkspaceTransactionSession(lifecycle, module.name.contains("alpha"))
    }
}

private class CloseFailureSession <: api_provider.SemanticProviderSession {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) {
        this.lifecycle = lifecycle
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {
        lifecycle.closed++
        throw IllegalStateException("close failed")
    }
}

private class CloseFailureFactory <: api_provider.SemanticProviderFactory {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) {
        this.lifecycle = lifecycle
    }

    public prop name: String {
        get() {
            "close-failure-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        CloseFailureSession(lifecycle)
    }
}

private class AnnotationSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        for (declaration in declarations) {
            if (declaration.name == "oldParse") {
                return api_provider.SemanticBatch(
                    api_model.SemanticCapabilities(true, false, false, false, false, annotations: true),
                    declarations: [api_provider.SemanticDeclaration(declaration.id, "partial",
                        annotations: ["@ProviderMeta"], annotationsProvided: true)])
            }
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false, annotations: true))
    }

    public func close(): Unit {}
}

private class AnnotationFactory <: api_provider.SemanticProviderFactory {
    public prop name: String {
        get() {
            "annotation-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        AnnotationSession()
    }
}

private class RelationshipSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        var parser: ?api_provider.SourceDeclarationView = None
        var reader: ?api_provider.SourceDeclarationView = None
        for (declaration in declarations) {
            if (declaration.kind == "class" && declaration.name == "Parser") {
                parser = Some(declaration)
            }
            if (declaration.kind == "interface" && declaration.name == "Reader") {
                reader = Some(declaration)
            }
        }
        if (parser.isNone() || reader.isNone()) {
            return api_provider.SemanticBatch(
                api_model.SemanticCapabilities(true, false, false, true, false, relationships: true))
        }
        let relationship = api_provider.SemanticSymbolRelationship("implements", "basic.Reader", "resolved",
            targetSourceId: Some(reader.getOrThrow().id))
        let superType = api_provider.SemanticTypeRelationship("superType",
            api_model.TypeRef("semantic", "Reader",
                api_model.SemanticType("resolved", canonical: Some("basic.Reader"), provider: Some("relationship-test"))))
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, true, false, relationships: true),
            declarations: [api_provider.SemanticDeclaration(parser.getOrThrow().id, "partial",
                typeRelationships: [superType], symbolRelationships: [relationship])])
    }

    public func close(): Unit {}
}

private class RelationshipFactory <: api_provider.SemanticProviderFactory {
    public prop name: String {
        get() {
            "relationship-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        RelationshipSession()
    }
}

private class StateSession <: api_provider.SemanticProviderSession {
    private let state: String

    init(state: String) {
        this.state = state
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, state))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {}
}

private class StateFactory <: api_provider.SemanticProviderFactory {
    private let state: String

    init(state: String) {
        this.state = state
    }

    public prop name: String {
        get() {
            "state-${state}-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        StateSession(state)
    }
}

private func deeplyNestedProviderType(): api_model.TypeRef {
    var value = api_model.TypeRef("source", "Leaf", api_model.SemanticType("partial"))
    var depth: Int64 = 0
    while (depth < api_model.DOC_IR_MAX_TYPE_DEPTH + 2) {
        value = api_model.TypeRef("source", "Layer", api_model.SemanticType("partial"), arguments: [value])
        depth++
    }
    value
}

private class ImplicitTypeProviderSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        var addedType = false
        for (declaration in declarations) {
            if (!addedType && declaration.returnTypeSpelling.isSome()) {
                let nested = api_model.TypeRef("semantic", "Outer<Inner>", api_model.SemanticType("partial"),
                    arguments: [api_model.TypeRef("semantic", "Inner", api_model.SemanticType("partial"))])
                converted.add(api_provider.SemanticDeclaration(declaration.id, "partial", returnType: Some(nested)))
                addedType = true
            } else {
                converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
            }
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, true, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {}
}

private class ImplicitTypeProviderFactory <: api_provider.SemanticProviderFactory {
    public prop name: String {
        get() {
            "implicit-type-provider-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        ImplicitTypeProviderSession()
    }
}

private class InvalidBatchSession <: api_provider.SemanticProviderSession {
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

private class InvalidBatchFactory <: api_provider.SemanticProviderFactory {
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

private class LateReferenceSession <: api_provider.SemanticProviderSession {
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

private class LateReferenceFactory <: api_provider.SemanticProviderFactory {
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

private class DiagnosticOnlyUnknownReferenceSession <: api_provider.SemanticProviderSession {
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

private class DiagnosticOnlyUnknownReferenceFactory <: api_provider.SemanticProviderFactory {
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

private class SourceMutationCapture {
    var startOffset: Int64 = 0
    var endOffset: Int64 = 0
}

private class SourceMutationSession <: api_provider.SemanticProviderSession {
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

private class SourceMutationFactory <: api_provider.SemanticProviderFactory {
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

private class EnumFactCapture {
    var sawEnum: Bool = false
    var leakedToNonEnum: Bool = false
}

private class EnumFactSession <: api_provider.SemanticProviderSession {
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

private class EnumFactFactory <: api_provider.SemanticProviderFactory {
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

private class DefaultExpressionCapture {
    var sawDeclaration: Bool = false
    var required: ?String = None
    var count: ?String = None
    var label: ?String = None
}

private class DefaultExpressionSession <: api_provider.SemanticProviderSession {
    private let capture: DefaultExpressionCapture

    init(capture: DefaultExpressionCapture) {
        this.capture = capture
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            if (declaration.name == "defaulted" && declaration.parameters.size == 3) {
                capture.sawDeclaration = true
                capture.required = declaration.parameters[0].defaultExpression
                capture.count = declaration.parameters[1].defaultExpression
                capture.label = declaration.parameters[2].defaultExpression
            }
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {}
}

private class DefaultExpressionFactory <: api_provider.SemanticProviderFactory {
    private let capture: DefaultExpressionCapture

    init(capture: DefaultExpressionCapture) {
        this.capture = capture
    }

    public prop name: String {
        get() {
            "default-expression-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        DefaultExpressionSession(capture)
    }
}

private class HostileProviderCapture {
    var nameReads: Int64 = 0
    var versionReads: Int64 = 0
    var opened: Int64 = 0
    var analyzed: Int64 = 0
    var closed: Int64 = 0
}

private func hostileProviderMessage(): String {
    String.fromUtf8(Array<Byte>(8192, repeat: b'x'))
}

private class HostileProviderSession <: api_provider.SemanticProviderSession {
    private let mode: String
    private let capture: HostileProviderCapture

    init(mode: String, capture: HostileProviderCapture) {
        this.mode = mode
        this.capture = capture
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        capture.analyzed++
        if (mode == "analyze-throws") {
            throw IllegalStateException(hostileProviderMessage())
        }
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {
        capture.closed++
        if (mode == "close-throws") {
            throw IllegalStateException(hostileProviderMessage())
        }
    }
}

private class HostileProviderFactory <: api_provider.SemanticProviderFactory {
    private let mode: String
    private let capture: HostileProviderCapture

    init(mode: String, capture: HostileProviderCapture) {
        this.mode = mode
        this.capture = capture
    }

    public prop name: String {
        get() {
            capture.nameReads++
            if (mode == "name-throws") {
                throw IllegalStateException(hostileProviderMessage())
            }
            if (mode == "blank-name") {
                return " \t "
            }
            if (mode == "huge-name") {
                return String.fromUtf8(Array<Byte>(1025, repeat: b'n'))
            }
            "hostile-provider-test"
        }
    }

    public prop version: String {
        get() {
            capture.versionReads++
            if (mode == "version-throws") {
                throw IllegalStateException(hostileProviderMessage())
            }
            if (mode == "blank-version") {
                return " \t "
            }
            if (mode == "huge-version") {
                return String.fromUtf8(Array<Byte>(1025, repeat: b'v'))
            }
            "1"
        }
    }

    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        capture.opened++
        if (mode == "open-throws") {
            throw IllegalStateException(hostileProviderMessage())
        }
        HostileProviderSession(mode, capture)
    }
}

private class IdentityConflictSession <: api_provider.SemanticProviderSession {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) {
        this.lifecycle = lifecycle
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        lifecycle.analyzed++
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            let parameters = ArrayList<api_provider.SemanticParameter>()
            for (parameter in declaration.parameters) {
                let canonical = if (declaration.name == "parse") {
                    "identity.conflict.Collapsed"
                } else {
                    parameter.typeSpelling
                }
                parameters.add(
                    api_provider.SemanticParameter(parameter.name,
                        api_model.TypeRef("semantic", parameter.typeSpelling,
                            api_model.SemanticType("resolved", canonical: Some(canonical),
                                provider: Some("identity-conflict-test")))))
            }
            converted.add(api_provider.SemanticDeclaration(declaration.id, "resolved", parameters: parameters.toArray()))
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, true, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {
        lifecycle.closed++
    }
}

private class IdentityConflictFactory <: api_provider.SemanticProviderFactory {
    private let lifecycle: ProviderLifecycle

    init(lifecycle: ProviderLifecycle) {
        this.lifecycle = lifecycle
    }

    public prop name: String {
        get() {
            "identity-conflict-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        lifecycle.opened++
        IdentityConflictSession(lifecycle)
    }
}

private class PartialSpellingCollapseSession <: api_provider.SemanticProviderSession {
    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            if (declaration.name == "overload") {
                let parameters = ArrayList<api_provider.SemanticParameter>()
                for (parameter in declaration.parameters) {
                    parameters.add(
                        api_provider.SemanticParameter(parameter.name,
                            api_model.TypeRef("semantic", "T",
                                api_model.SemanticType("partial", provider: Some("partial-spelling-test")))))
                }
                converted.add(
                    api_provider.SemanticDeclaration(declaration.id, "partial", parameters: parameters.toArray()))
            } else {
                converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
            }
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, true, false),
            declarations: converted.toArray())
    }

    public func close(): Unit {}
}

private class PartialSpellingCollapseFactory <: api_provider.SemanticProviderFactory {
    public prop name: String {
        get() {
            "partial-spelling-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }

    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        PartialSpellingCollapseSession()
    }
}

private class CrossModuleDiagnosticCapture {
    var firstModuleSymbolId: ?String = None
}

private class CrossModuleDiagnosticSession <: api_provider.SemanticProviderSession {
    private let module: api_provider.SemanticModule
    private let capture: CrossModuleDiagnosticCapture

    init(module: api_provider.SemanticModule, capture: CrossModuleDiagnosticCapture) {
        this.module = module
        this.capture = capture
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "resolved"))
        }
        let diagnostics = ArrayList<api_model.Diagnostic>()
        if (!declarations.isEmpty()) {
            match (capture.firstModuleSymbolId) {
                case Some(symbolId) => diagnostics.add(
                    api_model.Diagnostic("warning", "CJDOC2999", "cross-module diagnostic identity",
                        symbolId: Some(symbolId)))
                case None =>
                    let first = declarations[0]
                    let parameterTypes = ArrayList<String>()
                    for (parameter in first.parameters) {
                        parameterTypes.add(parameter.typeSpelling)
                    }
                    capture.firstModuleSymbolId = Some(
                        makeSymbolId(module.id, first.packageName, "", first.kind, first.name, first.genericArity,
                            parameterTypes.toArray()))
            }
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray(), diagnostics: diagnostics.toArray())
    }

    public func close(): Unit {}
}

private class CrossModuleDiagnosticFactory <: api_provider.SemanticProviderFactory {
    private let capture: CrossModuleDiagnosticCapture

    init(capture: CrossModuleDiagnosticCapture) {
        this.capture = capture
    }

    public prop name: String {
        get() {
            "cross-module-diagnostic-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(module: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        CrossModuleDiagnosticSession(module, capture)
    }
}

private class AlternatingDiagnosticCapture {
    var reversed: Bool = false
}

private class AlternatingDiagnosticSession <: api_provider.SemanticProviderSession {
    private let capture: AlternatingDiagnosticCapture

    init(capture: AlternatingDiagnosticCapture) {
        this.capture = capture
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        for (declaration in declarations) {
            converted.add(api_provider.SemanticDeclaration(declaration.id, "resolved"))
        }
        let error = api_model.Diagnostic("error", "CJDOC2998", "same")
        let alpha = api_model.Diagnostic("warning", "CJDOC2998", "alpha")
        let zeta = api_model.Diagnostic("warning", "CJDOC2998", "zeta")
        let diagnostics = if (capture.reversed) {
            [zeta, alpha, error]
        } else {
            [error, alpha, zeta]
        }
        capture.reversed = !capture.reversed
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: converted.toArray(), diagnostics: diagnostics)
    }

    public func close(): Unit {}
}

private class AlternatingDiagnosticFactory <: api_provider.SemanticProviderFactory {
    private let capture: AlternatingDiagnosticCapture

    init(capture: AlternatingDiagnosticCapture) {
        this.capture = capture
    }

    public prop name: String {
        get() {
            "alternating-diagnostic-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }
    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        AlternatingDiagnosticSession(capture)
    }
}

private class AlternatingTypeRelationshipCapture {
    var reversed: Bool = false
}

private func orderingRelationshipTarget(kind: String, nullable: Bool, argument: String): api_model.TypeRef {
    api_model.TypeRef(kind, "Same", api_model.SemanticType("partial", provider: Some("alternating-relationship-test")),
        nullable: nullable,
        arguments: [api_model.TypeRef("semantic", argument,
            api_model.SemanticType("partial", provider: Some("alternating-relationship-test")))])
}

private class AlternatingTypeRelationshipSession <: api_provider.SemanticProviderSession {
    private let capture: AlternatingTypeRelationshipCapture

    init(capture: AlternatingTypeRelationshipCapture) {
        this.capture = capture
    }

    public func analyze(declarations: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let nestedA = api_provider.SemanticTypeRelationship("ordering", orderingRelationshipTarget("semantic", false,
            "A"))
        let nestedB = api_provider.SemanticTypeRelationship("ordering", orderingRelationshipTarget("semantic", false,
            "B"))
        let nullable = api_provider.SemanticTypeRelationship("ordering", orderingRelationshipTarget("semantic", true,
            "A"))
        let sourceKind = api_provider.SemanticTypeRelationship("ordering",
            orderingRelationshipTarget("source", false, "A"))
        let relationships = if (capture.reversed) {
            [sourceKind, nullable, nestedB, nestedA]
        } else {
            [nestedA, nestedB, nullable, sourceKind]
        }
        capture.reversed = !capture.reversed
        let converted = ArrayList<api_provider.SemanticDeclaration>()
        var index: Int64 = 0
        for (declaration in declarations) {
            if (index == 0) {
                converted.add(
                    api_provider.SemanticDeclaration(declaration.id, "partial", typeRelationships: relationships))
            } else {
                converted.add(api_provider.SemanticDeclaration(declaration.id, "partial"))
            }
            index++
        }
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, true, false, relationships: true),
            declarations: converted.toArray())
    }

    public func close(): Unit {}
}

private class AlternatingTypeRelationshipFactory <: api_provider.SemanticProviderFactory {
    private let capture: AlternatingTypeRelationshipCapture

    init(capture: AlternatingTypeRelationshipCapture) {
        this.capture = capture
    }

    public prop name: String {
        get() {
            "alternating-relationship-test"
        }
    }
    public prop version: String {
        get() {
            "1"
        }
    }

    public func open(_: api_provider.SemanticModule): api_provider.SemanticProviderSession {
        AlternatingTypeRelationshipSession(capture)
    }
}

private func publicHasDiagnostic(documentation: api_model.DocumentationSet, code: String): Bool {
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) {
            return true
        }
    }
    false
}

private func publicDiagnosticCount(documentation: api_model.DocumentationSet, code: String): Int64 {
    var count: Int64 = 0
    for (diagnostic in documentation.diagnostics) {
        if (diagnostic.code == code) {
            count++
        }
    }
    count
}

private func markdownLiteral(node: api_model.MarkdownNode, kind: String): ?String {
    if (node.kind == kind) {
        return Some(node.literal)
    }
    for (child in node.children) {
        if (let Some(value) <- markdownLiteral(child, kind)) {
            return Some(value)
        }
    }
    None
}

private func renderedContent(artifacts: Array<api_render.RenderArtifact>): String {
    let out = StringBuilder()
    for (artifact in artifacts) {
        out.append("\n--- ${artifact.path} ---\n")
        out.append(artifact.content)
    }
    out.toString()
}

private func hasArtifactPrefix(artifacts: Array<api_render.RenderArtifact>, prefix: String): Bool {
    for (artifact in artifacts) {
        if (artifact.path.startsWith(prefix)) {
            return true
        }
    }
    false
}

private func artifactContent(artifacts: Array<api_render.RenderArtifact>, path: String): String {
    for (artifact in artifacts) {
        if (artifact.path == path) {
            return artifact.content
        }
    }
    throw IllegalArgumentException("missing render artifact '${path}'")
}

private func rendererFixture(markdown: api_model.MarkdownNode, summary: String, assets!: Array<api_model.AssetDoc> = []): api_model.DocumentationSet {
    let moduleId = "cjdoc:module:v1:renderer-test"
    let symbolId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Arenderer-test::fixture::function:api#g0()"
    let source = api_model.SourceRange("src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 24, 23))
    let capabilities = api_model.SemanticCapabilities(false, false, false, false, false)
    let symbol = api_model.SymbolDoc(symbolId, "function", "api", "fixture.api", "fixture", moduleId, "public", source,
        "public func api(): Unit", api_model.SemanticInfo("partial", "ast-fallback"),
        documentation: Some(
            api_model.DocComment("RAW-FIELD-MUST-NOT-RENDER", summary, "DESCRIPTION-FIELD-MUST-NOT-RENDER", markdown)))
    api_model.DocumentationSet(api_model.GeneratorInfo("cjdoc", "test"), "complete",
        api_model.ProjectInfo("renderer-fixture"),
        api_model.ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [api_model.ProviderInfo("ast-fallback", "builtin", moduleId, "partial", capabilities)],
        modules: [api_model.ModuleDoc(moduleId, "renderer-fixture", "root", "", packageNames: ["fixture"])],
        packages: [api_model.PackageDoc("fixture", moduleId, sourceFiles: ["src/api.cj"], symbolIds: [symbolId])],
        files: [api_model.FileDoc("src/api.cj", moduleId, "fixture")], declarations: [symbol], assets: assets)
}

private func samePackageAcrossModulesFixture(): api_model.DocumentationSet {
    let firstModule = "cjdoc:module:v1:first"
    let secondModule = "cjdoc:module:v1:second"
    let firstId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Afirst::shared::function:first#g0()"
    let secondId = "cjdoc:v2:cjdoc%3Amodule%3Av1%3Asecond::shared::function:second#g0()"
    let firstSource = api_model.SourceRange("first/src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 26, 25))
    let secondSource = api_model.SourceRange("second/src/api.cj", api_model.SourcePosition(1, 1, 0),
        api_model.SourcePosition(1, 27, 26))
    let capabilities = api_model.SemanticCapabilities(false, false, false, false, false)
    let markdown = api_model.MarkdownNode("document",
        children: [api_model.MarkdownNode("paragraph",
            children: [api_model.MarkdownNode("text", literal: "Module-local API")])])
    let first = api_model.SymbolDoc(firstId, "function", "first", "shared.first", "shared", firstModule, "public",
        firstSource, "public func first(): Unit", api_model.SemanticInfo("partial", "ast-fallback"),
        documentation: Some(api_model.DocComment("Module-local API", "Module-local API", "", markdown)))
    let second = api_model.SymbolDoc(secondId, "function", "second", "shared.second", "shared", secondModule, "public",
        secondSource, "public func second(): Unit", api_model.SemanticInfo("partial", "ast-fallback"),
        documentation: Some(api_model.DocComment("Module-local API", "Module-local API", "", markdown)))
    api_model.DocumentationSet(
        api_model.GeneratorInfo("cjdoc", "test"),
        "complete",
        api_model.ProjectInfo("two-modules", kind: "workspace"),
        api_model.ConfigurationSnapshot(audience: "external", lintProfile: "off"),
        providers: [
            api_model.ProviderInfo("ast-fallback", "builtin", firstModule, "partial", capabilities),
            api_model.ProviderInfo("ast-fallback", "builtin", secondModule, "partial", capabilities)
        ],
        modules: [
            api_model.ModuleDoc(firstModule, "first", "workspace", "first", packageNames: ["shared"]),
            api_model.ModuleDoc(secondModule, "second", "workspace", "second", packageNames: ["shared"])
        ],
        packages: [
            api_model.PackageDoc("shared", firstModule, sourceFiles: ["first/src/api.cj"], symbolIds: [firstId]),
            api_model.PackageDoc("shared", secondModule, sourceFiles: ["second/src/api.cj"], symbolIds: [secondId])
        ],
        files: [
            api_model.FileDoc("first/src/api.cj", firstModule, "shared"),
            api_model.FileDoc("second/src/api.cj", secondModule, "shared")
        ],
        declarations: [first, second]
    )
}

@Test
class PublicApiContractsTest {
    @TestCase
    func sourceDeclarationIdsAreSessionLocal(): Unit {
        let firstIssuer = api_provider.SourceDeclarationIssuer()
        let secondIssuer = api_provider.SourceDeclarationIssuer()
        let first = firstIssuer.issue("same-text")
        let sameSession = firstIssuer.issue("same-text")
        let otherSession = secondIssuer.issue("same-text")
        @Expect(first == sameSession)
        @Expect(first != otherSession)
        @Expect(first.serialize() == otherSession.serialize())
        @Expect(firstIssuer.owns(first))
        @Expect(!firstIssuer.owns(otherSession))
    }

    @TestCase
    func generatedDocIrRoundTripsStrictly(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "standard",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.schemaVersion, "cjdoc.doc-ir/8")
        @Expect(documentation.declarations.size, 25)
        @Expect(documentation.files.size, 1)
        @Expect(documentation.declarations[0].source.start.byteOffset > 0)

        let encoded = api_render.encodeDocIr(documentation)
        @Expect(!encoded.contains("/home/"))
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)

        let unknown = encoded.replace("\"schemaVersion\":", "\"unknown\":true,\"schemaVersion\":")
        @ExpectThrows(api_render.decodeDocIr(unknown))
        let duplicate = encoded.replace("\"schemaVersion\": \"cjdoc.doc-ir/8\",",
            "\"schemaVersion\": \"cjdoc.doc-ir/8\", \"schemaVersion\": \"cjdoc.doc-ir/8\",")
        @ExpectThrows(api_render.decodeDocIr(duplicate))

        let missingProviderModule = encoded.replace(
            "      \"moduleId\": \"cjdoc:module:v1:root\",\n      \"state\": \"partial\",",
            "      \"state\": \"partial\",")
        @Expect(missingProviderModule != encoded)
        @ExpectThrows(api_render.decodeDocIr(missingProviderModule))

        let unknownOwner = encoded.replace("      \"ownerId\": null,", "      \"ownerId\": \"cjdoc:missing\",")
        @Expect(unknownOwner != encoded)
        @ExpectThrows(api_render.decodeDocIr(unknownOwner))
    }

    @TestCase
    func strictV6InputMigratesOnlyWithUniquePackageModuleMapping(): Unit {
        let path = Path("tests/fixtures/golden-v6/basic.docs.json")
        let legacy = String.fromUtf8(File.readFrom(path))
        let migrated = api_render.decodeDocIr(legacy)
        @Expect(migrated.schemaVersion, "cjdoc.doc-ir/8")
        @Expect(migrated.providers.size, 1)
        @Expect(migrated.providers[0].moduleId, "cjdoc:module:v1:root")
        @Expect(migrated.declarations[0].moduleId, "cjdoc:module:v1:root")
        @Expect(migrated.declarations[0].id.startsWith(
            "cjdoc:v2:cjdoc%3Amodule%3Av1%3Aroot::"))
        @Expect(migrated.packages[0].symbolIds[0], migrated.declarations[0].id)
        var migratedAnnotation = false
        var migratedReference = false
        for (declaration in migrated.declarations) {
            if (let Some(ownerId) <- declaration.ownerId) {
                @Expect(ownerId.startsWith("cjdoc:v2:"))
            }
            for (relationship in declaration.symbolRelationships) {
                if (let Some(targetId) <- relationship.targetSymbolId) {
                    @Expect(targetId.startsWith("cjdoc:v2:"))
                    migratedReference = true
                }
            }
            if (let Some(documentation) <- declaration.documentation) {
                for (tag in documentation.tags) {
                    if (let Some(targetId) <- tag.targetSymbolId) {
                        @Expect(targetId.startsWith("cjdoc:v2:"))
                        migratedReference = true
                    }
                }
            }
            for (annotation in declaration.annotations) {
                @Expect(annotation.provenance, "source")
                @Expect(annotation.provider.isNone())
                migratedAnnotation = true
            }
        }
        @Expect(migratedAnnotation)
        @Expect(migratedReference)

        let ambiguous = legacy.replace("  \"modules\": [\n    {",
            "  \"modules\": [\n" + "    {\"id\":\"cjdoc:module:v1:other\",\"name\":\"other\"," +
                "\"role\":\"workspace\",\"sourcePrefix\":\"other\"," +
                "\"packageNames\":[\"basic\"],\"dependencyIds\":[]},\n    {")
        @Expect(ambiguous != legacy)
        @ExpectThrows(api_render.decodeDocIr(ambiguous))
    }

    @TestCase
    func renderersHonorAudienceWithoutChangingDocIr(): Unit {
        let external = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", audience: "external", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let all = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", audience: "all", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(external.declarations.size, all.declarations.size)

        let externalArtifacts = api_render.HtmlDocumentationRenderer().render(external)
        let allArtifacts = api_render.HtmlDocumentationRenderer().render(all)
        let externalHtml = renderedContent(externalArtifacts)
        let allHtml = renderedContent(allArtifacts)
        @Expect(!externalHtml.contains("basic.Parser.hidden"))
        @Expect(allHtml.contains("basic.Parser.hidden"))
        @Expect(hasArtifactPrefix(externalArtifacts, "html/packages/"))
        @Expect(hasArtifactPrefix(externalArtifacts, "html/symbols/"))
        let searchScript = artifactContent(externalArtifacts, "html/search.js")
        @Expect(searchScript.contains("data-cjdoc-search"))
        @Expect(!searchScript.contains("fetch("))
        @Expect(artifactContent(externalArtifacts, "html/search-index.js").startsWith(
            "globalThis.__CJDOC_SEARCH_INDEX__ ="))
        let searchIndex = artifactContent(externalArtifacts, "html/search-index.json")
        @Expect(searchIndex.contains("\"href\": \"symbols/"))
        @Expect(!searchIndex.contains("index.html#"))
        @Expect(!searchIndex.contains("basic.Parser.hidden"))
        @Expect(artifactContent(externalArtifacts, "html/index.html").contains(
            "<script defer src=\"search-index.js\"></script><script defer src=\"search.js\""))
        @Expect(externalHtml.contains("<h2>Functions</h2>"))
        @Expect(externalHtml.contains("Content-Security-Policy"))
    }

    @TestCase
    func renderersUseMarkdownAstAsTheOnlyDocumentationSource(): Unit {
        let markdown = api_model.MarkdownNode("document",
            children: [api_model.MarkdownNode("paragraph",
                children: [api_model.MarkdownNode("text", literal: "AST truth")])])
        let documentation = rendererFixture(markdown, "SUMMARY-LIE-<script>alert(1)</script>")
        let html = renderedContent(api_render.HtmlDocumentationRenderer().render(documentation))
        let renderedMarkdown = renderedContent(api_render.MarkdownDocumentationRenderer().render(documentation))
        @Expect(html.contains("AST truth"))
        @Expect(renderedMarkdown.contains("AST truth"))
        @Expect(!html.contains("SUMMARY-LIE"))
        @Expect(!html.contains("RAW-FIELD-MUST-NOT-RENDER"))
        @Expect(!html.contains("DESCRIPTION-FIELD-MUST-NOT-RENDER"))
        @Expect(!renderedMarkdown.contains("SUMMARY-LIE"))
    }

    @TestCase
    func htmlRoutesSamePackageNamePerModuleWithoutCollisions(): Unit {
        let artifacts = api_render.HtmlDocumentationRenderer().render(samePackageAcrossModulesFixture())
        var packageCount: Int64 = 0
        var firstPath = ""
        for (artifact in artifacts) {
            if (!artifact.path.startsWith("html/packages/")) {
                continue
            }
            packageCount++
            if (firstPath.isEmpty()) {
                firstPath = artifact.path
            } else {
                @Expect(artifact.path != firstPath)
            }
        }
        @Expect(packageCount, 2)
        let index = artifactContent(artifacts, "html/index.html")
        @Expect(index.contains("2 modules, 2 packages, 2 visible declarations"))
        let search = artifactContent(artifacts, "html/search-index.json")
        @Expect(search.contains("shared.first"))
        @Expect(search.contains("shared.second"))
    }

    @TestCase
    func renderersEmitStrictlyValidatedLocalImageAssets(): Unit {
        let markdown = api_model.MarkdownNode("document",
            children: [api_model.MarkdownNode("paragraph",
                children: [api_model.MarkdownNode("image", literal: "images/pixel.png",
                    children: [api_model.MarkdownNode("text", literal: "pixel")])])])
        let png = api_model.AssetDoc("sha256-431ced6916a2a21a156e38701afe55bbd7f88969fbbfc56d7fe099d47f265460",
            "image/png", "images/pixel.png",
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
        let documentation = rendererFixture(markdown, "ignored", assets: [png])
        let htmlArtifacts = api_render.HtmlDocumentationRenderer().render(documentation)
        let markdownArtifacts = api_render.MarkdownDocumentationRenderer().render(documentation)
        let assetPath = "assets/asset-7368613235362d34333163656436393136613261323161313536653338373031616665353562626437663838393639666262666335366437666530393964343766323635343630.png"
        @Expect(renderedContent(htmlArtifacts).contains("../${assetPath}"))
        @Expect(artifactContent(markdownArtifacts, "markdown/docs.md").contains(assetPath))
        var htmlBinary = false
        var markdownBinary = false
        for (artifact in htmlArtifacts) {
            if (artifact.path == "html/${assetPath}") {
                @Expect(artifact.isBinary)
                @Expect(artifact.bytes[0], 0x89)
                htmlBinary = true
            }
        }
        for (artifact in markdownArtifacts) {
            if (artifact.path == "markdown/${assetPath}") {
                @Expect(artifact.isBinary)
                @Expect(artifact.bytes[0], 0x89)
                markdownBinary = true
            }
        }
        @Expect(htmlBinary)
        @Expect(markdownBinary)

        let invalidBase64 = rendererFixture(markdown, "ignored",
            assets: [api_model.AssetDoc("bad", "image/png", "images/bad.png", "!!!!")])
        @ExpectThrows(api_render.HtmlDocumentationRenderer().render(invalidBase64))
        let invalidMagic = rendererFixture(markdown, "ignored",
            assets: [api_model.AssetDoc("bad", "image/png", "images/bad.png", "AAAA")])
        @ExpectThrows(api_render.MarkdownDocumentationRenderer().render(invalidMagic))
    }

    @TestCase
    func generationBundlesSafeImagesAndReportsMissingAssets(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "local_assets", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.status, "partial")
        if (!publicLocalAssetEmbeddingEnabled()) {
            @Expect(documentation.assets.size, 0)
            @Expect(publicHasDiagnostic(documentation, "CJDOC4026"))
            return
        }
        @Expect(documentation.assets.size, 1)
        @Expect(documentation.assets[0].mediaType, "image/gif")
        @Expect(documentation.assets[0].sourcePath, "src/images/pixel.gif")
        @Expect(documentation.assets[0].id.startsWith("sha256-"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC4026"))
        var rejectedInvalidContainer = false
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC4026" && diagnostic.message.contains("invalid.gif") &&
                diagnostic.message.contains("container or dimensions are invalid")) {
                rejectedInvalidContainer = true
            }
        }
        @Expect(rejectedInvalidContainer)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(encoded.contains("\"literal\": \"sha256-"))
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)

        let html = api_render.HtmlDocumentationRenderer().render(documentation)
        var bundled = false
        for (artifact in html) {
            if (artifact.mediaType == "image/gif") {
                @Expect(artifact.isBinary)
                @Expect(artifact.bytes.size > 6)
                bundled = true
            }
        }
        @Expect(bundled)
    }

    @TestCase
    func generationFallsBackWithinThePublicMarkdownBudget(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "markdown_limits", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.status, "partial")
        @Expect(publicHasDiagnostic(documentation, "CJDOC3026"))
        @Expect(documentation.declarations.size, 1)
        let comment = documentation.declarations[0].documentation.getOrThrow()
        @Expect(comment.summary,
            "Documentation omitted because Markdown resource limits were exceeded.")
        @Expect(comment.markdown.children.size, 1)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func strictLintAndProviderLifecycleAreObservable(): Unit {
        let strict = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "strict",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(strict, "CJDOC3004") ||
            publicHasDiagnostic(strict, "CJDOC3025"))

        let lifecycle = ProviderLifecycle()
        let provided = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [LifecycleFactory(lifecycle)], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(provided.providers[0].name, "lifecycle-test")
        @Expect(provided.providers[0].version, "2026.08-test")

        let unknown = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [UnknownIdFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(unknown, "CJDOC2001"))
        @Expect(unknown.declarations.size, 25)

        let related = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [RelationshipFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        var verifiedRelationship = false
        for (declaration in related.declarations) {
            if (declaration.kind == "class" && declaration.name == "Parser") {
                @Expect(declaration.typeRelationships.size, 1)
                @Expect(declaration.typeRelationships[0].target.semantic.state, "resolved")
                @Expect(declaration.symbolRelationships.size, 1)
                @Expect(declaration.symbolRelationships[0].state, "resolved")
                @Expect(declaration.symbolRelationships[0].targetSymbolId.isSome())
                verifiedRelationship = true
            }
        }
        @Expect(verifiedRelationship)
    }

    @TestCase
    func providerBatchesCommitPerModuleOnlyAfterClose(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "workspace", lintProfile: "off",
                providerFactories: [WorkspaceTransactionFactory(lifecycle)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 2)
        @Expect(lifecycle.analyzed, 2)
        @Expect(lifecycle.closed, 2)
        @Expect(documentation.providers.size, 2)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        var unavailableModules: Int64 = 0
        var partialModules: Int64 = 0
        for (provider in documentation.providers) {
            if (provider.state == "unavailable") {
                unavailableModules++
            }
            if (provider.state == "partial") {
                partialModules++
            }
        }
        @Expect(unavailableModules, 1)
        @Expect(partialModules, 1)

        var unavailableDeclarations: Int64 = 0
        var partialDeclarations: Int64 = 0
        for (declaration in documentation.declarations) {
            if (declaration.semantic.state == "unavailable") {
                unavailableDeclarations++
            }
            if (declaration.semantic.state == "partial") {
                partialDeclarations++
            }
        }
        @Expect(unavailableDeclarations > 0)
        @Expect(partialDeclarations > 0)
    }

    @TestCase
    func providerCloseFailureDiscardsStagedModuleBatch(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [CloseFailureFactory(lifecycle)], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(documentation.providers[0].state, "unavailable")
        for (declaration in documentation.declarations) {
            @Expect(declaration.semantic.state, "unavailable")
            for (parameter in declaration.parameters) {
                @Expect(parameter.typeRef.semantic.state, "unavailable")
                @Expect(parameter.typeRef.semantic.canonical.isNone())
                @Expect(parameter.typeRef.semantic.provider.isNone())
            }
            match (declaration.returnType) {
                case Some(value) =>
                    @Expect(value.semantic.state, "unavailable")
                    @Expect(value.semantic.canonical.isNone())
                    @Expect(value.semantic.provider.isNone())
                case None => ()
            }
            for (relationship in declaration.typeRelationships) {
                @Expect(relationship.target.semantic.state, "unavailable")
                @Expect(relationship.target.semantic.canonical.isNone())
                @Expect(relationship.target.semantic.provider.isNone())
            }
        }
    }

    @TestCase
    func providerIdentityIsReadOnceAndHostileExceptionsStayInModuleFallback(): Unit {
        let stableCapture = HostileProviderCapture()
        let stableFactory = HostileProviderFactory("valid", stableCapture)
        let stableRequest = GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "workspace", lintProfile: "off",
            providerFactories: [stableFactory], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT)
        @Expect(stableCapture.nameReads, 0)
        @Expect(stableCapture.versionReads, 0)
        let stable = DocumentationEngine().generate(stableRequest)
        @Expect(stableCapture.nameReads, 1)
        @Expect(stableCapture.versionReads, 1)
        @Expect(stableCapture.opened, 2)
        @Expect(stableCapture.analyzed, 2)
        @Expect(stableCapture.closed, 2)
        @Expect(!publicHasDiagnostic(stable, "CJDOC2001"))

        for (mode in ["name-throws", "version-throws", "blank-name", "blank-version", "huge-name", "huge-version",
            "open-throws", "analyze-throws", "close-throws"]) {
            let capture = HostileProviderCapture()
            let documentation = DocumentationEngine().generate(
                GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                    providerFactories: [HostileProviderFactory(mode, capture)],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(capture.nameReads, 1)
            @Expect(capture.versionReads, 1)
            @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
            @Expect(documentation.providers[0].state, "unavailable")
            @Expect(documentation.declarations.size, 25)
            if (mode == "name-throws" || mode == "version-throws" || mode == "blank-name" || mode == "blank-version" ||
                mode == "huge-name" || mode == "huge-version") {
                @Expect(capture.opened, 0)
                @Expect(capture.analyzed, 0)
                @Expect(capture.closed, 0)
            } else if (mode == "open-throws") {
                @Expect(capture.opened, 1)
                @Expect(capture.analyzed, 0)
                @Expect(capture.closed, 0)
            } else {
                @Expect(capture.opened, 1)
                @Expect(capture.analyzed, 1)
                @Expect(capture.closed, 1)
            }
            for (diagnostic in documentation.diagnostics) {
                if (diagnostic.code == "CJDOC2001") {
                    @Expect(diagnostic.message.size < 512)
                    @Expect(!diagnostic.message.contains("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"))
                }
            }
        }
    }

    @TestCase
    func generationRequestNormalizesCfgValuesAtConstruction(): Unit {
        let request = GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic",
            cfgValues: [
                CfgValue("target", "x86_64"),
                CfgValue("os", "linux"),
                CfgValue("target", "x86_64")
            ]
        )
        @Expect(request.cfgValues.size, 2)
        @Expect(request.cfgValues[0].name, "os")
        @Expect(request.cfgValues[0].value, "linux")
        @Expect(request.cfgValues[1].name, "target")
        @Expect(request.cfgValues[1].value, "x86_64")
        @ExpectThrows[IllegalArgumentException](GenerationRequest(
            PUBLIC_FIXTURE_PROJECTS + "basic", cfgValues: [
                CfgValue("os", "linux"), CfgValue("os", "windows")
            ]))
    }

    @TestCase
    func remappedLintWarningsDoNotMarkSourceStatusPartial(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "lint", lintProfile: "standard",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(documentation, "CJDOC3001"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC3008"))
        @Expect(documentation.status, "complete")
    }

    @TestCase
    func finalSemanticStatesDriveProviderAndDocumentStatus(): Unit {
        let partial = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [StateFactory("partial")], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(partial.providers[0].state, "partial")
        @Expect(partial.status, "complete")
        for (declaration in partial.declarations) {
            @Expect(declaration.semantic.state, "partial")
        }
        let partialEncoded = api_render.encodeDocIr(partial)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(partialEncoded)), partialEncoded)

        let unavailable = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [StateFactory("unavailable")], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(unavailable.providers[0].state, "unavailable")
        @Expect(unavailable.status, "partial")
        for (declaration in unavailable.declarations) {
            @Expect(declaration.semantic.state, "unavailable")
        }
        let unavailableEncoded = api_render.encodeDocIr(unavailable)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(unavailableEncoded)), unavailableEncoded)

        let ambiguous = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [StateFactory("ambiguous")], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(ambiguous.providers[0].state, "ambiguous")
        @Expect(ambiguous.status, "partial")
        for (declaration in ambiguous.declarations) {
            @Expect(declaration.semantic.state, "ambiguous")
        }
        let ambiguousEncoded = api_render.encodeDocIr(ambiguous)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(ambiguousEncoded)), ambiguousEncoded)
    }

    @TestCase
    func implicitNestedTypeProviderIsNormalizedToCurrentFactory(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [ImplicitTypeProviderFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        var sawNestedType = false
        for (declaration in documentation.declarations) {
            if (let Some(typeRef) <- declaration.returnType) {
                if (typeRef.arguments.isEmpty()) {
                    continue
                }
                @Expect(typeRef.semantic.provider, Some("implicit-type-provider-test"))
                @Expect(typeRef.arguments[0].semantic.provider,
                    Some("implicit-type-provider-test"))
                sawNestedType = true
            }
        }
        @Expect(sawNestedType)
    }

    @TestCase
    func invalidStructuredProviderBatchFallsBackAtomicallyAfterClose(): Unit {
        for (mode in ["annotation", "type", "deep-type", "diagnostic", "range", "out-of-bounds", "foreign-provider",
            "declaration-budget", "diagnostic-budget", "relationship-annotation-budget", "type-budget", "text-budget",
            "empty-canonical-type", "blank-canonical-type", "empty-canonical-signature", "blank-canonical-signature",
            "unavailable-canonical-signature"]) {
            let lifecycle = ProviderLifecycle()
            let documentation = DocumentationEngine().generate(
                GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                    providerFactories: [InvalidBatchFactory(mode, lifecycle)],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(lifecycle.opened, 1)
            @Expect(lifecycle.analyzed, 1)
            @Expect(lifecycle.closed, 1)
            @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2998"))
            @Expect(documentation.providers[0].state, "unavailable")
            @Expect(documentation.status, "partial")
            for (declaration in documentation.declarations) {
                @Expect(declaration.semantic.state, "unavailable")
            }
            let encoded = api_render.encodeDocIr(documentation)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        }
    }

    @TestCase
    func providerIdentityCollisionFallsBackWithoutDroppingOverloads(): Unit {
        let lifecycle = ProviderLifecycle()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [IdentityConflictFactory(lifecycle)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(lifecycle.opened, 1)
        @Expect(lifecycle.analyzed, 1)
        @Expect(lifecycle.closed, 1)
        @Expect(publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2006"))
        @Expect(documentation.providers[0].state, "unavailable")
        var overloadCount: Int64 = 0
        let overloadIds = HashSet<String>()
        for (declaration in documentation.declarations) {
            if (declaration.name == "parse" && declaration.kind == "function") {
                overloadCount++
                let _ = overloadIds.add(declaration.id)
            }
        }
        @Expect(overloadCount, 2)
        @Expect(overloadIds.size, 2)
    }

    @TestCase
    func partialProviderSpellingDoesNotCollapseSourceOverloads(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "partial_identity"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            File.writeTo(temporary.join("src/api.cj"),
                """
                package partial_identity

                public func overload(value: Int64): Unit {}
                public func overload(value: String): Unit {}
                """
                    .toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    providerFactories: [PartialSpellingCollapseFactory()],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2006"))
            @Expect(documentation.providers[0].state, "partial")
            let ids = HashSet<String>()
            let spellings = HashSet<String>()
            var overloads: Int64 = 0
            for (declaration in documentation.declarations) {
                if (declaration.name != "overload") {
                    continue
                }
                overloads++
                let _ = ids.add(declaration.id)
                @Expect(declaration.parameters.size, 1)
                let _ = spellings.add(declaration.parameters[0].typeRef.spelling)
            }
            @Expect(overloads, 2)
            @Expect(ids.size, 2)
            @Expect(spellings.contains("Int64"))
            @Expect(spellings.contains("String"))
            let encoded = api_render.encodeDocIr(documentation)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func lateProviderReferencesFailClosedWithoutDroppingDiagnostics(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [LateReferenceFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(publicHasDiagnostic(documentation, "CJDOC2017"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC2998"))
        @Expect(publicHasDiagnostic(documentation, "CJDOC2999"))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(documentation.providers[0].state, "partial")
        @Expect(documentation.status, "partial")
        var checkedRelationship = false
        for (declaration in documentation.declarations) {
            for (relationship in declaration.symbolRelationships) {
                if (relationship.targetDisplay != "missing") {
                    continue
                }
                @Expect(relationship.state, "unavailable")
                @Expect(relationship.targetSymbolId.isNone())
                checkedRelationship = true
            }
        }
        @Expect(checkedRelationship)
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC2999") {
                @Expect(diagnostic.symbolId.isNone())
            }
        }
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func diagnosticOnlyUnknownSymbolIdIsDetachedAndMarksProviderPartialOnce(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [DiagnosticOnlyUnknownReferenceFactory()],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(publicDiagnosticCount(documentation, "CJDOC2017"), 1)
        @Expect(publicDiagnosticCount(documentation, "CJDOC2999"), 1)
        @Expect(documentation.providers[0].state, "partial")
        @Expect(documentation.status, "partial")
        for (declaration in documentation.declarations) {
            @Expect(declaration.semantic.state, "resolved")
        }
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC2999") {
                @Expect(diagnostic.message, "diagnostic-only unknown identity")
                @Expect(diagnostic.symbolId.isNone())
            }
        }
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func crossModuleProviderDiagnosticIsDetachedAtItsOriginModule(): Unit {
        let capture = CrossModuleDiagnosticCapture()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "workspace", lintProfile: "off",
                providerFactories: [CrossModuleDiagnosticFactory(capture)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(capture.firstModuleSymbolId.isSome())
        @Expect(publicDiagnosticCount(documentation, "CJDOC2017"), 1)
        @Expect(publicDiagnosticCount(documentation, "CJDOC2999"), 1)
        var retainedDetached = false
        for (diagnostic in documentation.diagnostics) {
            if (diagnostic.code == "CJDOC2999") {
                @Expect(diagnostic.message, "cross-module diagnostic identity")
                @Expect(diagnostic.symbolId.isNone())
                retainedDetached = true
            }
        }
        @Expect(retainedDetached)
        var resolvedProviders: Int64 = 0
        var partialProviders: Int64 = 0
        for (provider in documentation.providers) {
            if (provider.state == "resolved") {
                resolvedProviders++
            }
            if (provider.state == "partial") {
                partialProviders++
            }
        }
        @Expect(resolvedProviders, 1)
        @Expect(partialProviders, 1)
        @Expect(documentation.status, "partial")
    }

    @TestCase
    func diagnosticOrderingIsIndependentOfProviderInsertionOrder(): Unit {
        let capture = AlternatingDiagnosticCapture()
        let factory = AlternatingDiagnosticFactory(capture)
        let first = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let second = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(api_render.encodeDocIr(second), api_render.encodeDocIr(first))
        let ordered = ArrayList<String>()
        for (diagnostic in first.diagnostics) {
            if (diagnostic.code == "CJDOC2998") {
                ordered.add("${diagnostic.severity}:${diagnostic.message}")
            }
        }
        @Expect(ordered.size, 3)
        @Expect(ordered[0], "error:same")
        @Expect(ordered[1], "warning:alpha")
        @Expect(ordered[2], "warning:zeta")
    }

    @TestCase
    func recursiveTypeRelationshipOrderIsIndependentOfProviderInsertionOrder(): Unit {
        let capture = AlternatingTypeRelationshipCapture()
        let factory = AlternatingTypeRelationshipFactory(capture)
        let first = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        let second = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off", providerFactories: [factory],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(api_render.encodeDocIr(second), api_render.encodeDocIr(first))
        let ordered = ArrayList<api_model.TypeRef>()
        for (declaration in first.declarations) {
            for (relationship in declaration.typeRelationships) {
                if (relationship.kind == "ordering") {
                    ordered.add(relationship.target)
                }
            }
        }
        @Expect(ordered.size, 4)
        @Expect(ordered[0].kind, "semantic")
        @Expect(!ordered[0].nullable)
        @Expect(ordered[0].arguments[0].spelling, "A")
        @Expect(ordered[1].kind, "semantic")
        @Expect(!ordered[1].nullable)
        @Expect(ordered[1].arguments[0].spelling, "B")
        @Expect(ordered[2].kind, "semantic")
        @Expect(ordered[2].nullable)
        @Expect(ordered[2].arguments[0].spelling, "A")
        @Expect(ordered[3].kind, "source")
        @Expect(!ordered[3].nullable)
        @Expect(ordered[3].arguments[0].spelling, "A")
    }

    @TestCase
    func diagnosticTotalOrderIncludesFullRangeAndOptionalSymbolIdentity(): Unit {
        let documentation = DocumentationSet("diagnostic-order")
        let earlierEnd = SourceLocation("src/api.cj", 1, 1, 1, 2)
        let laterEnd = SourceLocation("src/api.cj", 1, 1, 1, 3)
        let laterEndLine = SourceLocation("src/api.cj", 1, 1, 2, 1)
        let laterStart = SourceLocation("src/api.cj", 1, 2, 1, 2)
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: laterEnd, symbolId: Some("b")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", symbolId: Some("b")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: earlierEnd, symbolId: Some("z")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same"))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", symbolId: Some("a")))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: laterStart))
        documentation.diagnostics.add(Diagnostic("warning", "CJDOC2998", "same", source: laterEndLine))
        sortDocumentationDeterministically(documentation)
        @Expect(documentation.diagnostics[0].symbolId.isNone())
        @Expect(documentation.diagnostics[1].symbolId, Some("a"))
        @Expect(documentation.diagnostics[2].symbolId, Some("b"))
        @Expect(documentation.diagnostics[3].source.getOrThrow().endColumn, 2)
        @Expect(documentation.diagnostics[4].source.getOrThrow().endColumn, 3)
        @Expect(documentation.diagnostics[5].source.getOrThrow().endLine, 2)
        @Expect(documentation.diagnostics[6].source.getOrThrow().startColumn, 2)
    }

    @TestCase
    func capturedSourceOffsetsSurviveProviderSideFileMutation(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "captured_source"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let sourcePath = temporary.join("src/api.cj")
            File.writeTo(sourcePath,
                """
                package captured_source

                /** Captured source location. */
                public func stable(): Unit {}
                """
                    .toArray())
            let capture = SourceMutationCapture()
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    providerFactories: [SourceMutationFactory(sourcePath.toString(), capture)],
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(capture.startOffset > 0)
            @Expect(capture.endOffset > capture.startOffset)
            @Expect(documentation.declarations.size, 1)
            @Expect(documentation.declarations[0].source.start.byteOffset, capture.startOffset)
            @Expect(documentation.declarations[0].source.end.byteOffset, capture.endOffset)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func structuralMarkdownLeavesUseEmptyLiteral(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "markdown_leaf"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            File.writeTo(temporary.join("src/api.cj"),
                """
                package markdown_leaf

                /**
                 * Summary.
                 *
                 * ---
                 */
                public func leaf(): Unit {}
                """
                    .toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(documentation.declarations.size, 1)
            let comment = documentation.declarations[0].documentation.getOrThrow()
            @Expect(markdownLiteral(comment.markdown, "thematic_break"), Some(""))
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func duplicateSymbolsAreDeterministicallyPrunedAndPackageIdsRebuilt(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "duplicate", lintProfile: "off",
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(documentation.status, "partial")
        @Expect(publicHasDiagnostic(documentation, "CJDOC2006"))
        @Expect(documentation.declarations.size, 1)
        @Expect(documentation.packages.size, 1)
        @Expect(documentation.packages[0].symbolIds.size, 1)
        @Expect(documentation.packages[0].symbolIds[0], documentation.declarations[0].id)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func enumNonExhaustiveFlowsThroughProviderAndPublicProjection(): Unit {
        let capture = EnumFactCapture()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "types", lintProfile: "off",
                providerFactories: [EnumFactFactory(capture)], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(capture.sawEnum)
        @Expect(!capture.leakedToNonEnum)
        var sawPublicEnum = false
        for (declaration in documentation.declarations) {
            if (declaration.kind == "enum") {
                @Expect(declaration.enumNonExhaustive, Some(false))
                sawPublicEnum = true
            } else {
                @Expect(declaration.enumNonExhaustive.isNone())
            }
        }
        @Expect(sawPublicEnum)
        let encoded = api_render.encodeDocIr(documentation)
        @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
    }

    @TestCase
    func providerSourceViewPreservesParameterDefaultExpressions(): Unit {
        let capture = DefaultExpressionCapture()
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "frontend_regressions", lintProfile: "off",
                providerFactories: [DefaultExpressionFactory(capture)],
                astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        @Expect(!publicHasDiagnostic(documentation, "CJDOC2001"))
        @Expect(capture.sawDeclaration)
        @Expect(capture.required, None)
        @Expect(capture.count, Some("40 + 2"))
        @Expect(capture.label, Some("\"cjdoc\""))
    }

    @TestCase
    func providerAnnotationsOverlaySourceFactsWithProvenance(): Unit {
        let documentation = DocumentationEngine().generate(
            GenerationRequest(PUBLIC_FIXTURE_PROJECTS + "basic", lintProfile: "off",
                providerFactories: [AnnotationFactory()], astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
        var checked = false
        for (declaration in documentation.declarations) {
            if (declaration.name != "oldParse") {
                continue
            }
            var hasSource = false
            var hasProvider = false
            for (annotation in declaration.annotations) {
                if (annotation.provenance == "source" && annotation.spelling.startsWith("@Deprecated")) {
                    hasSource = true
                }
                if (annotation.provenance == "provider" && annotation.spelling == "@ProviderMeta" &&
                    annotation.provider == Some("annotation-test")) {
                    hasProvider = true
                }
            }
            @Expect(hasSource)
            @Expect(hasProvider)
            checked = true
        }
        @Expect(checked)
    }

    @TestCase
    func genericBindingPositionsKeepOverloadsUniqueAndRenamesStable(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "generic_identity"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let sourcePath = temporary.join("src/api.cj")
            File.writeTo(sourcePath,
                """
                package generic_identity

                public class Box<T> {
                    public func pair<U>(outer: T, local: U): Unit {}
                }

                public func f<X, Y>(left: X, right: Y): Unit {}
                public func f<Y, X>(left: X, right: Y): Unit {}

                extend<E> Box<E> {
                    public func extensionValue(value: E): E { value }
                }
                """
                    .toArray())
            let before = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(before, "CJDOC2006"))
            let beforeIds = HashSet<String>()
            let overloadIds = HashSet<String>()
            var overloads: Int64 = 0
            var sawLexicalOwnerBindings = false
            var sawGenericExtendTarget = false
            for (declaration in before.declarations) {
                let _ = beforeIds.add(declaration.id)
                if (declaration.name == "f") {
                    overloads++
                    let _ = overloadIds.add(declaration.id)
                }
                if (declaration.name == "pair") {
                    @Expect(declaration.id.contains("@g0"))
                    @Expect(declaration.id.contains("@g1"))
                    sawLexicalOwnerBindings = true
                }
                if (declaration.kind == "extend" || declaration.name == "extensionValue") {
                    @Expect(declaration.id.contains("@g0"))
                    sawGenericExtendTarget = true
                }
            }
            @Expect(overloads, 2)
            @Expect(overloadIds.size, 2)
            @Expect(sawLexicalOwnerBindings)
            @Expect(sawGenericExtendTarget)
            @Expect(beforeIds.size, before.declarations.size)

            File.writeTo(sourcePath,
                """
                package generic_identity

                public class Box<OuterRenamed> {
                    public func pair<LocalRenamed>(outer: OuterRenamed,
                        local: LocalRenamed): Unit {}
                }

                public func f<First, Second>(left: First, right: Second): Unit {}
                public func f<Second, First>(left: First, right: Second): Unit {}

                extend<ExtensionRenamed> Box<ExtensionRenamed> {
                    public func extensionValue(value: ExtensionRenamed): ExtensionRenamed { value }
                }
                """
                    .toArray())
            let after = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(after, "CJDOC2006"))
            let afterIds = HashSet<String>()
            for (declaration in after.declarations) {
                let _ = afterIds.add(declaration.id)
            }
            @Expect(afterIds.size, beforeIds.size)
            for (id in beforeIds) {
                @Expect(afterIds.contains(id))
            }
            let encoded = api_render.encodeDocIr(after)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func extensionLocalPrivateAndEmptyBlocksHaveStableUniqueIdentities(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "extension_block_identity"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let sourcePath = temporary.join("src/api.cj")
            let compact = """
                package extension_block_identity

                public class Box<T> {
                    public init() {}
                }

                extend<T> Box<T> {
                    public func first(value: T): T { value }
                    private func hidden(value: T): T { value }
                }
                extend<U> Box<U> {
                    public func second(value: U): U { value }
                    private func hidden(value: U): U { value }
                }
                extend<V> Box<V> {}
                extend<W> Box<W> {}
                """
            File.writeTo(sourcePath, compact.toArray())
            let before = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off", audience: "all",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(before, "CJDOC2006"))
            let beforeIds = HashSet<String>()
            let extendIds = HashSet<String>()
            let referencedExtendIds = HashSet<String>()
            let hiddenIds = HashSet<String>()
            let hiddenOwnerIds = HashSet<String>()
            var extendCount: Int64 = 0
            var hiddenCount: Int64 = 0
            for (declaration in before.declarations) {
                let _ = beforeIds.add(declaration.id)
                if (declaration.kind == "extend") {
                    extendCount++
                    let _ = extendIds.add(declaration.id)
                }
                if (let Some(ownerId) <- declaration.ownerId) {
                    let _ = referencedExtendIds.add(ownerId)
                }
                if (declaration.name == "hidden") {
                    hiddenCount++
                    let _ = hiddenIds.add(declaration.id)
                    @Expect(declaration.id.contains("extension-block"))
                    @Expect(declaration.ownerId.isSome())
                    let _ = hiddenOwnerIds.add(declaration.ownerId.getOrThrow())
                }
                if (declaration.name == "first" || declaration.name == "second") {
                    @Expect(!declaration.id.contains("extension-block"))
                }
            }
            @Expect(extendCount, 4)
            @Expect(extendIds.size, 4)
            @Expect(hiddenCount, 2)
            @Expect(hiddenIds.size, 2)
            @Expect(hiddenOwnerIds.size, 2)
            for (ownerId in hiddenOwnerIds) {
                @Expect(extendIds.contains(ownerId))
            }
            var emptyOwners: Int64 = 0
            for (extendId in extendIds) {
                if (!referencedExtendIds.contains(extendId)) {
                    emptyOwners++
                    @Expect(extendId.contains("extension-block"))
                }
            }
            @Expect(emptyOwners, 2)

            File.writeTo(sourcePath,
                compact
                    .replace("\nextend<U>", "\n\n\n\nextend<U>")
                    .replace("\nextend<V>", "\n\n\nextend<V>")
                    .replace("\nextend<W>", "\n\n\n\nextend<W>")
                    .toArray())
            let after = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off", audience: "all",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(after, "CJDOC2006"))
            let afterIds = HashSet<String>()
            for (declaration in after.declarations) {
                let _ = afterIds.add(declaration.id)
            }
            @Expect(afterIds.size, beforeIds.size)
            for (id in beforeIds) {
                @Expect(afterIds.contains(id))
            }
            let encoded = api_render.encodeDocIr(after)
            @Expect(api_render.encodeDocIr(api_render.decodeDocIr(encoded)), encoded)
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }

    @TestCase
    func largeExtensionSetKeepsUniqueOwnerIdentities(): Unit {
        let temporary = Directory.createTemp(getTempDirectory())
        try {
            Directory.create(temporary.join("src"), recursive: true)
            File.writeTo(temporary.join("cjpm.toml"),
                """
                [package]
                cjc-version = "1.1.0"
                name = "identity_scale"
                version = "0.1.0"
                output-type = "static"
                """
                    .toArray())
            let source = StringBuilder()
            source.append("package identity_scale\n\n")
            source.append("public class Box<T> {\n    public init() {}\n}\n")
            var index: Int64 = 0
            while (index < 512) {
                source.append("\nextend Box<String> {\n")
                source.append("    public func member${index}(value: Int64): Int64 { value }\n")
                source.append("}\n")
                index++
            }
            File.writeTo(temporary.join("src/api.cj"), source.toString().toArray())
            let documentation = DocumentationEngine().generate(
                GenerationRequest(temporary.toString(), lintProfile: "off",
                    astPreflightExecutable: PUBLIC_TEST_AST_PREFLIGHT))
            @Expect(!publicHasDiagnostic(documentation, "CJDOC2006"))
            let allIds = HashSet<String>()
            let extendIds = HashSet<String>()
            var extendCount: Int64 = 0
            var memberCount: Int64 = 0
            for (declaration in documentation.declarations) {
                let _ = allIds.add(declaration.id)
                if (declaration.kind == "extend") {
                    extendCount++
                    let _ = extendIds.add(declaration.id)
                }
                if (declaration.name.startsWith("member")) {
                    memberCount++
                }
            }
            @Expect(extendCount, 512)
            @Expect(extendIds.size, 512)
            @Expect(memberCount, 512)
            for (declaration in documentation.declarations) {
                if (!declaration.name.startsWith("member")) {
                    continue
                }
                @Expect(declaration.ownerId.isSome())
                @Expect(allIds.contains(declaration.ownerId.getOrThrow()))
                @Expect(declaration.qualifiedName,
                    "identity_scale.Box < String >.${declaration.name}")
            }
        } finally {
            let _ = removeIfExists(temporary, recursive: true)
        }
    }
}
