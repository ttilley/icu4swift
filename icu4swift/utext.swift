import ICU4C


private typealias CUTextClone                   = @convention(c) (UTextRef, UTextConstRef, UBool, UErrorCodeRef) -> UTextRef
private typealias CUTextNativeLength            = @convention(c) (UTextRef) -> Int64
private typealias CUTextAccess                  = @convention(c) (UTextRef, Int64, UBool) -> UBool
private typealias CUTextExtract                 = @convention(c) (UTextRef, Int64, Int64, UCharRef, Int32, UErrorCodeRef) -> Int32
private typealias CUTextReplace                 = @convention(c) (UTextRef, Int64, Int64, UCharConstRef, Int32, UErrorCodeRef) -> Int32
private typealias CUTextCopy                    = @convention(c) (UTextRef, Int64, Int64, Int64, UBool, UErrorCodeRef) -> Void
private typealias CUTextMapOffsetToNative       = @convention(c) (UTextConstRef) -> Int64
private typealias CUTextMapNativeIndexToUTF16   = @convention(c) (UTextConstRef, Int64) -> Int32
private typealias CUTextClose                   = @convention(c) (UTextRef) -> Void


internal struct UTextProviderOptions : OptionSetType {
    typealias RawValue = Int32
    let rawValue: RawValue
    init(rawValue: RawValue) {self.rawValue = rawValue}

    static let lengthIsExpensive    = UTextProviderOptions(
        rawValue: Int32(1 << UTEXT_PROVIDER_LENGTH_IS_EXPENSIVE))
    static let stableChunks         = UTextProviderOptions(
        rawValue: Int32(1 << UTEXT_PROVIDER_STABLE_CHUNKS))
    static let writable             = UTextProviderOptions(
        rawValue: Int32(1 << UTEXT_PROVIDER_WRITABLE))
    static let hasMetaData          = UTextProviderOptions(
        rawValue: Int32(1 << UTEXT_PROVIDER_HAS_META_DATA))
    static let ownsText             = UTextProviderOptions(
        rawValue: Int32(1 << UTEXT_PROVIDER_OWNS_TEXT))
}


private class StringUTextContext {
    typealias StringIndexTuple =
        (character: String.CharacterView.Index, utf16: String.UTF16View.Index)

    var string: String

    init(_ string: String) {
        self.string = string
    }

