protected package cjdoc.render.foundation

// A captured report is a read-only attachment: its presence is recorded, but it
// is never treated as a compatibility verdict or an execution claim. The
// document-root path is derived here so the HTML evidence page and the machine
// manifest cannot name different files.
private let REPORT_ATTACHMENT_KIND_VALUES: Array<String> = ["validation", "api-diff"]

public func isReportAttachmentKind(kind: String): Bool {
    REPORT_ATTACHMENT_KIND_VALUES.contains(kind)
}

public func reportAttachmentPath(kind: String): String {
    if (!isReportAttachmentKind(kind)) {
        throw IllegalArgumentException("unsupported report attachment kind '${kind}'")
    }
    "agent/reports/" + kind + ".json"
}

public class ReportAttachmentView {
    public let kind: String
    public let path: String
    public let snapshotId: String
    public let baselineSnapshotId: ?String
    public let currentSnapshotId: ?String

    public init(kind: String, path: String, snapshotId: String,
        baselineSnapshotId!: ?String = None, currentSnapshotId!: ?String = None) {
        if (path != reportAttachmentPath(kind)) {
            throw IllegalArgumentException("invalid report attachment view")
        }
        this.kind = kind
        this.path = path
        this.snapshotId = snapshotId
        this.baselineSnapshotId = baselineSnapshotId
        this.currentSnapshotId = currentSnapshotId
    }
}
