import Foundation
import InkCore

/// Talks to the Anthropic Messages API over HTTP.
///
/// Swift has no official Anthropic SDK, so this is a hand-rolled request against
/// `POST /v1/messages`. The shape is small and stable: three headers, a JSON body,
/// and a response whose `content` is an array of typed blocks.
public struct AnthropicPromptService: PromptService {

    public enum Failure: LocalizedError, Equatable {
        /// No API key was configured.
        case missingAPIKey
        /// The API rejected the request. Carries the status and any message.
        case requestFailed(status: Int, message: String?)
        /// The request never reached the API.
        case couldNotReachAPI
        /// The response arrived but held no text.
        case noTextInResponse

        /// Plain sentences rather than enum dumps: these surface directly in the
        /// UI, and the common failures here are ordinary and worth naming — a
        /// rate limit and an overloaded server both mean "wait and retry".
        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No API key — check Secrets.plist is in the app bundle."
            case .couldNotReachAPI:
                return "Couldn't reach the API. Check your connection."
            case .noTextInResponse:
                return "The model replied with nothing."
            case .requestFailed(let status, let message):
                switch status {
                case 401:
                    return "API key was rejected."
                case 429:
                    return "Rate limited — wait a moment and try again."
                case 529:
                    return "The API is overloaded — try again shortly."
                case 500...599:
                    return "The API had a problem (\(status)) — try again shortly."
                default:
                    return message.map { "Request failed (\(status)): \($0)" }
                        ?? "Request failed (\(status))."
                }
            }
        }
    }

    private let apiKey: String
    private let model: String
    private let maxTokens: Int
    private let systemPrompt: String
    private let session: URLSession

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"

    /// Keeps replies short enough to live inside a hand-drawn node. Without this,
    /// a scrap of handwriting tends to come back as several paragraphs.
    public static let defaultSystemPrompt = """
        You are helping someone think on a handwritten canvas. They write short \
        notes and ask you to expand on them. Reply in plain prose, at most a few \
        sentences. No markdown, no lists, no preamble — just the answer.
        """

    public init(
        apiKey: String,
        model: String = "claude-haiku-4-5",
        maxTokens: Int = 1024,
        systemPrompt: String = AnthropicPromptService.defaultSystemPrompt,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.systemPrompt = systemPrompt
        self.session = session
    }

    public func complete(_ promptRequest: PromptRequest) async throws -> String {
        guard !apiKey.isEmpty else { throw Failure.missingAPIKey }

        let prompt = Self.userMessage(for: promptRequest)

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(
                model: model,
                maxTokens: maxTokens,
                system: systemPrompt,
                messages: [.init(role: "user", content: prompt)]
            )
        )

        // `URLSession` throws `CancellationError` if the enclosing task is already
        // cancelled, so a cancelled prompt genuinely stops rather than running on
        // and having its result discarded.
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Failure.couldNotReachAPI
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw Failure.requestFailed(status: status, message: Self.errorMessage(in: data))
        }

        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)

        // `content` is an array of blocks; only the text ones matter here.
        let text = decoded.content
            .filter { $0.type == "text" }
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { throw Failure.noTextInResponse }
        return text
    }

    /// Turn a request into the text the model sees.
    ///
    /// A focused request names the note first and the highlighted part second, so
    /// the model has somewhere to stand before being told where to look. Without
    /// the surrounding note, a fragment like "the second one" is unanswerable.
    static func userMessage(for request: PromptRequest) -> String {
        guard let focus = request.focus else { return request.context }

        return """
            Here is my note:

            \(request.context)

            Focus on this part of it: "\(focus)"
            """
    }

    /// Pull the human-readable reason out of an error body, if there is one.
    private static func errorMessage(in data: Data) -> String? {
        struct ErrorBody: Decodable {
            struct Detail: Decodable { let message: String? }
            let error: Detail?
        }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error?.message
    }

    // MARK: - Wire format

    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let maxTokens: Int
        let system: String
        let messages: [Message]

        enum CodingKeys: String, CodingKey {
            case model
            case maxTokens = "max_tokens"
            case system
            case messages
        }
    }

    private struct ResponseBody: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }
}