    func loadChunkFromNativeIndex(offset: Int = 0, forward: Bool = true, utext: UTextRef) throws {
        let bufferChunkSize = Int(utext.memory.extraSize)
        var array = ContiguousArray<UChar>(count: bufferChunkSize, repeatedValue: UChar(0))
        let initialIndices = try indicesFromCharacterOffset(offset)

        var utf16StartIndex: String.UTF16View.Index
        var utf16EndIndex: String.UTF16View.Index
        var charStartIndex: String.CharacterView.Index?
        var charEndIndex: String.CharacterView.Index?
        var chunkOffset: Int32 = 0
        var chunkSize: Int = 0

        let string = self.string

        if forward {
            utf16StartIndex = initialIndices.utf16
            charStartIndex = initialIndices.character
            utf16EndIndex = utf16StartIndex.advancedBy((bufferChunkSize - 1), limit: string.utf16.endIndex)

            charEndIndex = utf16EndIndex.samePositionIn(string)
            while charEndIndex == nil {
                utf16EndIndex = utf16EndIndex.predecessor()
                charEndIndex = utf16EndIndex.samePositionIn(string)
            }

            chunkSize = Int(utf16StartIndex.distanceTo(utf16EndIndex))

            if chunkSize < bufferChunkSize {
                let spareRoom = bufferChunkSize - chunkSize
                let originalStartIndex = utf16StartIndex
                utf16StartIndex = utf16StartIndex.advancedBy(-spareRoom, limit: string.utf16.startIndex)

                charStartIndex = utf16StartIndex.samePositionIn(string)
                while charStartIndex == nil {
                    utf16StartIndex = utf16StartIndex.successor()
                    charStartIndex = utf16StartIndex.samePositionIn(string)
                }

                chunkSize = Int(utf16StartIndex.distanceTo(utf16EndIndex))
                chunkOffset = Int32(Int(utf16StartIndex.distanceTo(originalStartIndex)))
            }
        } else {
            utf16EndIndex = initialIndices.utf16
            charEndIndex = initialIndices.character
            utf16StartIndex = utf16EndIndex.advancedBy(-(bufferChunkSize - 1), limit: string.utf16.startIndex)

            charStartIndex = utf16StartIndex.samePositionIn(string)
            while charStartIndex == nil {
                utf16StartIndex = utf16StartIndex.successor()
                charStartIndex = utf16StartIndex.samePositionIn(string)
            }

            chunkSize = Int(utf16StartIndex.distanceTo(utf16EndIndex))

            if chunkSize < bufferChunkSize {
                let spareRoom = bufferChunkSize - chunkSize
                let originalEndIndex = utf16EndIndex
                utf16EndIndex = utf16EndIndex.advancedBy(spareRoom, limit: string.utf16.endIndex)

                charEndIndex = utf16EndIndex.samePositionIn(string)
                while charEndIndex == nil {
                    utf16EndIndex = utf16EndIndex.predecessor()
                    charEndIndex = utf16EndIndex.samePositionIn(string)
                }

                chunkSize = Int(utf16StartIndex.distanceTo(utf16EndIndex))
                chunkOffset = Int32(Int(utf16StartIndex.distanceTo(originalEndIndex)))
            }
        }

        array.replaceRange(Range<Int>(start: 0, end: chunkSize), with: string.utf16[Range(start: utf16StartIndex, end: utf16EndIndex.successor())])

        let chunkContents = unsafeBitCast(utext.memory.chunkContents, UCharRef.self)
        chunkContents.initializeFrom(array)
        utext.memory.chunkLength = Int32(chunkSize)
        utext.memory.chunkNativeStart = Int64(string.characters.startIndex.distanceTo(charStartIndex!))
        utext.memory.chunkNativeLimit = Int64(string.characters.startIndex.distanceTo(charEndIndex!) + 1)
        utext.memory.chunkOffset = chunkOffset
        utext.memory.nativeIndexingLimit = Int32(chunkSize)
    }

    func characterIndexFromOffset(offset: Int) throws -> String.CharacterView.Index {
        guard offset >= 0 && offset < self.string.characters.count else {
            throw ICUErrorCode(U_INDEX_OUTOFBOUNDS_ERROR)
        }

        let first = self.string.characters.indices.startIndex
        return first.advancedBy(offset)
    }

    func indicesFromCharacterOffset(offset: Int) throws -> StringIndexTuple {
        let characterIndex = try characterIndexFromOffset(offset)
        let utf16Index = characterIndex.samePositionIn(self.string.utf16)
        
        return (character: characterIndex, utf16: utf16Index)
    }
}


@inline(__always) private func uniqueStringContextWrapper(inout ptr: UnsafePointer<Void>) -> Unmanaged<StringUTextContext> {
    let srcWrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(ptr))
    if isUnmanagedValueUniquelyReferenced(srcWrapper) { return srcWrapper }

    let srcContext = srcWrapper.takeRetainedValue()
    let wrapper = Unmanaged<StringUTextContext>.passRetained(StringUTextContext(srcContext.string))
    ptr = UnsafePointer(wrapper.toOpaque())

    return wrapper
}


private struct CUTextFunctionWrapper {
    static let providerOptions: UTextProviderOptions = [.writable, .ownsText, .stableChunks]

