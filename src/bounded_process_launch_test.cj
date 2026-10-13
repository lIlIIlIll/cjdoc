package cjdoc

import std.collection.*
import std.unittest.*
import std.unittest.testmacro.*

@When[os != "Windows"]
@Test
class BoundedProcessLaunchTest {
    @TestCase
    func parallelRedirectedLaunchesKeepTheirOwnStreams(): Unit {
        for (round in 0..10) {
            let results = ArrayList<Future<String>>()
            for (index in 0..4) {
                let value = "worker-${round}-${index}"
                results.add(spawn {
                    let (code, output, error) = executeWithBoundedOutput("/bin/bash",
                        ["-c", "printf '%s' \"$1\"; printf '%s' \"$2\" >&2",
                            "stream-fixture", value, "error-" + value], timeoutMilliseconds: 5000)
                    if (code == 0 && String.fromUtf8(output) == value &&
                        String.fromUtf8(error) == "error-" + value) { "" }
                    else { "exit ${code}; stdout: ${String.fromUtf8(output)}; stderr: ${String.fromUtf8(error)}" }
                })
            }
            for (result in results) { @Expect(result.get(), "") }
        }
    }
}
