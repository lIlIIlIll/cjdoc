protected package cjdoc.dependency.identity

import cjdoc.source.DependencySourceSelection

protected struct DependencyIdentityInputs {
    let projectRoot: String
    let dependencySources: Array<DependencySourceSelection>
    let buildContext: ?String
    let cfg: String
    let target: String

    protected init(projectRoot: String, dependencySources: Array<DependencySourceSelection>, buildContext: ?String,
        cfg: String, target: String) {
        this.projectRoot = projectRoot
        this.dependencySources = dependencySources
        this.buildContext = buildContext
        this.cfg = cfg
        this.target = target
    }
}
