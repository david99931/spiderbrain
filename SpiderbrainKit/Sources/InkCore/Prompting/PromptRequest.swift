import Foundation

/// What to ask the model about.
///
/// Carries the surrounding text alongside the part the user actually pointed at,
/// because a highlighted fragment usually cannot be answered on its own — "the
/// second one" or "this bit" means nothing without the note it came from. Keeping
/// the two separate lets the service say *here is the note, focus on this part*
/// rather than the caller mashing them into one string and hoping.
public struct PromptRequest: Equatable, Sendable {

    /// The whole of what the node says.
    public let context: String

    /// The part the user highlighted, when they highlighted one.
    ///
    /// `nil` means the question is the entire node.
    public let focus: String?

    /// Ask about a node's full contents.
    public init(context: String) {
        self.context = context
        self.focus = nil
    }

    /// Ask about one part of a node, in the light of the rest of it.
    ///
    /// A focus that is blank, or indistinguishable from the whole context, is
    /// treated as no focus at all — there is nothing to narrow down to.
    public init(context: String, focus: String?) {
        self.context = context

        let trimmed = focus?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty,
           trimmed != context.trimmingCharacters(in: .whitespacesAndNewlines) {
            self.focus = trimmed
        } else {
            self.focus = nil
        }
    }

    /// Whether this narrows to part of the node rather than all of it.
    public var isFocused: Bool { focus != nil }
}
