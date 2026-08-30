package cfg_owner

@When[os == "Windows"]
public class WindowsOnly {
    @When[missing]
    public func child(): Unit {}
}

@When[missing && docs]
public func unknownThenFalse(): Unit {}

@When[docs && missing]
public func falseThenUnknown(): Unit {}
