package cjdoc.render

import cjdoc.model.*
import std.unittest.*
import std.unittest.testmacro.*

@Test
class RenderTextBufferBoundaryTest {
    @TestCase
    func largeTextPreservesUtf8NulAndAppendAfterObservation(): Unit {
        let out = RenderTextBuffer(limit: 2193140)
        let piece = String(Array<Rune>(17001, repeat: r'a'))
        for (_ in 0..129) { out.append(piece) }
        out.append(r'汉')
        out.append(String.fromUtf8([0x00]))
        out.append("tail")
        let before = out.toString()
        @Expect(before.size, 2193137)
        @Expect(contractFingerprint(before),
            "0475b5f444aa4806e1187a937f3319ce996cc3bc1c5dec650e5a828761ad033a")
        out.append(r'字')
        @Expect(out.size, 2193140)
        @Expect(contractFingerprint(out.toString()),
            "588b383fab142cbe96c03770a9a5260c9c85243d0cb372d69a2f4623ae50d2b7")
        @ExpectThrows[RenderResourceLimitException](out.append("!"))
        @Expect(out.size, 2193140)
    }

    @TestCase
    func wholeTextFragmentsCannotResetTheGlobalUtf8Budget(): Unit {
        let text = String.fromUtf8(Array<Byte>(2 * 1024 * 1024, repeat: 0x61))
        let out = RenderTextBuffer(limit: text.size + 3)
        out.append(text)
        out.append(r'汉')
        @ExpectThrows[RenderResourceLimitException](out.append(r'字'))
        @Expect(out.size, 2097155)
        @Expect(contractFingerprint(out.toString()),
            "acf92ae1dc49bfe3d3cd93e4b8d161dbe0f98fb7f3584640f925fac6c261d250")
    }
}
