protected package cjdoc.versions

import cjdoc.filesystem.{canonicalForWrite, pathContains}
import cjdoc.render.RenderArtifact
import std.collection.ArrayList
import std.fs.*

protected func prepareVersionComposition(specs: ArrayList<VersionComposeSpec>,
    latest: String, latestPolicy: String, output: String): Array<RenderArtifact> {
    let sites = ArrayList<VersionSite>()
    let budget = VersionComposeBudget()
    for (spec in specs) { sites.add(loadVersionSite(spec, budget)) }
    let outputPath = canonicalForWrite(Path(output), "version composition output")
    for (site in sites) {
        let source = canonicalize(Path(site.spec.source))
        if (pathContains(source, outputPath) || pathContains(outputPath, source)) {
            throw IllegalArgumentException("version source and composition output overlap")
        }
        match (site.spec.apiDiffSource) {
            case Some(path) =>
                let diff = canonicalize(Path(path))
                if (pathContains(diff, outputPath) || pathContains(outputPath, diff)) {
                    throw IllegalArgumentException("version API diff and composition output overlap")
                }
            case None => ()
        }
    }
    composeVersionArtifacts(sites, latest, latestPolicy, budget)
}
