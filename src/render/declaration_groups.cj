package cjdoc.render

import cjdoc.model.*
import std.collection.*
import std.sort.*

internal class DeclarationGroup {
    let id: String
    var title: String
    let scopeKey: String
    let scopeSortBytes: Array<Byte>
    let order: ?Int64
    let splitByScope: Bool
    let partitionKey: String
    let symbols = ArrayList<SymbolDoc>()
    var anchor = ""
    var kindPrefix = ""
    var isPrimary = false

    init(id: String, title: String, scopeKey: String, order: ?Int64,
        splitByScope: Bool, partitionKey: String) {
        this.id = id
        this.title = title
        this.scopeKey = scopeKey
        this.scopeSortBytes = scopeKey.toArray()
        this.order = order
        this.splitByScope = splitByScope
        this.partitionKey = partitionKey
    }
}

/**
 * Heading structure of one grouped declaration partition.
 *
 * Counts come from the published projection, so an audience/cfg decision can
 * never be re-derived here: a group whose kind partition has exactly one
 * non-empty category omits the redundant category heading, while a mixed group
 * keeps it one level below the group heading.
 */
internal class DeclarationGroupLayout {
    let showKindHeading: Bool
    let kindHeadingLevel: Int64
    let entryParentLevel: Int64

    init(showKindHeading: Bool, kindHeadingLevel: Int64, entryParentLevel: Int64) {
        this.showKindHeading = showKindHeading
        this.kindHeadingLevel = kindHeadingLevel
        this.entryParentLevel = entryParentLevel
    }
}

internal func declarationGroupLayout(visibleKindCount: Int64,
    groupHeadingLevel: Int64): DeclarationGroupLayout {
    if (visibleKindCount <= 1) {
        return DeclarationGroupLayout(false, groupHeadingLevel, groupHeadingLevel)
    }
    let kindLevel = groupHeadingLevel + 1
    return DeclarationGroupLayout(true, kindLevel, kindLevel)
}

private func utf8BytesLessThan(left: Array<Byte>, right: Array<Byte>): Bool {
    let sharedSize = if (left.size < right.size) { left.size } else { right.size }
    var index: Int64 = 0
    while (index < sharedSize) {
        let leftByte = Int64(left[index])
        let rightByte = Int64(right[index])
        if (leftByte != rightByte) { return leftByte < rightByte }
        index++
    }
    left.size < right.size
}

private func declarationGroupLessThan(left: DeclarationGroup, right: DeclarationGroup): Bool {
    if (left.id.isEmpty()) { return false }
    if (right.id.isEmpty()) { return true }
    match ((left.order, right.order)) {
        case (Some(leftOrder), Some(rightOrder)) =>
            if (leftOrder != rightOrder) { return leftOrder < rightOrder }
        case (Some(_), None) => return true
        case (None, Some(_)) => return false
        case _ => ()
    }
    if (left.id != right.id) { return left.id < right.id }
    if (left.scopeKey != right.scopeKey) {
        return utf8BytesLessThan(left.scopeSortBytes, right.scopeSortBytes)
    }
    false
}

/**
 * Partition the captured visible declarations by catalog classifications.
 *
 * Without a matching central definition, same-ID inline groups retain their
 * historical page-local merge and conflicting-title fallback. If any
 * same-ID source scope has a matching captured definition and another scope
 * is visible on the page, all source scopes are kept distinct.
 */
internal func partitionDeclarationGroups(symbols: ArrayList<SymbolDoc>,
    catalog: DeclarationGroupCatalog): ArrayList<DeclarationGroup> {
    let classifications = ArrayList<(SymbolDoc, ?DeclarationGroupClassification)>()
    let scopesById = HashMap<String, HashSet<String>>()
    let definedIds = HashSet<String>()
    for (symbol in symbols) {
        let group = catalog.groupFor(symbol)
        classifications.add((symbol, group))
        match (group) {
            case Some(value) =>
                match (scopesById.get(value.id)) {
                    case Some(scopes) => let _ = scopes.add(value.scopeKey)
                    case None =>
                        let scopes = HashSet<String>()
                        let _ = scopes.add(value.scopeKey)
                        scopesById[value.id] = scopes
                }
                if (value.defined) { let _ = definedIds.add(value.id) }
            case None => ()
        }
    }

    let splitIds = HashSet<String>()
    for ((id, scopes) in scopesById) {
        if (definedIds.contains(id) && scopes.size > 1) { let _ = splitIds.add(id) }
    }

    let resultByKey = HashMap<String, DeclarationGroup>()
    let result = ArrayList<DeclarationGroup>()
    for ((symbol, group) in classifications) {
        let id = match (group) {
            case Some(value) => value.id
            case None => ""
        }
        let scopeKey = match (group) {
            case Some(value) => value.scopeKey
            case None => ""
        }
        let split = !id.isEmpty() && splitIds.contains(id)
        let partitionKey = if (id.isEmpty()) { "" }
            else if (split) { "${id.size}:${id}${scopeKey}" }
            else { id }
        let title = match (group) {
            case Some(value) => value.title
            case None => ""
        }
        let order: ?Int64 = match (group) {
            case Some(value) => value.order
            case None => None
        }
        let role = match (resultByKey.get(partitionKey)) {
            case Some(value) =>
                if (!id.isEmpty() && value.title != title) { value.title = value.id }
                value
            case None =>
                let value = DeclarationGroup(id, title, scopeKey, order, split, partitionKey)
                resultByKey[partitionKey] = value
                result.add(value)
                value
        }
        role.symbols.add(symbol)
    }
    sort(result, lessThan: { left, right => declarationGroupLessThan(left, right) },
        stable: true)
    result
}

