import Foundation

/// "Open in…" under an answer: links that hand the prompt to the person's own Claude, ChatGPT or Gemini. Moved from
/// HiveMind's `OpenInApps.swift` (same links as hivemindcore/apps.py). Opening one is the person's own tap.
public enum OpenInApp: String, CaseIterable, Sendable {
    case claude, chatgpt, gemini

    public var name: String {
        switch self { case .claude: "Claude"; case .chatgpt: "ChatGPT"; case .gemini: "Gemini" }
    }

    /// The longest prompt that still goes in the link; a longer one opens the app's home page (paste it, it's copied).
    public static let linkMax = 4000
    /// urllib.parse.quote(prompt, safe=""): only letters, digits and -._~ stay as they are.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Claude and ChatGPT take the prompt in the link when it fits; Gemini has no such link.
    public func link(for prompt: String) -> URL {
        let (prefill, home): (String?, String) = switch self {
        case .claude: ("https://claude.ai/new?q=", "https://claude.ai/new")
        case .chatgpt: ("https://chatgpt.com/?q=", "https://chatgpt.com/")
        case .gemini: (nil, "https://gemini.google.com/app")
        }
        if let prefill, prompt.count <= Self.linkMax,
           let q = prompt.addingPercentEncoding(withAllowedCharacters: Self.unreserved), let url = URL(string: prefill + q) {
            return url
        }
        return URL(string: home)!
    }
}
