protected package cjdoc.source.frontend

import std.unittest.*
import std.unittest.testmacro.*

@Test
class SourceSyntaxRecoveryTest {
    @TestCase
    func bodylessMethodDoesNotConsumePropertyInitializer(): Unit {
        let source = """
            interface Recovery {
                func missing(): Unit
                let callback = { => 41 }
            }
            public func broken(): Unit { let value = ; }
            """
        let recovered = syntaxRecoverySource(source)
        @Expect(recovered.contains("let callback = { => 41 }"), true)
        @Expect(recovered.contains("let value = ;"), false)
    }
}
