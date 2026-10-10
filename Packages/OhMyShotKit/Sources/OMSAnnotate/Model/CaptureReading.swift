/// What reading a capture's text gives the tools that use it, made by the app, which reads text, for one
/// picture: the redaction tool's suggestions and the lines the highlighter snaps to, in the picture's
/// pixels with a top-left origin. Each is read the first time it is asked for, and what both need of the
/// picture is read once, for whichever asks first. Each throws when the picture could not be read; asked
/// again, it reads again.
nonisolated public struct CaptureReading: Sendable {
    /// What reading finds better covered.
    public var redactionSuggestions: @Sendable () async throws -> [RedactionSuggestion]
    /// Where the lines of text lie, and the words in them.
    public var textLines: @Sendable () async throws -> [TextLine]

    public init(
        redactionSuggestions: @escaping @Sendable () async throws -> [RedactionSuggestion] = { [] },
        textLines: @escaping @Sendable () async throws -> [TextLine] = { [] }
    ) {
        self.redactionSuggestions = redactionSuggestions
        self.textLines = textLines
    }
}