internal func hasGroupedDeclarations(groups: ArrayList<DeclarationGroup>): Bool {
    for (group in groups where !group.id.isEmpty()) { return true }
    false
}

internal func declarationGroupDisplayTitle(group: DeclarationGroup, locale: String): String {
    if (group.id.isEmpty()) { label(locale, "Other declarations", "其他声明") } else { group.title }
}

private func groupHashSuffix(group: DeclarationGroup): String {
    stableFileHash(group.scopeKey)
}

private func scopeHexFallback(group: DeclarationGroup): String {
    let digits = "0123456789abcdef"
    let result = StringBuilder()
    for (byte in group.scopeSortBytes) {
        let high = Int64((byte >> 4) & 0x0F)
        let low = Int64(byte & 0x0F)
        result.append(digits[high..high + 1])
        result.append(digits[low..low + 1])
    }
    result.toString()
}

/**
 * Assign old primary anchors and deterministic scope-specific aliases.
 *
 * The preferred page container wins independently of display order; otherwise
 * the UTF-8-smallest original scope owns the old bare group ID.
 */
internal func prepareDeclarationGroupAnchors(groups: ArrayList<DeclarationGroup>,
    pageModuleId: String, pagePackageName: String, pageOwnerId: ?String): Unit {
    let byId = HashMap<String, ArrayList<DeclarationGroup>>()
    let primaryAnchors = HashSet<String>()
    for (group in groups) {
        group.isPrimary = false
        if (group.id.isEmpty()) {
            group.anchor = "api-ungrouped"
            group.kindPrefix = "api-kind-0--"
            continue
        }
        if (!group.splitByScope) {
            group.anchor = "api-group-${group.id}"
            group.kindPrefix = "api-kind-${group.id.size}-${group.id}-"
            group.isPrimary = true
            let _ = primaryAnchors.add(group.anchor)
        }
        match (byId.get(group.id)) {
            case Some(values) => values.add(group)
            case None => byId[group.id] = ArrayList<DeclarationGroup>([group])
        }
    }

    for ((id, values) in byId) {
        if (values.size <= 1) {
            if (!values[0].isPrimary) {
                values[0].isPrimary = true
                values[0].anchor = "api-group-${id}"
                values[0].kindPrefix = "api-kind-${id.size}-${id}-"
                let _ = primaryAnchors.add(values[0].anchor)
            }
            continue
        }
        var selected: ?DeclarationGroup = None
        let pageScope = documentationMetadataGroupKey(pageModuleId, pagePackageName,
            pageOwnerId, id)
        for (group in values) {
            if (group.scopeKey == pageScope) { selected = Some(group); break }
        }
        if (selected.isNone()) {
            var smallest = values[0]
            var index: Int64 = 1
            while (index < values.size) {
                let group = values[index]
                if (utf8BytesLessThan(group.scopeSortBytes, smallest.scopeSortBytes)) {
                    smallest = group
                }
                index++
            }
            selected = Some(smallest)
        }
        let primary = selected.getOrThrow()
        primary.isPrimary = true
        primary.anchor = "api-group-${id}"
        primary.kindPrefix = "api-kind-${id.size}-${id}-"
        let _ = primaryAnchors.add(primary.anchor)
    }

    let hashAnchors = HashMap<String, Int64>()
    for (group in groups where !group.id.isEmpty() && !group.isPrimary) {
        let candidate = "api-group-${group.id}--${groupHashSuffix(group)}"
        hashAnchors[candidate] = hashAnchors.get(candidate).getOrDefault({ => 0 }) + 1
    }
    let scopeFallbacks = ArrayList<DeclarationGroup>()
    let usedAnchors = HashSet<String>()
    for (anchor in primaryAnchors) { let _ = usedAnchors.add(anchor) }
    for (group in groups where !group.id.isEmpty() && !group.isPrimary) {
        let hashSuffix = groupHashSuffix(group)
        let hashAnchor = "api-group-${group.id}--${hashSuffix}"
        if (primaryAnchors.contains(hashAnchor) || hashAnchors[hashAnchor] > 1) {
            scopeFallbacks.add(group)
        } else {
            group.anchor = hashAnchor
            group.kindPrefix = "api-kind-${group.id.size}-${group.id}--${hashSuffix}-"
            let _ = usedAnchors.add(hashAnchor)
        }
    }
    sort(scopeFallbacks, lessThan: { left, right =>
        if (left.id != right.id) {
            left.id < right.id
        } else {
            utf8BytesLessThan(left.scopeSortBytes, right.scopeSortBytes)
        }
    }, stable: true)
    for (group in scopeFallbacks) {
        let completeScopeHex = scopeHexFallback(group)
        var suffix = completeScopeHex
        var anchor = "api-group-${group.id}--${suffix}"
        while (usedAnchors.contains(anchor)) {
            suffix += completeScopeHex
            anchor = "api-group-${group.id}--${suffix}"
        }
        group.anchor = anchor
        group.kindPrefix = "api-kind-${group.id.size}-${group.id}--${suffix}-"
        let _ = usedAnchors.add(anchor)
    }
}

