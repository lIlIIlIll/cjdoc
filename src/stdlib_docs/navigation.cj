protected package cjdoc.stdlib_docs

import cjdoc.model as standard_library_model
import std.collection.*

private let STS_1_2_0_STANDARD_LIBRARY_DOCS_BASE = "https://cj-docs.gitcode.com/zh/1.2.0/libs/std"

private func buildSts120StandardLibraryDocTargets(): HashMap<String, String> {
    let targets = HashMap<String, String>()
    for ((qualifiedName, route) in STS_1_2_0_STANDARD_LIBRARY_DOC_ROUTES) {
        targets[qualifiedName] = route
    }
    targets
}

private let STS_1_2_0_STANDARD_LIBRARY_DOC_TARGETS = buildSts120StandardLibraryDocTargets()

private func buildStandardLibraryDocPackages(): HashSet<String> {
    let packages = HashSet<String>()
    for ((qualifiedName, _) in STS_1_2_0_STANDARD_LIBRARY_DOC_ROUTES) {
        var end = qualifiedName.size
        while (end > 0 && qualifiedName[end - 1] != b'.') { end-- }
        if (end > 0) { let _ = packages.add(qualifiedName[..end - 1]) }
    }
    packages
}

private let STANDARD_LIBRARY_DOC_PACKAGES = buildStandardLibraryDocPackages()

protected func hasStandardLibraryDocPackage(packageName: String): Bool {
    STANDARD_LIBRARY_DOC_PACKAGES.contains(packageName)
}

private let STS_1_1_0_BETA_25_STANDARD_LIBRARY_DOC_ROUTE_OVERRIDES: Array<(String, String)> = [
    ("std.collection.concurrent.ConcurrentHashMap", "collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.html#class-concurrenthashmapk-v-where-k--hashable--equatablek"),
    ("std.collection.concurrent.ConcurrentHashMapIterator", "collection_concurrent/collection_concurrent_package_api/collection_concurrent_class.html#class-concurrenthashmapiteratork-v-where-k--hashable--equatablek"),
    ("std.collection.HashMap", "collection/collection_package_api/collection_package_class.html#class-hashmapk-v-where-k--hashable--equatablek"),
    ("std.collection.HashMapIterator", "collection/collection_package_api/collection_package_class.html#class-hashmapiteratork-v-where-k--hashable--equatablek"),
    ("std.collection.HashSet", "collection/collection_package_api/collection_package_class.html#class-hashsett-where-t--hashable--equatablet"),
    ("std.collection.TreeMap", "collection/collection_package_api/collection_package_class.html#class-treemapk-v-where-k--comparablek"),
    ("std.collection.TreeSet", "collection/collection_package_api/collection_package_class.html#class-treesett-where-t--comparablet"),
    ("std.core.CPointerHandle", "core/core_package_api/core_package_structs.html#struct-cpointerhandlet-where-t--ctype"),
    ("std.core.CPointerResource", "core/core_package_api/core_package_structs.html#struct-cpointerresourcet-where-t--ctype"),
    ("std.core.Range", "core/core_package_api/core_package_structs.html#struct-ranget-where-t--countablet--comparablet--equatablet"),
    ("std.core.RangeIterator", "core/core_package_api/core_package_classes.html#class-rangeiteratort--iteratort-where-t--countablet--comparablet--equatablet"),
    ("std.io.BufferedInputStream", "io/io_package_api/io_package_classes.html#class-bufferedinputstreamt-where-t--inputstream"),
    ("std.io.BufferedOutputStream", "io/io_package_api/io_package_classes.html#class-bufferedoutputstreamt-where-t--outputstream"),
    ("std.io.ChainedInputStream", "io/io_package_api/io_package_classes.html#class-chainedinputstreamt-where-t--inputstream"),
    ("std.io.MultiOutputStream", "io/io_package_api/io_package_classes.html#class-multioutputstreamt-where-t--outputstream"),
    ("std.io.StringReader", "io/io_package_api/io_package_classes.html#class-stringreadert-where-t--inputstream"),
    ("std.io.StringWriter", "io/io_package_api/io_package_classes.html#class-stringwritert-where-t--outputstream"),
    ("std.objectpool.ObjectPool", "objectpool/objectpool_package_api/objectpool_package_classes.html#class-objectpoolt-where-t--object-deprecated"),
    ("std.reflect.Annotation", "reflect/reflect_package_api/reflect_package_types.html#type-annotation--object"),
    ("std.runtime.SignalHandlerFunc", "runtime/runtime_package_api/runtime_package_types.html#type-signalhandlerfunc--int32---bool"),
    ("std.sync.AtomicOptionReference", "sync/sync_package_api/sync_package_classes.html#class-atomicoptionreferencet-where-t--object"),
    ("std.sync.AtomicReference", "sync/sync_package_api/sync_package_classes.html#class-atomicreferencet-where-t--object"),
    ("std.unittest.CartesianProductProcessor", "unittest/unittest_package_api/unittest_package_classes.html#class-cartesianproductprocessort0t1"),
    ("std.unittest.FlatMapProcessor", "unittest/unittest_package_api/unittest_package_classes.html#class-flatmapprocessortr"),
    ("std.unittest.FlatMapStrategyProcessor", "unittest/unittest_package_api/unittest_package_classes.html#class-flatmapstrategyprocessortr"),
    ("std.unittest.MapProcessor", "unittest/unittest_package_api/unittest_package_classes.html#class-mapprocessortr")
]

private let STS_1_1_0_BETA_25_UNAVAILABLE_TYPES: Array<String> = [
    "std.unittest.Runtime",
    "std.unittest.RuntimeInfo"
]

