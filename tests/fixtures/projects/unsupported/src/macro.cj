macro package unsupported_fixture

import std.ast.*

/** Unsupported macro declaration. */
public macro Echo(input: Tokens): Tokens {
    let copied = input
    copied
}
