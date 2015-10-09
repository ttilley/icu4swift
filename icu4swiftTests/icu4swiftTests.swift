import ICU4C
@testable import icu4swift
import Quick
import Nimble


func utextChunkString(utext: UTextRef) -> String {
    let buffer = UnsafeBufferPointer<UChar>(start: utext.memory.chunkContents, count: Int(utext.memory.chunkLength))
    return ucharCollectionToString(buffer)
}

class CoreUTextSpec: QuickSpec {
    override func spec() {
        describe("the core Swift.String UText Struct") {
            var testString: String!
            var testStringLength: Int!

            typealias housekeepingClosure = (utext: UTextRef, error: UErrorCodeRef) -> Void

            context("during typical usage") {
                func withHousekeeping(closure: housekeepingClosure) {
                    var error = UErrorCodeRef.alloc(1)
                    defer { error.dealloc(1) }
                    error.initialize(U_ZERO_ERROR)
                    var utext = utext_openString(nil, string: testString, status: error, bufferChunkSize: 16)
                    defer { utext_close(utext) }

                    closure(utext: utext, error: error)
                }
                
                beforeEach {
                    testString = "friendship 👫 love 💑 family 👨‍👩‍👧‍👧 poop 💩"
                    testStringLength = testString.characters.count
                }

                it("successfully creates a UText for a Swift.String") {
                    withHousekeeping({ (utext, error) -> Void in
                        let icuError = ICUErrorCode(error)
                        expect(icuError.isSuccess()).to(equal(true), description: icuError.debugDescription)
                    })
                }

                it("has the correct native length") {
                    withHousekeeping({ (utext, error) -> Void in
                        let length = utext_nativeLength(utext)
                        expect(Int(length)).to(equal(testStringLength))
                    })
                }

                it("can access the Swift.String and use it to optimally fill the buffer in each direction") {
                    withHousekeeping({ (utext, error) -> Void in
                        var success: UBool
                        var buffered: String

                        success = utext.memory.pFuncs.memory.access(utext, Int64(0), UBool.True)
                        expect(success).to(equal(UBool.True))
                        buffered = utextChunkString(utext)
                        expect(buffered).to(equal("friendship 👫 l"))
                        expect(utext.memory.chunkOffset).to(equal(0))

                        // data already in buffer, should just update offset
                        success = utext.memory.pFuncs.memory.access(utext, Int64(12), UBool.True)
                        expect(success).to(equal(UBool.True))
                        buffered = utextChunkString(utext)
                        expect(buffered).to(equal("friendship 👫 l"))
                        expect(utext.memory.chunkOffset).to(equal(13))

                        success = utext.memory.pFuncs.memory.access(utext, Int64(24), UBool.True)
                        expect(success).to(equal(UBool.True))
                        buffered = utextChunkString(utext)
                        expect(buffered).to(equal("ily 👨‍👩‍👧‍👧 "))
                        expect(utext.memory.chunkOffset).to(equal(1))

                        success = utext.memory.pFuncs.memory.access(utext, Int64(testStringLength - 1), UBool.False)
                        expect(success).to(equal(UBool.True))
                        buffered = utextChunkString(utext)
                        expect(buffered).to(equal("👩‍👧‍👧 poop 💩"))
                        expect(utext.memory.chunkOffset).to(equal(14))

                        success = utext.memory.pFuncs.memory.access(utext, Int64(24), UBool.False)
                        expect(success).to(equal(UBool.True))
                        buffered = utextChunkString(utext)
                        expect(buffered).to(equal("👫 love 💑 famil"))
                        expect(utext.memory.chunkOffset).to(equal(15))

                        // data already in buffer, should just update offset
                        success = utext.memory.pFuncs.memory.access(utext, Int64(12), UBool.False)
                        expect(success).to(equal(UBool.True))
                        buffered = utextChunkString(utext)
                        expect(buffered).to(equal("👫 love 💑 famil"))
                        expect(utext.memory.chunkOffset).to(equal(2))
                    })
                }

            }
        }
    }
}

