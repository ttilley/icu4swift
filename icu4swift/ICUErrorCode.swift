import ICU4C

public struct ICUErrorCode: ErrorType {
    // the internal implementation of ErrorType uses these two values to bridge to NSError
    public var _domain: String {return "icu4c"}
    public var _code: Int

    public let reason: String
    public let function: String
    public let file: String
    public let line: Int
    public var extra: String?

    public var code: Int { return _code }
    public var source: String {
        return "Thrown in \(function) (File: \(file) Line: \(line))"
    }

    public init(_ uerror: UnsafePointer<UErrorCode>, extra: String? = nil,
        function: String = __FUNCTION__,
        file: String = __FILE__,
        line: Int = __LINE__) {
            self._code = Int(uerror.memory.rawValue)
            self.reason = String.fromCString(u_errorName(uerror.memory))!
            self.function = function
            self.file = file
            self.line = line
            self.extra = extra
    }

    public init(_ errorCode: UErrorCode, extra: String? = nil,
        function: String = __FUNCTION__,
        file: String = __FILE__,
        line: Int = __LINE__) {
            var status = UErrorCodeRef.alloc(1)
            defer { status.dealloc(1) }
            status.memory = errorCode
            self.init(status, extra: extra, function: function, file: file, line: line)
    }

    public mutating func addExtraInfo(extra: String) {
        self.extra = extra
    }

    public func isWarning() -> Bool { return _code < 0  }
    public func isSuccess() -> Bool { return _code <= 0 }
    public func isFailure() -> Bool { return _code > 0  }
}

extension ICUErrorCode: CustomStringConvertible {
    public var description: String {return "\(reason) \(source)"}
}

extension ICUErrorCode: CustomDebugStringConvertible {
    public var debugDescription: String {
        var str = "" +
            "{UErrorCode:\n" +
            "  domain:   \(_domain)\n" +
            "  code:     \(_code)\n" +
            "  reason:   \(reason)\n" +
            "  warning:  \(isWarning())\n" +
            "  success:  \(isSuccess())\n" +
            "  failure:  \(isFailure())\n" +
            "  function: \(function)\n" +
            "  file:     \(file)\n" +
            "  line:     \(line)\n" +
        "}"
        if let extraInfo = self.extra {
            str.appendContentsOf("\n\(extraInfo)")
        }
        return str
    }
}