internal func appendGroupedDeclarationMarkdown(out: RenderTextBuffer,
    group: DeclarationGroup, level: String, locale: String): Unit {
    out.append("<a id=\"${escapeHtml(group.anchor)}\"></a>\n")
    out.append(level + " ")
    appendEscapedMarkdownText(out, declarationGroupDisplayTitle(group, locale))
    out.append("\n\n")
}


private func appendQueryValue(out: StringBuilder, value: String): Unit {
    let digits = "0123456789ABCDEF"
    var index: Int64 = 0
    while (index < value.size) {
        let byte = value[index]
        if ((byte >= b'A' && byte <= b'Z') || (byte >= b'a' && byte <= b'z') ||
            (byte >= b'0' && byte <= b'9') || byte == b'-' || byte == b'.' ||
            byte == b'_' || byte == b'~') {
            out.append(value[index..index + 1])
        } else {
            let high = Int64((byte >> 4) & 0x0F)
            let low = Int64(byte & 0x0F)
            out.append("%")
            out.append(digits[high..high + 1])
            out.append(digits[low..low + 1])
        }
        index++
    }
}

private func tagIndexHref(rootPrefix: String, symbol: SymbolDoc, tagId: String,
    snapshotId: String): String {
    if (snapshotId.isEmpty()) {
        throw IllegalArgumentException("tag links require the captured read snapshot identity")
    }
    let query = StringBuilder()
    appendQueryValue(query, tagId)
    query.append("&moduleId=")
    appendQueryValue(query, symbol.moduleId)
    query.append("&snapshotId=")
    appendQueryValue(query, snapshotId)
    "${rootPrefix}index.html?tag=${query.toString()}"
}

/**
 * Render captured classification values. Grouped rows omit the group badge:
 * their parent heading already supplies it, and tag-free rows need no wrapper.
 */
internal func appendDeclarationClassificationBadges(out: RenderTextBuffer,
    catalog: DeclarationGroupCatalog, snapshotId: String, symbol: SymbolDoc,
    rootPrefix: String, includeGroup!: Bool = true): Unit {
    let classification = catalog.classificationFor(symbol)
    if ((!includeGroup || classification.group.isNone()) && classification.tags.isEmpty()) { return }
    out.append("<div class=\"declaration-classification\">")
    if (includeGroup) {
        match (classification.group) {
            case Some(group) =>
                out.append("<span class=\"declaration-group-badge\" data-cjdoc-declaration-group=\"" +
                    escapeHtml(group.id) + "\">" + escapeHtml(group.title) + "</span>")
            case None => ()
        }
    }
    for (tag in classification.tags) {
        let href = tagIndexHref(rootPrefix, symbol, tag.id, snapshotId)
        out.append("<a class=\"declaration-tag-badge\" data-cjdoc-tag-link data-cjdoc-tag-id=\"" +
            escapeHtml(tag.id) + "\" href=\"" + escapeHtml(href) + "\">" +
            escapeHtml(tag.title) + "</a>")
    }
    out.append("</div>")
}
