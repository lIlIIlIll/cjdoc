package cjdoc

import cjdoc.dependency.identity.DependencyIdentityInputs
import cjdoc.source.DependencySourceSelection

internal func dependencyIdentityInputs(request: GenerationRequest): DependencyIdentityInputs {
    let inputs = request.dependencySources
    let sources = Array<DependencySourceSelection>(inputs.size, { i =>
        DependencySourceSelection(inputs[i].name, inputs[i].path)
    })
    DependencyIdentityInputs(request.projectRoot, sources, request.buildContext,
        dependencyCfg(request), dependencyTarget(request))
}

private func dependencyCfg(request: GenerationRequest): String {
    let result = StringBuilder()
    var first = true
    for (value in request.cfgValues) {
        if (!first) { result.append("\n") }
        first = false
        result.append(value.name + "=" + value.value)
    }
    result.toString()
}

private func dependencyTarget(request: GenerationRequest): String {
    for (value in request.cfgValues) { if (value.name == "target") { return value.value } }
    ""
}
