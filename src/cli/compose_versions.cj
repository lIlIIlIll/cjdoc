protected package cjdoc.cli

import cjdoc.output.{prepareOutputAndCacheDirectories, publishOutputArtifacts}
import cjdoc.versions.prepareVersionComposition

protected func runVersionsCompose(options: NewCliOptions): Int64 {
    let output = match (options.output) {
        case Some(path) => path
        case None => throw IllegalArgumentException("versions compose requires --output")
    }
    let (specs, latest, latestPolicy) = buildVersionSpecs(options)
    let artifacts = prepareVersionComposition(specs, latest, latestPolicy, output)
    let (prepared, _) = prepareOutputAndCacheDirectories(output, None<String>)
    publishOutputArtifacts(prepared, artifacts, options.forceOwned)
    println("composed ${specs.size} documentation versions into ${output}")
    0
}
