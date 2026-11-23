protected package cjdoc.output

import cjdoc.render.foundation.RenderArtifactStore

// The draft opens only after generation. The lock already covers generation,
// and a rejected rebuild discards the draft without touching the publication.
protected class OutputPublication {
    private let lock: OutputLockHandle
    private var spool: ?OutputArtifactSpool = None

    internal init(lock: OutputLockHandle) { this.lock = lock }

    protected func begin(): RenderArtifactStore {
        let draft = OutputArtifactSpool(lock)
        spool = Some(draft)
        draft
    }

    protected func restart(): Unit { spool.getOrThrow().reset() }

    internal func finish(output: String, publish: Bool, forceOwned: Bool): Unit {
        if (let Some(draft) <- spool) {
            if (publish) { writeOwnedSpoolWithLockHeld(output, draft, lock, forceOwned: forceOwned) }
            else { draft.discard() }
        }
    }
}

protected func withOutputPublication(output: String, forceOwned: Bool,
    action: (OutputPublication) -> Int64, writeOnFailure!: Bool = true,
    afterRelease!: () -> Unit = { => }): Int64 {
    let result = withOutputLockResultGuard(output, { lock =>
        let publication = OutputPublication(lock)
        let exitCode = action(publication)
        publication.finish(output, writeOnFailure || exitCode == 0, forceOwned)
        exitCode
    })
    afterRelease()
    result
}
