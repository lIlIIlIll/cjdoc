package frontend_gaps_fixture

/** Public entry point. */
public func outer(): Unit {
    /** A local doc comment must not bind to a later top-level declaration. */
    let local = 1
}

@missing.Generate
public class Generated {}

/** This trailing doc comment is intentionally orphaned. */
