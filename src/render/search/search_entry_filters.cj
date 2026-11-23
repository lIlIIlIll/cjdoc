protected package cjdoc.render.search

import std.collection.*
import std.sort.*

/** One normalized request filter: `{field, op, value}`. */
protected class SearchFilter {
    protected let field: String
    protected let op: String
    protected let value: String
    protected let foldedValue: String

    protected init(field: String, op: String, value: String) {
        this.field = field
        this.op = op
        this.value = value
        foldedValue = searchAsciiFold(value)
    }

    protected func key(): String { field + "\u{0}" + op + "\u{0}" + value }
}

internal func searchFilterSpec(field: String): ?SearchFilterSpec {
    SEARCH_FILTER_SPECS.get(field)
}

private func searchFieldMatches(actual: String, actualFolded: String,
    filter: SearchFilter): Bool {
    let primitive = match (SEARCH_FILTER_OPS.get(filter.op)) {
        case Some(value) => value
        case None => ""
    }
    match (primitive) {
        case "exact_string_equal" => actual == filter.value
        case "ascii_fold_contains" => actualFolded.contains(filter.foldedValue)
        case _ => false
    }
}

protected class SearchFilterMatch {
    protected let admitted: Bool
    protected let matchedExposureIds: Array<String>

    protected init(admitted: Bool, matchedExposureIds!: Array<String> = []) {
        this.admitted = admitted
        this.matchedExposureIds = matchedExposureIds
    }
}

private func searchContextPropertyMatches(property: String, filter: SearchFilter,
    name: String, nameFolded: String, qualifiedName: String, qualifiedNameFolded: String,
    packageName: String, packageNameFolded: String): Bool {
    match (property) {
        case "name" => searchFieldMatches(name, nameFolded, filter)
        case "qualifiedName" => searchFieldMatches(qualifiedName, qualifiedNameFolded, filter)
        case "packageName" => searchFieldMatches(packageName, packageNameFolded, filter)
        case _ => false
    }
}

private func searchContextAdmits(name: String, nameFolded: String,
    qualifiedName: String, qualifiedNameFolded: String, packageName: String,
    packageNameFolded: String, filters: ArrayList<SearchFilter>): Bool {
    for (filter in filters) {
        let spec = match (searchFilterSpec(filter.field)) {
            case Some(value) => value
            case None => return false
        }
        if (spec.context != "canonical-or-exposure") { continue }
        let property = if (spec.properties.isEmpty()) { "" } else { spec.properties[0] }
        if (!searchContextPropertyMatches(property, filter, name, nameFolded,
            qualifiedName, qualifiedNameFolded, packageName, packageNameFolded)) {
            return false
        }
    }
    true
}

private func searchContextFiltersPresent(filters: ArrayList<SearchFilter>): Bool {
    for (filter in filters) {
        match (searchFilterSpec(filter.field)) {
            case Some(spec) =>
                if (spec.context == "canonical-or-exposure") { return true }
            case None => ()
        }
    }
    false
}

private func searchEntryPropertyMatches(facts: SearchPreparedEntry,
    property: String, filter: SearchFilter): Bool {
    let entry = facts.entry
    match (property) {
        case "ownerName" =>
            !entry.ownerName.isEmpty() &&
                searchFieldMatches(entry.ownerName, facts.ownerNameFolded, filter)
        case "ownerQualifiedName" =>
            !entry.ownerQualifiedName.isEmpty() &&
                searchFieldMatches(entry.ownerQualifiedName, facts.ownerQualifiedNameFolded, filter)
        case "parameterTypes" =>
            var index: Int64 = 0
            while (index < entry.parameterTypes.size) {
                if (searchFieldMatches(entry.parameterTypes[index],
                    facts.parameterTypesFolded[index], filter)) { return true }
                index++
            }
            false
        case "returnType" =>
            !entry.returnType.isEmpty() &&
                searchFieldMatches(entry.returnType, facts.returnTypeFolded, filter)
        case "returnCanonical" =>
            !entry.returnCanonical.isEmpty() &&
                searchFieldMatches(entry.returnCanonical, facts.returnCanonicalFolded, filter)
        case "kind" =>
            !entry.kind.isEmpty() && searchFieldMatches(entry.kind, facts.kindFolded, filter)
        case _ => false
    }
}