    /**
    * Function type declaration for UText.clone().
    *
    *  clone a UText.  Much like opening a UText where the source text is itself
    *  another UText.
    *
    *  A deep clone will copy both the UText data structures and the underlying text.
    *  The original and cloned UText will operate completely independently; modifications
    *  made to the text in one will not effect the other.  Text providers are not
    *  required to support deep clones.  The user of clone() must check the status return
    *  and be prepared to handle failures.
    *
    *  A shallow clone replicates only the UText data structures; it does not make
    *  a copy of the underlying text.  Shallow clones can be used as an efficient way to
    *  have multiple iterators active in a single text string that is not being
    *  modified.
    *
    *  A shallow clone operation must not fail except for truly exceptional conditions such
    *  as memory allocation failures.
    *
    *  A UText and its clone may be safely concurrently accessed by separate threads.
    *  This is true for both shallow and deep clones.
    *  It is the responsibility of the Text Provider to ensure that this thread safety
    *  constraint is met.

    *
    *  @param dest   A UText struct to be filled in with the result of the clone operation,
    *                or NULL if the clone function should heap-allocate a new UText struct.
    *  @param src    The UText to be cloned.
    *  @param deep   TRUE to request a deep clone, FALSE for a shallow clone.
    *  @param status Errors are returned here.  For deep clones, U_UNSUPPORTED_ERROR
    *                should be returned if the text provider is unable to clone the
    *                original text.
    *  @return       The newly created clone, or NULL if the clone operation failed.
    *
    * @stable ICU 3.4
    */
    static let clone: CUTextClone = { (dest: UTextRef, src: UTextConstRef, deep: UBool, status: UErrorCodeRef) -> UTextRef in
        guard status.memory.rawValue <= Int32(0) else { return nil }

        var ut = utext_setup(dest, src.memory.extraSize, status)
        guard status.memory.rawValue <= Int32(0) else { return nil }

        ut.memory.pFuncs = src.memory.pFuncs

        // we've set this UText provider to have the stable chunk optimization; copy any state
        ut.memory.pExtra.initializeFrom(src.memory.pExtra, count: Int(src.memory.extraSize))
        ut.memory.chunkLength = src.memory.chunkLength
        ut.memory.chunkNativeStart = src.memory.chunkNativeStart
        ut.memory.chunkNativeLimit = src.memory.chunkNativeLimit
        ut.memory.nativeIndexingLimit = src.memory.nativeIndexingLimit

        ut.memory.chunkContents = unsafeBitCast(ut.memory.pExtra, UCharConstRef.self)

        // as long as we're consistent about unique reference checks, we shouldn't have to care much
        // about deep copies. we can always defer the copy until the string is mutated, and mark
        // shallow copies as being immutable. either way we need to retain the string context.
        let wrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(src.memory.context))
        wrapper.retain()
        ut.memory.context = UnsafePointer(wrapper.toOpaque())

        if deep {
            ut.memory.providerProperties = CUTextFunctionWrapper.providerOptions.rawValue
        } else {
            var pp = CUTextFunctionWrapper.providerOptions
            pp.remove(.writable)
            ut.memory.providerProperties = pp.rawValue
        }

        status.memory = U_ZERO_ERROR

