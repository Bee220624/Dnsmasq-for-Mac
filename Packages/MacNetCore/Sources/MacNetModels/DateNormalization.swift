import Foundation

extension Date {
    /// Drops sub-second precision.
    ///
    /// Every date in this product is persisted and transported as ISO-8601 without fractional
    /// seconds, so a `Date` carrying them cannot survive a round trip. That matters more than
    /// it sounds: `ProfileStore` verifies a save by reading the file back and comparing it to
    /// what it meant to write, and an in-memory value that is *unrepresentable* on disk makes
    /// that check fail every time — reporting a corrupt write on every successful save.
    ///
    /// Normalizing at the point a value is created keeps the two representations equal by
    /// construction, rather than making every comparison site remember to be lenient.
    /// Sub-second precision has no meaning for "when was this profile last edited".
    public var truncatedToSeconds: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
