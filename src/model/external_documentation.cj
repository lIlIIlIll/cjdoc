package cjdoc.model

/** A resolved external-index snapshot, usable without the original config/index. */
public class ExternalDocumentationReference {
    public let symbolId: String
    public let name: String
    public let state: String
    public let url: String
    public let reason: String
    public let version: String
    public let index: String
    public let format: String
    public let fingerprint: String
    public init(symbolId: String, name: String, state: String, url: String,
        reason!: String = "", version!: String = "", index!: String = "",
        format!: String = "", fingerprint!: String = "") {
        if (symbolId.isEmpty() || name.isEmpty() || !["available", "unavailable", "ambiguous"].contains(state)) {
            throw IllegalArgumentException("invalid external documentation snapshot")
        }
        if ((state == "available") == url.isEmpty()) {
            throw IllegalArgumentException("external documentation state/URL mismatch")
        }
        this.symbolId = symbolId; this.name = name; this.state = state; this.url = url
        this.reason = reason; this.version = version; this.index = index
        this.format = format; this.fingerprint = fingerprint
    }
}
