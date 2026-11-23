protected package cjdoc.source.cache

import cjdoc.source.model.SourceInputFile
import cjdoc.source.model.{SourcePackage, SourceSnapshot}
import std.collection.*
internal func sourceAggregationKey(left: String, right: String): String {
    "${left.size}:${left}${right}"
}

internal class SourceAggregationIndex {
    private let packages = HashMap<String, SourcePackage>()
    private let modulePackages = HashSet<String>()
    private let packageFiles = HashSet<String>()

    func add(source: SourceSnapshot, input: SourceInputFile, packageName: String): Unit {
        let packageKey = sourceAggregationKey(input.module.id, packageName)
        if (modulePackages.add(packageKey)) { input.module.packageNames.add(packageName) }
        let pkg = match (packages.get(packageKey)) {
            case Some(value) => value
            case None =>
                let value = SourcePackage(packageName, input.module.id)
                packages[packageKey] = value
                source.packages.add(value)
                value
        }
        if (packageFiles.add(sourceAggregationKey(packageKey, input.logicalPath))) {
            pkg.sourceFiles.add(input.logicalPath)
        }
    }
}
