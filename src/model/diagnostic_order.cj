package cjdoc.model

private func comparePublicString(left: String, right: String): Int64 {
    if (left < right) {
        return -1
    }
    if (right < left) {
        return 1
    }
    0
}

private func comparePublicInt(left: Int64, right: Int64): Int64 {
    if (left < right) {
        return -1
    }
    if (right < left) {
        return 1
    }
    0
}

private func comparePublicOptionalString(left: ?String, right: ?String): Int64 {
    if (left.isNone()) {
        return if (right.isNone()) {
            0
        } else {
            -1
        }
    }
    if (right.isNone()) {
        return 1
    }
    comparePublicString(left.getOrThrow(), right.getOrThrow())
}

private func comparePublicSource(left: ?SourceRange, right: ?SourceRange): Int64 {
    if (left.isNone()) {
        return if (right.isNone()) {
            0
        } else {
            -1
        }
    }
    if (right.isNone()) {
        return 1
    }
    let leftValue = left.getOrThrow()
    let rightValue = right.getOrThrow()
    var compared = comparePublicString(leftValue.path, rightValue.path)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.line, rightValue.start.line)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.column, rightValue.start.column)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.start.byteOffset, rightValue.start.byteOffset)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.end.line, rightValue.end.line)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicInt(leftValue.end.column, rightValue.end.column)
    if (compared != 0) {
        return compared
    }
    comparePublicInt(leftValue.end.byteOffset, rightValue.end.byteOffset)
}

protected func comparePublicDiagnostic(left: Diagnostic, right: Diagnostic): Int64 {
    var compared = comparePublicSource(left.source, right.source)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.code, right.code)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.severity, right.severity)
    if (compared != 0) {
        return compared
    }
    compared = comparePublicString(left.message, right.message)
    if (compared != 0) {
        return compared
    }
    comparePublicOptionalString(left.symbolId, right.symbolId)
}
