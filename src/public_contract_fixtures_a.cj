package cjdoc

import cjdoc.model as api_model
import cjdoc.provider as api_provider
import std.collection.*

internal let PUBLIC_FIXTURE_PROJECTS = "tests/fixtures/projects/"
internal let PUBLIC_TEST_AST_PREFLIGHT = Some("target/release/bin/main")

@When[os == "Linux"]
internal func publicLocalAssetEmbeddingEnabled(): Bool {
    true
}

@When[os != "Linux"]
internal func publicLocalAssetEmbeddingEnabled(): Bool {
    false
}

internal class ProviderLifecycle {
    var opened: Int64 = 0
    var analyzed: Int64 = 0
    var closed: Int64 = 0
}

internal class LifecycleSession <: api_provider.SemanticProviderSession {
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

internal class LifecycleFactory <: api_provider.SemanticProviderFactory {
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

internal class UnknownIdSession <: api_provider.SemanticProviderSession {
    public func analyze(_: ReadOnlyList<api_provider.SourceDeclarationView>): api_provider.SemanticBatch {
        let foreignIssuer = api_provider.SourceDeclarationIssuer()
        api_provider.SemanticBatch(api_model.SemanticCapabilities(true, false, false, false, false),
            declarations: [api_provider.SemanticDeclaration(foreignIssuer.issue("not-issued-by-cjdoc"), "partial")])
    }

    public func close(): Unit {}
}

internal class UnknownIdFactory <: api_provider.SemanticProviderFactory {
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

internal class WorkspaceTransactionSession <: api_provider.SemanticProviderSession {
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

internal class WorkspaceTransactionFactory <: api_provider.SemanticProviderFactory {
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

internal class CloseFailureSession <: api_provider.SemanticProviderSession {
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

internal class CloseFailureFactory <: api_provider.SemanticProviderFactory {
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

internal class AnnotationSession <: api_provider.SemanticProviderSession {
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

internal class AnnotationFactory <: api_provider.SemanticProviderFactory {
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

internal class RelationshipSession <: api_provider.SemanticProviderSession {
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

internal class RelationshipFactory <: api_provider.SemanticProviderFactory {
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

internal class StateSession <: api_provider.SemanticProviderSession {
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

internal class StateFactory <: api_provider.SemanticProviderFactory {
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

internal func deeplyNestedProviderType(): api_model.TypeRef {
    var value = api_model.TypeRef("source", "Leaf", api_model.SemanticType("partial"))
    var depth: Int64 = 0
    while (depth < api_model.DOC_IR_MAX_TYPE_DEPTH + 2) {
        value = api_model.TypeRef("source", "Layer", api_model.SemanticType("partial"), arguments: [value])
        depth++
    }
    value
}

internal class ImplicitTypeProviderSession <: api_provider.SemanticProviderSession {
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

internal class ImplicitTypeProviderFactory <: api_provider.SemanticProviderFactory {
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
