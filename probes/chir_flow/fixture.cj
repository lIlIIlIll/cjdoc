package chir_probe

public interface Reader {
    func read(): Int64
}

public class Parser<T> <: Reader {
    public let value: T

    public init(value: T) {
        this.value = value
    }

    public func read(): Int64 {
        return 0
    }

    public func parse(text: String): T {
        return value
    }

    public func parse(data: Array<UInt8>): T {
        return value
    }
}

extend Parser<String> {
    public func pretty(): String {
        return value
    }
}

public struct Box<T> {
    public let value: T
    public init(value: T) { this.value = value }
}

public enum Status {
    | Ready
    | Failed(String)
}

@Deprecated[message: "probe annotation"]
private func hidden(): Unit {}

public func transform<T>(
    value: T
): T {
    return value
}

public func 解析(文本: String): String {
    return 文本
}
