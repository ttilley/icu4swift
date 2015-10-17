extension String.UTF16View.Index {
    @warn_unused_result
    public func closestPositionIn(characters: String, forward: Bool = true) -> String.CharacterView.Index {
        var utf16Index = self
        var charIndex: String.CharacterView.Index?
        charIndex = utf16Index.samePositionIn(characters)

        while charIndex == nil {
            utf16Index = forward ? utf16Index.successor() : utf16Index.predecessor()
            charIndex = utf16Index.samePositionIn(characters)
        }

        return charIndex!
    }
}
