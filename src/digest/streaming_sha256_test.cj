protected package cjdoc.digest

import std.unittest.*
import std.unittest.testmacro.*

@Test
class StreamingSha256Test {
    @TestCase
    func countsOnlyEachChunkPrefixAcrossBlockAndPaddingBoundaries(): Unit {
        let digest = StreamingSha256()
        digest.update([0x61, 0xFF], 1)
        digest.update(Array<Byte>(138, repeat: 0x62), 130)
        digest.update(Array<Byte>(65, repeat: 0x63), 56)
        @Expect(digest.finish(), "e7ce2848ca8be50f7e24c1de64131664a52aff6c40aaca48c4baa536a94eb1ae")
    }
}
