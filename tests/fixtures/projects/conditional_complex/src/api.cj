package conditional_complex

@When[(os == "Linux" && arch == "x86_64") || docs]
public func selected(): Bool { true }

@When[!docs && os != "Linux"]
public func omitted(): Bool { false }

@When[missing || docs]
public func provenByOr(): Bool { true }

@When[missing && docs]
public func omittedByAnd(): Bool { false }

