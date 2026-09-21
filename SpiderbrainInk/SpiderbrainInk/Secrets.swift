import Foundation

/// Reads local secrets from `Secrets.plist`.
///
/// That file is gitignored and lives only on this machine. `Secrets.example.plist`
/// is committed alongside it to document the shape — copy it, drop your key in,
/// and the bundle picks it up.
///
/// This puts the key in the app bundle, which means anyone with the binary can
/// extract it. That is acceptable while this runs on personal devices. Once the
/// canvas is shared with other people, the key has to move behind a server and
/// `AnthropicPromptService` gets swapped for one that calls it — the
/// `PromptService` protocol exists so that change stops here.
enum Secrets {

    /// The Anthropic API key, or nil when `Secrets.plist` is absent or empty.
    static var anthropicAPIKey: String? {
        guard let url = Bundle.main.url(forResource: "Secrets", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let key = values["ANTHROPIC_API_KEY"] as? String,
              !key.isEmpty
        else { return nil }

        return key
    }
}
