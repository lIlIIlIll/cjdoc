package cjdoc

import std.time.*
import std.unittest.*
import std.unittest.testmacro.*

// The supervised subprocess contract: `timeoutMilliseconds` must bound the WHOLE
// call, not just the child's own lifetime. The regression this guards is a
// descendant that escapes the supervisor's process group (issue #116): it survives
// the group kill, keeps the inherited stdout pipe open, and made the trailing
// stream reads wait for as long as that descendant lived -- a 2 s timeout measured
// 45 s, and in CI the same shape consumed a 110-minute job.
@When[os != "Windows"]
@Test
class BoundedProcessTimeoutTest {
    @TestCase
    func escapingDescendantCannotOutliveTheTimeout(): Unit {
        // The descendant sleeps far longer than the timeout, detaches with `setsid`
        // so the supervisor's process-group kill cannot reach it, AND keeps this
        // call's inherited stdout open. Not redirecting the detached child's output
        // is the whole point: an inherited descriptor is what makes EOF unreachable,
        // so a version that redirects to /dev/null would pass even without the fix.
        let descendantSeconds: Int64 = 45
        let timeoutMs: Int64 = 2000
        let started = DateTime.now()
        let (_, _, _) = executeWithBoundedOutput("/bin/bash",
            ["-c", "setsid sh -c 'sleep ${descendantSeconds}' & exit 0"],
            timeoutMilliseconds: timeoutMs)
        let elapsedMs = (DateTime.now() - started).toMilliseconds()
        // Bound generously (well below the descendant's lifetime) so a slow machine
        // cannot make this flaky, while an unbounded read still fails it clearly.
        @Expect(elapsedMs < descendantSeconds * 1000 / 2, true)
        println("bounded call returned in ${elapsedMs} ms (descendant lived ${descendantSeconds} s)")
    }
}
