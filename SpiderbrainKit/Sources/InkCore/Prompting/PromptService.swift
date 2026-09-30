import Foundation

/// Sends a prompt somewhere and returns what comes back.
///
/// Deliberately one method and no transport detail. Today the implementation
/// talks to the Anthropic API directly with a key on the device; when this canvas
/// is shared with other people that has to become a call to a server that holds
/// the key instead. Everything above this protocol is unaffected by that change.
public protocol PromptService: Sendable {
    /// Answer a question about a node.
    ///
    /// - Parameter request: the node's text, and optionally the part of it the
    ///   user highlighted.
    /// - Returns: the reply, as plain text.
    func complete(_ request: PromptRequest) async throws -> String
}

public extension PromptService {
    /// Ask about a node's full contents.
    func complete(prompt: String) async throws -> String {
        try await complete(PromptRequest(context: prompt))
    }
}
