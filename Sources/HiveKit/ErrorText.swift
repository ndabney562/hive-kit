import Foundation

/// Shared plain-English descriptions for GitHub auth, fetch, and Keychain errors across Hive apps.
public enum HiveErrorText {
    public static func words(_ error: any Error, offline: String = "No internet connection.") -> String {
        switch error {
        case FetchError.offline, AuthError.offline:
            offline
        case FetchError.rateLimited(let until):
            "GitHub asked to wait" + (until.map { " until \($0.formatted(date: .omitted, time: .shortened))" } ?? "") + "."
        case FetchError.signedOut, AuthError.signedOut:
            "GitHub signed you out. Sign in again."
        case FetchError.repoNotFound(let repo):
            "The app can't see \(repo). Add it to the GitHub App, or untrack it in Settings."
        case FetchError.github(let status, let message):
            "GitHub answered \(status)\(message.isEmpty ? "" : ": \(message)")."
        case AuthError.denied:
            "Sign-in was cancelled on GitHub."
        case AuthError.codeExpired:
            "The code ran out. Start again."
        case AuthError.github(let message):
            "GitHub sign-in failed: \(message)."
        #if canImport(Security)
        case let e as KeychainError:
            "Couldn't save the sign-in on this device (Keychain error \(e.status))."
        #endif
        default:
            error.localizedDescription
        }
    }
}
