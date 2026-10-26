macro package macro_sources

import std.ast.*

/**
 * Copy <script>alert(1)</script> input tokens without expanding them.
 * @param input Source declaration tokens.
 * @return The unchanged tokens.
 * @see Echo(Tokens, Tokens)
 */
public macro Echo(input: Tokens): Tokens {
    input
}

/**
 * Copy input tokens with explicit attributes.
 * @param attrs Invocation attributes.
 * @param input Source declaration tokens.
 * @return The unchanged tokens.
 */
public macro Echo(attrs: Tokens, input: Tokens) {
    input
}
