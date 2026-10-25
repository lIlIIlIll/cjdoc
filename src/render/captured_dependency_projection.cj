package cjdoc.render

import cjdoc.model.*
import std.collection.*

private func sameCapturedDependency(left: DependencyInstance, right: DependencyInstance): Bool {
    left.instanceId == right.instanceId && left.moduleId == right.moduleId && left.name == right.name &&
        left.kind == right.kind && left.identity == right.identity && left.state == right.state &&
        left.evidence == right.evidence && left.version == right.version && left.revision == right.revision &&
        left.target == right.target && left.cfg == right.cfg && left.componentModuleId == right.componentModuleId
}

// A local module's own source observation is not a consumer dependency. Index
// this distinction once for static details and every query, without choosing
// between several captured instances by traversal order.
internal func capturedDependencyProjection(documentation: DocumentationSet):
    HashMap<String, (?DependencyInstance, String)> {
    let result = HashMap<String, (?DependencyInstance, String)>()
    for (module in documentation.modules) {
        result[module.id] = (Option<DependencyInstance>.None,
            if (module.role == "root" || module.role == "workspace") { "not_applicable" } else { "unrecorded" })
    }
    for (dependency in documentation.dependencies) {
        if (dependency.instanceId.isEmpty() || !result.contains(dependency.componentModuleId)) { continue }
        let (previous, state) = result[dependency.componentModuleId]
        if (state == "not_applicable" || state == "ambiguous") { continue }
        match (previous) {
            case Some(value) => if (!sameCapturedDependency(value, dependency)) {
                result[dependency.componentModuleId] = (Option<DependencyInstance>.None, "ambiguous")
            }
            case None => result[dependency.componentModuleId] = (Some(dependency), "recorded")
        }
    }
    result
}
