package cjdoc

import cjdoc.model as query_model
import std.collection.*
import yjson.*

internal func queryCapturedPageModules(documentation: query_model.DocumentationSet,
    pages: Array<query_model.DocumentationPage>): HashMap<String, ?String> {
    let packageModules = HashMap<String, ?String>()
    for (packageDoc in documentation.packages) {
        match (packageModules.get(packageDoc.name)) {
            case Some(previous) => if (previous != Some(packageDoc.moduleId)) {
                packageModules[packageDoc.name] = Option<String>.None
            }
            case None => packageModules[packageDoc.name] = Some(packageDoc.moduleId)
        }
    }
    var root: ?String = None
    var foundRoot = false
    for (module in documentation.modules where module.role == "root") {
        root = if (foundRoot) { Option<String>.None } else { Some(module.id) }
        foundRoot = true
    }
    let result = HashMap<String, ?String>()
    for (page in pages) {
        // An unassociated guide has the snapshot's project edition as context,
        // not an invented declaration/module ownership claim.
        result[page.id] = if (page.packageName.isEmpty()) { root }
            else { packageModules.get(page.packageName).getOrDefault({ => Option<String>.None }) }
    }
    result
}

internal func queryPageAdmitted(input: QuerySnapshotInput, page: query_model.DocumentationPage,
    request: JsonObject): Bool {
    let kind = queryString(request, "kind")
    if (!kind.isEmpty() && kind != "concept") { return false }
    for (field in ["symbolId", "symbolKey", "name", "qualifiedName", "parameterTypes", "genericArity"]) {
        if (request.get(field).isSome()) { return false }
    }
    let packageName = queryString(request, "packageName")
    if (!packageName.isEmpty() && page.packageName != packageName) { return false }
    if (!queryString(request, "moduleId").isEmpty() && page.packageName.isEmpty()) { return false }
    var scoped = !queryString(request, "moduleId").isEmpty()
    for (field in ["documentSetId", "apiVersion", "library", "dependencyInstanceId", "target", "cfg"]) {
        scoped = scoped || !queryString(request, field).isEmpty()
    }
    if (!scoped) { return true }
    let moduleId = input.pageModules.get(page.id).getOrDefault({ => Option<String>.None })
    if (moduleId.isNone()) { return false }
    let id = moduleId.getOrThrow()
    if (!queryModuleIdMatches(input, id, request)) { return false }
    let (dependency, _) = queryDependencyState(input, id)
    queryScopeAdmits(queryDocumentSetFor(input, id), dependency, request)
}