private func buildSts110StandardLibraryDocOverrides(): HashMap<String, String> {
    let targets = HashMap<String, String>()
    for ((qualifiedName, route) in STS_1_1_0_BETA_25_STANDARD_LIBRARY_DOC_ROUTE_OVERRIDES) {
        targets[qualifiedName] = route
    }
    targets
}

private let STS_1_1_0_BETA_25_STANDARD_LIBRARY_DOC_TARGET_OVERRIDES =
    buildSts110StandardLibraryDocOverrides()

private let STANDARD_LIBRARY_DOCS_BASES: Array<(String, String)> = [
    ("1.0.5", "https://docs.cangjie-lang.cn/docs/1.0.5/libs/std"),
    ("1.1.0", "https://docs.cangjie-lang.cn/docs/1.1.0/libs/std"),
    ("1.1.0-beta.25", "https://docs.cangjie-lang.cn/docs/1.1.0-beta.25/libs/std"),
    ("1.1.3", "https://cj-docs.gitcode.com/zh/1.1.3/libs/std"),
    ("1.2.0", STS_1_2_0_STANDARD_LIBRARY_DOCS_BASE)
]

private func standardLibraryDocsVersionByteIsSafe(byte: Byte): Bool {
    (byte >= b'a' && byte <= b'z') || (byte >= b'A' && byte <= b'Z') ||
        (byte >= b'0' && byte <= b'9') || byte == b'.' || byte == b'-' ||
        byte == b'+' || byte == b'_'
}

protected func isValidStandardLibraryDocsVersion(version: String): Bool {
    if (version.isEmpty() || version.size > 128 || version.startsWith(".") ||
        version.contains("..")) { return false }
    let first = version[0]
    if ((first < b'a' || first > b'z') && (first < b'A' || first > b'Z') &&
        (first < b'0' || first > b'9')) { return false }
    var index: Int64 = 0
    while (index < version.size) {
        if (!standardLibraryDocsVersionByteIsSafe(version[index])) { return false }
        index++
    }
    true
}

protected func isValidStandardLibraryDocsBaseUrl(baseUrl: String): Bool {
    if (baseUrl.size > 2048 || !baseUrl.startsWith("https://") ||
        !baseUrl.endsWith("/libs/std") || baseUrl.contains("\\") ||
        baseUrl.contains("..") || baseUrl.contains("#") || baseUrl.contains("?") ||
        baseUrl.contains(" ") || baseUrl.contains("\t") || baseUrl.contains("\n") ||
        baseUrl.contains("\r")) { return false }
    standard_library_model.isSafeAbsoluteDocumentationUrl(baseUrl,
        allowFragment: false, allowQuery: false)
}

private func standardLibraryDocsDefaultBaseUrl(version: String): String {
    for ((knownVersion, baseUrl) in STANDARD_LIBRARY_DOCS_BASES) {
        if (knownVersion == version) { return baseUrl }
    }
    ""
}

protected func hasBuiltInStandardLibraryDocsBase(version: String): Bool {
    !standardLibraryDocsDefaultBaseUrl(version).isEmpty()
}

protected func defaultStandardLibraryDocsVersion(): String { "1.2.0" }

private func standardLibraryDocsBaseUrl(version: String,
    baseUrlOverride: ?String): String {
    if (let Some(baseUrl) <- baseUrlOverride) { return baseUrl }
    standardLibraryDocsDefaultBaseUrl(version)
}

private func standardLibraryDocRoutesAreValidated(version: String): Bool {
    version == "1.2.0" || version == "1.1.0-beta.25"
}

private func standardLibraryDocRoute(version: String,
    qualifiedName: String): ?String {
    if (version == "1.1.0-beta.25" &&
        STS_1_1_0_BETA_25_UNAVAILABLE_TYPES.contains(qualifiedName)) { return None }
    if (version.startsWith("1.1.")) {
        if (let Some(route) <- STS_1_1_0_BETA_25_STANDARD_LIBRARY_DOC_TARGET_OVERRIDES.get(qualifiedName)) {
            return Some(route)
        }
    }
    STS_1_2_0_STANDARD_LIBRARY_DOC_TARGETS.get(qualifiedName)
}

protected func hasStandardLibraryDocTarget(version: String, qualifiedName: String,
    baseUrlOverride!: ?String = None): Bool {
    !standardLibraryDocsBaseUrl(version, baseUrlOverride).isEmpty() &&
        standardLibraryDocRoute(version, qualifiedName).isSome()
}

protected func standardLibraryTypeNavigation(version: String,
    names: Array<String>, baseUrlOverride!: ?String = None): ?standard_library_model.TypeNavigation {
    let baseUrl = standardLibraryDocsBaseUrl(version, baseUrlOverride)
    if (baseUrl.isEmpty()) { return None }
    var url = ""
    for (name in names) {
        if (let Some(route) <- standardLibraryDocRoute(version, name)) {
            let candidate = baseUrl + "/" + route
            if (!url.isEmpty() && url != candidate) { return None }
            url = candidate
        }
    }
    if (url.isEmpty()) { return None }
    let reason = if (baseUrlOverride.isSome()) {
        "configured standard-library documentation base for ${version}; not API identity evidence"
    } else if (standardLibraryDocRoutesAreValidated(version)) {
        "validated official ${version} standard-library documentation route; not API identity evidence"
    } else {
        "best-effort standard-library documentation route for ${version}; page and anchor are unvalidated"
    }
    Some(standard_library_model.TypeNavigation("resolved", "manual", reason, url: url))
}