private func searchEntryFilterAdmits(facts: SearchPreparedEntry,
    filters: ArrayList<SearchFilter>): Bool {
    for (filter in filters) {
        let spec = match (searchFilterSpec(filter.field)) {
            case Some(value) => value
            case None => return false
        }
        if (spec.context != "entry") { continue }
        var satisfied = false
        for (property in spec.properties) {
            if (searchEntryPropertyMatches(facts, property, filter)) {
                satisfied = true
                break
            }
        }
        if (!satisfied) { return false }
    }
    true
}

private func searchPreparedContextAdmits(facts: SearchPreparedEntry,
    filters: ArrayList<SearchFilter>): SearchFilterMatch {
    let entry = facts.entry
    let canonicalAdmits = searchContextAdmits(entry.name, facts.nameFolded,
        if (entry.concept) { "" } else { entry.qualifiedName },
        if (entry.concept) { "" } else { facts.qualifiedNameFolded },
        if (entry.concept) { "" } else { entry.packageName },
        if (entry.concept) { "" } else { facts.packageNameFolded }, filters)
    let matchedExposures = ArrayList<String>()
    if (!entry.concept) {
        for (prepared in facts.exposures) {
            let exposure = prepared.exposure
            if (searchContextAdmits(exposure.name, prepared.nameFolded,
                exposure.qualifiedName, prepared.qualifiedNameFolded,
                exposure.packageName, prepared.packageNameFolded, filters)) {
                matchedExposures.add(exposure.id)
            }
        }
    }
    if (!canonicalAdmits && matchedExposures.isEmpty()) {
        return SearchFilterMatch(false)
    }
    sort(matchedExposures,
        lessThan: { left, right => searchUtf8ByteLess(left, right) }, stable: true)
    SearchFilterMatch(true, matchedExposureIds: matchedExposures.toArray())
}

/**
 * All canonical-or-exposure predicates must hold in one spelling context.
 * Entry-field predicates then independently narrow that same canonical result.
 */
internal func searchFilterAdmits(facts: SearchPreparedEntry,
    filters: ArrayList<SearchFilter>): SearchFilterMatch {
    if (filters.isEmpty()) { return SearchFilterMatch(true) }
    if (!searchEntryFilterAdmits(facts, filters)) { return SearchFilterMatch(false) }
    if (!searchContextFiltersPresent(filters)) { return SearchFilterMatch(true) }
    searchPreparedContextAdmits(facts, filters)
}

private func searchSortedTagIdContains(sortedIds: Array<String>, requested: String): Bool {
    var low: Int64 = 0
    var high: Int64 = sortedIds.size
    while (low < high) {
        let middle = low + (high - low) / 2
        let candidate = sortedIds[middle]
        if (candidate == requested) { return true }
        if (searchUtf8ByteLess(candidate, requested)) { low = middle + 1 }
        else { high = middle }
    }
    false
}

private func searchSetPredicateAdmits(entry: SearchProjectedEntry,
    predicate: SearchSetPredicate, requested: Array<String>): Bool {
    if (requested.isEmpty()) { return true }
    match (predicate.primitive) {
        case "all_exact" =>
            if (entry.concept) { return false }
            let actual = match (predicate.property) {
                case "tagIds" => entry.tagIds
                case _ => throw IllegalStateException("unsupported search set-predicate property")
            }
            for (value in requested) {
                if (!searchSortedTagIdContains(actual, value)) { return false }
            }
            true
        case _ => throw IllegalStateException("unsupported search set-predicate primitive")
    }
}

internal func searchSetPredicatesAdmit(entry: SearchProjectedEntry,
    requested: HashMap<String, Array<String>>): Bool {
    for (predicate in SEARCH_SET_PREDICATES) {
        match (requested.get(predicate.field)) {
            case Some(values) =>
                if (!searchSetPredicateAdmits(entry, predicate, values)) { return false }
            case None => ()
        }
    }
    true
}
