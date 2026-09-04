package cjdoc

import cjdoc.model as api_model
import cjdoc.provider as api_provider
import std.collection.*

@When[os != "Linux"]
import std.posix.*

internal class DefaultExpressionCapture {
    var sawDeclaration: Bool = false
    var required: ?String = None
    var count: ?String = None
    var label: ?String = None
}

internal class DefaultExpressionSession <: api_provider.SemanticProviderSession {
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

internal class DefaultExpressionFactory <: api_provider.SemanticProviderFactory {
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

internal class HostileProviderCapture {
    var nameReads: Int64 = 0
    var versionReads: Int64 = 0
    var opened: Int64 = 0
    var analyzed: Int64 = 0
    var closed: Int64 = 0
}

internal func hostileProviderMessage(): String {
    String.fromUtf8(Array<Byte>(8192, repeat: b'x'))
}

internal class HostileProviderSession <: api_provider.SemanticProviderSession {
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

internal class HostileProviderFactory <: api_provider.SemanticProviderFactory {
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

internal class IdentityConflictSession <: api_provider.SemanticProviderSession {
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

internal class IdentityConflictFactory <: api_provider.SemanticProviderFactory {
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

internal class PartialSpellingCollapseSession <: api_provider.SemanticProviderSession {
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

internal class PartialSpellingCollapseFactory <: api_provider.SemanticProviderFactory {
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

internal class CrossModuleDiagnosticCapture {
    var firstModuleSymbolId: ?String = None
}

internal class CrossModuleDiagnosticSession <: api_provider.SemanticProviderSession {
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

internal class CrossModuleDiagnosticFactory <: api_provider.SemanticProviderFactory {
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

internal class AlternatingDiagnosticCapture {
    var reversed: Bool = false
}

internal class AlternatingDiagnosticSession <: api_provider.SemanticProviderSession {
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

internal class AlternatingDiagnosticFactory <: api_provider.SemanticProviderFactory {
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

internal class AlternatingTypeRelationshipCapture {
    var reversed: Bool = false
}

internal func orderingRelationshipTarget(kind: String, nullable: Bool, argument: String): api_model.TypeRef {
    api_model.TypeRef(kind, "Same", api_model.SemanticType("partial", provider: Some("alternating-relationship-test")),
        nullable: nullable,
        arguments: [api_model.TypeRef("semantic", argument,
            api_model.SemanticType("partial", provider: Some("alternating-relationship-test")))])
}

internal class AlternatingTypeRelationshipSession <: api_provider.SemanticProviderSession {
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

internal class AlternatingTypeRelationshipFactory <: api_provider.SemanticProviderFactory {
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