        return ut
    }

    /**
    * Function type declaration for UText.nativeLength().
    *
    * @param ut the UText to get the length of.
    * @return the length, in the native units of the original text string.
    * @see UText
    * @stable ICU 3.4
    */
    static let nativeLength: CUTextNativeLength = { (ut: UTextRef) -> Int64 in
        let wrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(ut.memory.context))
        let context = wrapper.takeUnretainedValue()

        return Int64(context.string.characters.count)
    }

    /**
    * Function type declaration for UText.access().  Get the description of the text chunk
    *  containing the text at a requested native index.  The UText's iteration
    *  position will be left at the requested index.  If the index is out
    *  of bounds, the iteration position will be left at the start or end
    *  of the string, as appropriate.
    *
    *  Chunks must begin and end on code point boundaries.  A single code point
    *  comprised of multiple storage units must never span a chunk boundary.
    *
    *
    * @param ut          the UText being accessed.
    * @param nativeIndex Requested index of the text to be accessed.
    * @param forward     If TRUE, then the returned chunk must contain text
    *                    starting from the index, so that start<=index<limit.
    *                    If FALSE, then the returned chunk must contain text
    *                    before the index, so that start<index<=limit.
    * @return            True if the requested index could be accessed.  The chunk
    *                    will contain the requested text.
    *                    False value if a chunk cannot be accessed
    *                    (the requested index is out of bounds).
    *
    * @see UText
    * @stable ICU 3.4
    */
    static let access: CUTextAccess = { (ut: UTextRef, nativeIndex: Int64, forward: UBool) -> UBool in
        let wrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(ut.memory.context))
        let context = wrapper.takeUnretainedValue()

        let length = context.string.characters.count

        // ensure that the requested index is valid
        guard nativeIndex >= 0 && nativeIndex <= Int64(length) else {return UBool.False}

        // _something_ is in the buffer...
        if ut.memory.chunkLength > 0 {
            // update chunk offset and return true if the text is already in the buffer
            if forward.boolValue {
                if nativeIndex >= ut.memory.chunkNativeStart && nativeIndex < ut.memory.chunkNativeLimit {
                    ut.memory.chunkOffset = ut.memory.pFuncs.memory.mapNativeIndexToUTF16(ut, nativeIndex)
                    return UBool.True
                }
            } else {
                if nativeIndex > ut.memory.chunkNativeStart && nativeIndex <= ut.memory.chunkNativeLimit {
                    ut.memory.chunkOffset = ut.memory.pFuncs.memory.mapNativeIndexToUTF16(ut, nativeIndex)
                    return UBool.True
                }
            }
        }

        // requested index isn't contained within the buffer. attempt to fill it
        do {
            try context.loadChunkFromNativeIndex(Int(nativeIndex), forward: forward.boolValue, utext: ut)
        } catch let error {
            var err = StderrOutputStream()
            debugPrint(error, toStream: &err)
            return UBool.False
        }

        return UBool.True
    }

    /**
    * Function type declaration for UText.extract().
    *
    * Extract text from a UText into a UChar buffer.  The range of text to be extracted
    * is specified in the native indices of the UText provider.  These may not necessarily
    * be UTF-16 indices.
    * <p>
    * The size (number of 16 bit UChars) in the data to be extracted is returned.  The
    * full amount is returned, even when the specified buffer size is smaller.
    * <p>
    * The extracted string will (if you are a user) / must (if you are a text provider)
    * be NUL-terminated if there is sufficient space in the destination buffer.
    *
    * @param  ut            the UText from which to extract data.
    * @param  nativeStart   the native index of the first characer to extract.
    * @param  nativeLimit   the native string index of the position following the last
    *                       character to extract.
    * @param  dest          the UChar (UTF-16) buffer into which the extracted text is placed
    * @param  destCapacity  The size, in UChars, of the destination buffer.  May be zero
    *                       for precomputing the required size.
    * @param  status        receives any error status.
    *                       If U_BUFFER_OVERFLOW_ERROR: Returns number of UChars for
    *                       preflighting.
    * @return Number of UChars in the data.  Does not include a trailing NUL.
    *
    * @stable ICU 3.4
    */
    static let extract: CUTextExtract = { (ut: UTextRef, nativeStart: Int64, nativeLimit: Int64, dest: UCharRef, destCapacity: Int32, status: UErrorCodeRef) -> Int32 in
        guard status.memory.rawValue <= Int32(0) else { return Int32(0) }

        let wrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(ut.memory.context))
        let context = wrapper.takeUnretainedValue()

        let string = context.string
        let trueCharacterStartIndex = string.characters.startIndex
        let trueCharacterEndIndex = string.characters.endIndex

        let startIndex = trueCharacterStartIndex.advancedBy(Int(nativeStart), limit: trueCharacterEndIndex)
        // due to the API, this is already past the last character expected to be returned, so we don't
        // need to use .successor here
        let endIndex = trueCharacterStartIndex.advancedBy(Int(nativeLimit), limit: trueCharacterEndIndex)

        var slice = string[startIndex..<endIndex].utf16
        let requiredSize = Int32(slice.count)

        // we only want to determine what space would be required
        if dest == nil || destCapacity == Int32(0) {
            return requiredSize
        }

        if requiredSize > destCapacity {
            status.memory.rawValue = U_BUFFER_OVERFLOW_ERROR.rawValue
            return requiredSize
        }

        // this is ugly as sin. so much unnecessary work.
        // TODO: refactor
        var uchara = ContiguousArray<UChar>(count: Int(destCapacity), repeatedValue: UChar(0))
        uchara.replaceRange(Range<Int>(start: 0, end: slice.count), with: slice)
        dest.initializeFrom(uchara)

        status.memory = U_ZERO_ERROR

        return requiredSize
    }

    /**
    * Function type declaration for UText.replace().
    *
    * Replace a range of the original text with a replacement text.
    *
    * Leaves the current iteration position at the position following the
    *  newly inserted replacement text.
    *
    * This function need only be implemented on UText types that support writing.
    *
    * When using this function, there should be only a single UText opened onto the
    * underlying native text string.  The function is responsible for updating the
    * text chunk within the UText to reflect the updated iteration position,
    * taking into account any changes to the underlying string's structure caused
    * by the replace operation.
    *
    * @param ut               the UText representing the text to be operated on.
    * @param nativeStart      the index of the start of the region to be replaced
    * @param nativeLimit      the index of the character following the region to be replaced.
    * @param replacementText  pointer to the replacement text
    * @param replacmentLength length of the replacement text in UChars, or -1 if the text is NUL terminated.
    * @param status           receives any error status.  Possible errors include
    *                         U_NO_WRITE_PERMISSION
    *
    * @return The signed number of (native) storage units by which
    *         the length of the text expanded or contracted.
    *
    * @stable ICU 3.4
    */
    static let replace: CUTextReplace = { (ut: UTextRef, nativeStart: Int64, nativeLimit: Int64, replacementText: UCharConstRef, replacementLength: Int32, status: UErrorCodeRef) -> Int32 in
        guard status.memory.rawValue <= Int32(0) else { return Int32(0) }

        let wrapper = uniqueStringContextWrapper(&ut.memory.context)
        let context = wrapper.takeUnretainedValue()
        var string = context.string

        let trueReplacementLength = replacementLength < 0 ? u_strlen(replacementText) : replacementLength
        let replacementBuffer = UnsafeBufferPointer<UChar>(start: replacementText, count: Int(trueReplacementLength))

        let startIndex = string.startIndex.advancedBy(Int(nativeStart))
        let endIndex = string.startIndex.advancedBy(Int(nativeLimit))

        let originalStringLength = string.characters.count

        string.replaceRange(Range(start: startIndex, end: endIndex), with: ucharCollectionToString(replacementBuffer))

        let newStringLength = string.characters.count

        context.string = string

        ut.memory.chunkLength = 0
        ut.memory.pFuncs.memory.access(ut, nativeLimit, UBool.True)

        status.memory = U_ZERO_ERROR

        return Int32(newStringLength - originalStringLength)
    }

    /**
    * Function type declaration for UText.copy().
    *
    * Copy or move a substring from one position to another within the text,
    * while retaining any metadata associated with the text.
    * This function is used to duplicate or reorder substrings.
    * The destination index must not overlap the source range.
    *
    * The text to be copied or moved is inserted at destIndex;
    * it does not replace or overwrite any existing text.
    *
    * This function need only be implemented for UText types that support writing.
    *
    * When using this function, there should be only a single UText opened onto the
    * underlying native text string.  The function is responsible for updating the
    * text chunk within the UText to reflect the updated iteration position,
    * taking into account any changes to the underlying string's structure caused
    * by the replace operation.
    *
    * @param ut           The UText representing the text to be operated on.
    * @param nativeStart  The index of the start of the region to be copied or moved
    * @param nativeLimit  The index of the character following the region to be replaced.
    * @param nativeDest   The destination index to which the source substring is copied or moved.
    * @param move         If TRUE, then the substring is moved, not copied/duplicated.
    * @param status       receives any error status.  Possible errors include U_NO_WRITE_PERMISSION
    *
    * @stable ICU 3.4
    */
    static let copy: CUTextCopy = { (ut: UTextRef, nativeStart: Int64, var nativeLimit: Int64, nativeDest: Int64, move: UBool, status: UErrorCodeRef) -> Void in
        guard status.memory.rawValue <= Int32(0) else { return }

        let wrapper = uniqueStringContextWrapper(&ut.memory.context)
        let context = wrapper.takeUnretainedValue()
        var string = context.string

        let length = string.characters.count
        if (nativeLimit > Int64(length)) {
            nativeLimit = Int64(length)
        }

        guard nativeDest < nativeStart || nativeDest > nativeLimit else {
            status.memory = U_INDEX_OUTOFBOUNDS_ERROR
            return
        }

        let startIndex = string.startIndex.advancedBy(Int(nativeStart))
        let endIndex = string.startIndex.advancedBy(Int(nativeLimit))
        let range = Range(start: startIndex, end: endIndex.successor())

        let sliceView = string.characters[range]

        string.insertContentsOf(sliceView, at: string.startIndex.advancedBy(Int(nativeDest)))
        if move { string.removeRange(range) }

        context.string = string
        status.memory = U_ZERO_ERROR
    }

    /**
    * Function type declaration for UText.mapOffsetToNative().
    * Map from the current UChar offset within the current text chunk to
    *  the corresponding native index in the original source text.
    *
    * This is required only for text providers that do not use native UTF-16 indexes.
    *
    * @param ut     the UText.
    * @return Absolute (native) index corresponding to chunkOffset in the current chunk.
    *         The returned native index should always be to a code point boundary.
    *
    * @stable ICU 3.4
    */
    static let mapOffsetToNative: CUTextMapOffsetToNative = { (ut: UTextConstRef) -> Int64 in
        let wrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(ut.memory.context))
        let context = wrapper.takeUnretainedValue()

        let chunkStartIndices = try! context.indicesFromCharacterOffset(Int(ut.memory.chunkNativeStart))
        let chunkOffset = ut.memory.chunkOffset
        var utf16index = chunkStartIndices.utf16.advancedBy(Int(chunkOffset))

        if UTF16.isTrailSurrogate(context.string.utf16[utf16index]) {
            utf16index = utf16index.predecessor()
        }

        let characterIndex = utf16index.samePositionIn(context.string)!
        let characterOffset = characterIndex.distanceTo(context.string.characters.startIndex)

        return Int64(abs(characterOffset))
    }

    /**
    * Function type declaration for UText.mapIndexToUTF16().
    * Map from a native index to a UChar offset within a text chunk.
    * Behavior is undefined if the native index does not fall within the
    *   current chunk.
    *
    * This function is required only for text providers that do not use native UTF-16 indexes.
    *
    * @param ut          The UText containing the text chunk.
    * @param nativeIndex Absolute (native) text index, chunk->start<=index<=chunk->limit.
    * @return            Chunk-relative UTF-16 offset corresponding to the specified native
    *                    index.
    *
    * @stable ICU 3.4
    */
    static let mapNativeIndexToUTF16: CUTextMapNativeIndexToUTF16 = { (ut: UTextConstRef, nativeIndex: Int64) -> Int32 in
        let wrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(ut.memory.context))
        let context = wrapper.takeUnretainedValue()

        let chunkStartIndices = try! context.indicesFromCharacterOffset(Int(ut.memory.chunkNativeStart))
        let targetIndices = try! context.indicesFromCharacterOffset(Int(nativeIndex))
        let offset = chunkStartIndices.utf16.distanceTo(targetIndices.utf16)

        return Int32(offset)
    }

    /**
    * Function type declaration for UText.utextClose().
    *
    * A Text Provider close function is only required for provider types that make
    *  allocations in their open function (or other functions) that must be
    *  cleaned when the UText is closed.
    *
    * The allocation of the UText struct itself and any "extra" storage
    * associated with the UText is handled by the common UText implementation
    * and does not require provider specific cleanup in a close function.
    *
    * Most UText provider implementations do not need to implement this function.
    *
    * @param ut A UText object to be closed.
    *
    * @stable ICU 3.4
    */
    static let close: CUTextClose = { (ut: UTextRef) -> Void in
        // even "shallow" copies retain their string source just in case
        let wrapper = Unmanaged<StringUTextContext>.fromOpaque(COpaquePointer(ut.memory.context))
        wrapper.release()
    }


    static let _providerFunctions = UnsafeMutablePointer<UTextFuncs>.alloc(1)
    // swift strideof() behaves like C sizeof(), but swift sizeof() does not (which isn't confusing at all)
    static let _tableSize = Int32(strideof(UTextFuncs))

    static func providerFunctionsPointer() -> UnsafePointer<UTextFuncs> {
        if CUTextFunctionWrapper._providerFunctions.memory.tableSize != CUTextFunctionWrapper._tableSize {
            CUTextFunctionWrapper._providerFunctions.memory = UTextFuncs.init(
                tableSize: CUTextFunctionWrapper._tableSize,
                reserved1: 0, reserved2: 0, reserved3: 0,
                clone:                  CUTextFunctionWrapper.clone,
                nativeLength:           CUTextFunctionWrapper.nativeLength,
                access:                 CUTextFunctionWrapper.access,
                extract:                CUTextFunctionWrapper.extract,
                replace:                CUTextFunctionWrapper.replace,
                copy:                   CUTextFunctionWrapper.copy,
                mapOffsetToNative:      CUTextFunctionWrapper.mapOffsetToNative,
                mapNativeIndexToUTF16:  CUTextFunctionWrapper.mapNativeIndexToUTF16,
                close:                  CUTextFunctionWrapper.close,
                spare1:                 CUTextFunctionWrapper.close,
                spare2:                 CUTextFunctionWrapper.close,
                spare3:                 CUTextFunctionWrapper.close)
        }

        return unsafeBitCast(CUTextFunctionWrapper._providerFunctions, UnsafePointer<UTextFuncs>.self)
    }
}



