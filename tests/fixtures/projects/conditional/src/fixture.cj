package conditional_fixture

@When[os == "Linux"]
func platformName(): String { "linux" }

@When[os != "Linux"]
func platformName(): String { "other" }
