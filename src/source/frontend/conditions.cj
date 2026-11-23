protected package cjdoc.source.frontend

import cjdoc.source.model.{UnsupportedDeclaration, SourceSnapshot}
import cjdoc.source.Diagnostic
import std.collection.*
import cjdoc.source.cfg.{CfgProfile, cfgSelection}

protected func filterSourceForCfg(source: SourceSnapshot, profile: CfgProfile): Unit {
    let includedByKey = HashMap<String, Bool>()
    let included = ArrayList<Bool>()
    for (declaration in source.declarations) {
        var ownerExcluded = false
        if (let Some(ownerKey) <- declaration.ownerSourceKey) {
            if (let Some(ownerIncluded) <- includedByKey.get(ownerKey)) {
                ownerExcluded = !ownerIncluded
            }
        }
        let keep = if (ownerExcluded) {
            false
        } else {
            match (cfgSelection(declaration.annotations, profile)) {
                case Some(selected) => selected
                case None =>
                    source.diagnostics.add(Diagnostic("warning", "CJDOC1019",
                        "conditional declaration omitted because its @When expression is unsupported or unresolved",
                        source: declaration.source))
                    source.unsupportedDeclarations.add(UnsupportedDeclaration(declaration.kind,
                        declaration.name,
                        "conditional compilation expression is unsupported or unresolved",
                        declaration.source))
                    false
            }
        }
        included.add(keep)
        includedByKey[declaration.sourceKey] = keep
    }
    var index = source.declarations.size - 1
    while (index >= 0) {
        if (!included[index]) { source.declarations.remove(at: index) }
        index--
    }
}
