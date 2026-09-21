import Foundation

/// Sends a prompt somewhere and returns what comes back.
///
/// Deliberately one method and no transport detail. Today the implementation
/// talks to the Anthropic API directly with a key on the device; when this canvas
/// is shared with other people that has to become a call to a server that holds
/// the key instead. Everything above this protocol is unaffected by that change.
public protocol PromptService: Sendable {
    /// Answer a prompt.
    ///
    /// - Parameter prompt: what the user wrote, as plain text.
    /// - Returns: the reply, as plain text.
    func complete(prompt: String) async throws -> String
}
