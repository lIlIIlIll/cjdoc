package reader_contract_probe

import pocketkit.TextCatalog
import pocketkit.io.openText

func require(condition: Bool, caseId: String): Unit {
    if (!condition) { throw IllegalStateException(caseId) }
    println("PASS " + caseId)
}

func checkCatalog(): Unit {
    let input = ["alpha", "", "alpha"]
    let catalog = TextCatalog(input)
    input[0] = "caller-mutated"
    require(catalog.at(0) == "alpha" && catalog.at(1) == "" && catalog.at(2) == "alpha", "C01-input-copy-order-duplicates-empty")
    require(catalog.tryAt(-1) == None && catalog.tryAt(3) == None && catalog.tryAt(0) == Some("alpha"), "C02-optional-domain")
    var rejected: Int64 = 0
    for (index in [-1, 3]) {
        try { catalog.at(index) } catch (e: IllegalArgumentException) { rejected++ }
    }
    require(rejected == 2 && catalog.size == 3 && catalog.at(0) == "alpha", "C03-at-invalid-no-mutation")
    catalog.add(42)
    require(catalog.at(3) == "42" && catalog.size == 4, "C04-default-decimal-add")
    try { catalog.add(7, radix: 16) } catch (e: IllegalArgumentException) { rejected++ }
    require(rejected == 3 && catalog.size == 4 && catalog.at(3) == "42", "C05-invalid-radix-pre-mutation")
    let more = ["beta", ""]
    catalog.addAll(more)
    more[0] = "caller-mutated"
    require(catalog.size == 6 && catalog.at(4) == "beta" && catalog.at(5) == "", "C06-addAll-copy-and-order")
    let saved = catalog.snapshot()
    saved[0] = "snapshot-mutated"
    require(catalog.at(0) == "alpha", "C07-snapshot-container-independent")
    catalog.clear()
    catalog.add("new")
    require(saved.size == 6 && saved[0] == "snapshot-mutated" && saved[4] == "beta" && catalog.size == 1 && catalog.at(0) == "new", "C08-clear-does-not-change-existing-snapshot")
}

func checkReader(): Unit {
    let empty = openText("")
    require(empty.read() == None && empty.read() == None && !empty.closed, "R01-empty-eof-stable-open")
    empty.close()
    let reader = openText("first\nsecond")
    require(reader.read() == Some("first") && reader.read() == Some("second") && reader.read() == None && reader.read() == None, "R02-ordered-read-stable-eof")
    reader.rewind()
    require(reader.read() == Some("first"), "R03-open-rewind")
    reader.close()
    reader.close()
    require(reader.closed, "R04-idempotent-close")
    var rejected: Int64 = 0
    try { reader.read() } catch (e: IllegalStateException) { rejected++ }
    try { reader.rewind() } catch (e: IllegalStateException) { rejected++ }
    require(rejected == 2 && reader.closed, "R05-closed-read-and-rewind-reject-without-reopening")
}

main(): Int64 {
    checkCatalog()
    checkReader()
    return 0
}
