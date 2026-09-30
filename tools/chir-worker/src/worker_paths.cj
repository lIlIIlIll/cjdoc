package cjdoc_chir_worker

func normalizedHostPath(path: String): String {
    // A backslash is a separator on Windows but ordinary filename data on
    // POSIX. Preserve it in absolute POSIX paths so host containment never
    // aliases `a\\b` with `a/b`; logical relative paths reject it below.
    let normalized = if (path.startsWith("/")) { path } else { path.replace("\\", "/") }
    if (normalized.endsWith("/") && normalized != "/" && !normalized.endsWith(":/")) {
        normalized.trimEnd("/")
    } else {
        normalized
    }
}

func hostPathIsWithin(root: String, candidate: String): Bool {
    let normalizedRoot = normalizedHostPath(root)
    let normalizedCandidate = normalizedHostPath(candidate)
    let prefix = if (normalizedRoot.endsWith("/")) { normalizedRoot } else { normalizedRoot + "/" }
    normalizedCandidate == normalizedRoot || normalizedCandidate.startsWith(prefix)
}

