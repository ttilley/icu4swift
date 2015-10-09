import ICU4C

public typealias UTextRef = UnsafeMutablePointer<UText>
public typealias UTextConstRef = UnsafePointer<UText>
public typealias UCharRef = UnsafeMutablePointer<UChar>
public typealias UCharConstRef = UnsafePointer<UChar>
public typealias UErrorCodeRef = UnsafeMutablePointer<UErrorCode>
public typealias UParseErrorRef = UnsafeMutablePointer<UParseError>


// WARNING: this depends on a few implementation details
@inline(__always) internal func tupleToArray<T, U>(var tuple: T, _ resultType: U.Type) -> [U] {
    let count = sizeof(T) / sizeof(U)
    return withUnsafePointer(&tuple) { ptr -> [U] in
        let eltPtr = UnsafePointer<U>(ptr)
        return Array(0..<count).map({ eltPtr[$0] })
    }
}

internal func ucharCollectionToString<T:CollectionType where T.Generator.Element == UChar>(collection: T) -> String {
    // by $deity this must be inefficient, but String(utf16CodeUnits:, count:)
    // doesn't exist unless you import Foundation...
    //        var str = ""
    //        str.reserveCapacity(Int(nativeLength))
    //        transcode(UTF16.self, UTF32.self, array.generate(), { str.append(UnicodeScalar($0)) }, stopOnError: false)
    //        return str

    // depending on the internal, hidden, _StringCore is bound to blow up in
    // my face eventually, but until then this is MUCH better than using the
    // transcode statement above.
    let count = collection.underestimateCount()
    var sc = _StringCore.init()
    sc.reserveCapacity(count)
    for codeunit in collection {
        // terminate processing at NULL like C string behavior
        if codeunit != UChar(0) {
            sc.append(codeunit)
        } else { break }
    }
    return String(sc)
}

internal func isUnmanagedValueUniquelyReferenced<T>(unmanaged: Unmanaged<T>) -> Bool {
    // take already-retained (no extra retain added) value with hint to release() at end of function
    var value = unmanaged.takeRetainedValue()
    // determine, from retain count, if the value is uniquely referenced
    let isUniquelyReferenced = isUniquelyReferencedNonObjC(&value)
    // ensure value isn't released/autoreleased yet
    withExtendedLifetime(value) {
        // balance that assumption of being retained with an ACTUAL retain, now that we've made any
        // uniqueness calculations that depend on retain count
        unmanaged.retain()
    }
    return isUniquelyReferenced
    // a release() is added here
}

// there has to be an easier way of doing this...
internal struct StderrOutputStream: OutputStreamType {
    internal mutating func write(string: String) {
        fputs(string, stderr)
    }
}
