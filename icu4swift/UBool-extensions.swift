import ICU4C

extension UBool {
    static let True = UBool(1)
    static let False = UBool(0)
}

extension UBool: BooleanType {
    public var boolValue: Bool {
        return self != UBool.False
    }
}

extension UBool: BooleanLiteralConvertible {
    public init(booleanLiteral value: Bool) {
        if value {
            self.init(1)
        } else {
            self.init(0)
        }
    }
}