//------------------------------------------------------------------------------
//
//     UText implementation for swift strings
//
//         Use of UText data members:
//              context         pointer to Unmanaged<StringUTextContext> containing string and helpers
//              utext.pExtra    pointer to the current UChar buffer
//
//------------------------------------------------------------------------------
public func utext_openString(ut: UTextRef, string: String, status: UErrorCodeRef, var bufferChunkSize: Int = 32) -> UTextRef {
    guard status.memory.rawValue <= Int32(0) else { return nil }

    if bufferChunkSize < 16 { bufferChunkSize = 16 }

    let utext = utext_setup(ut, Int32(bufferChunkSize), status)
    guard status.memory.rawValue <= Int32(0) else { return nil }

    let context = StringUTextContext(string)
    let wrapper = Unmanaged<StringUTextContext>.passRetained(context)

    utext.memory.pFuncs = CUTextFunctionWrapper.providerFunctionsPointer()

    utext.memory.providerProperties = CUTextFunctionWrapper.providerOptions.rawValue
    utext.memory.context = UnsafePointer(wrapper.toOpaque())
    utext.memory.chunkContents = unsafeBitCast(utext.memory.pExtra, UCharConstRef.self)

    // if the text is small enough to fit into the buffer, then we might as well preload it
    let utf16count = string.utf16.count
    // compare for less than bufferChunkSize to account for expected null terminator
    if utf16count != 0 && utf16count <= bufferChunkSize {
        try! context.loadChunkFromNativeIndex(0, forward: true, utext: utext)
    }

    return utext
}

