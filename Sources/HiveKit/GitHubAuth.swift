import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
import CryptoKit
#endif

// GitHub sign-in: a GitHub App with the device flow (the user types a short code on github.com). No client secret
// and no server: GitHub lets device-flow tokens refresh with the client ID alone. Read-only permissions are set on
// the App's settings page, not here.

public enum AuthError: Error, Equatable {
    /// No token, or GitHub no longer accepts it: sign in again.
    case signedOut
    /// The user pressed Cancel on github.com.
    case denied
    /// The user code ran out (15 minutes) before the user typed it.
    case codeExpired
    case offline
    case github(String)
}

/// A user access token. Expiring tokens last 8 hours and refresh for 6 months; the refresh token works once.
public struct Token: Codable, Equatable, Sendable {
    public var accessToken: String
    /// Nil when the App has token expiry turned off.
    public var expiresAt: Date?
    public var refreshToken: String?
    public var refreshExpiresAt: Date?

    public init(accessToken: String, expiresAt: Date?, refreshToken: String?, refreshExpiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.refreshToken = refreshToken
        self.refreshExpiresAt = refreshExpiresAt
    }
}

/// What to show while the user signs in: "Go to `verificationURI` and type `userCode`".
public struct DeviceCode: Equatable, Sendable {
    public var userCode: String
    public var verificationURI: URL
    public var expiresAt: Date
    var deviceCode: String
    var interval: Int
}

public struct DeviceFlow: Sendable {
    /// The "Health Score Noah" GitHub App (github.com/settings/apps), shared by the Hive apps: read-only, installed on
    /// the repos they read. A client ID is public; there is no secret.
    public static let appClientID = "Iv23liYCvEQLnZLeAfKd"

    static let codeURL = URL(string: "https://github.com/login/device/code")!
    static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    let clientID: String
    let transport: any HTTPTransport
    let now: @Sendable () -> Date
    let sleep: @Sendable (Duration) async throws -> Void

    public init(clientID: String, transport: any HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.clientID = clientID
        self.transport = transport
        self.now = now
        self.sleep = sleep
    }

    public func start() async throws -> DeviceCode {
        let json = try await post(Self.codeURL, [("client_id", clientID)])
        guard let device = json["device_code"] as? String, let user = json["user_code"] as? String,
              let uri = (json["verification_uri"] as? String).flatMap(URL.init(string:)) else {
            throw AuthError.github(json["error"] as? String ?? "no device code")
        }
        let expiresIn = json["expires_in"] as? Int ?? 900
        return DeviceCode(userCode: user, verificationURI: uri, expiresAt: now().addingTimeInterval(TimeInterval(expiresIn)),
                          deviceCode: device, interval: json["interval"] as? Int ?? 5)
    }

    /// Polls until the user types the code, no faster than GitHub's interval. Cancel the task to stop.
    public func waitForToken(_ code: DeviceCode) async throws -> Token {
        var interval = code.interval
        while true {
            try await sleep(.seconds(interval))
            if now() >= code.expiresAt { throw AuthError.codeExpired }
            let json: [String: Any]
            do {
                json = try await post(Self.tokenURL, [
                    ("client_id", clientID), ("device_code", code.deviceCode),
                    ("grant_type", "urn:ietf:params:oauth:grant-type:device_code"),
                ])
            } catch AuthError.offline {
                // The user is in Safari typing the code, so iOS drops the app's request: ask again next round
                // (iPhone, 2026-11-05). The code's expiry still ends the wait.
                continue
            }
            switch json["error"] as? String {
            case nil: return try token(json)
            case "authorization_pending": continue
            case "slow_down": interval = json["interval"] as? Int ?? interval + 5
            case "expired_token", "token_expired": throw AuthError.codeExpired
            case "access_denied": throw AuthError.denied
            case let error?: throw AuthError.github(error)
            }
        }
    }

    /// Spends the refresh token: GitHub accepts each one once.
    public func refresh(_ refreshToken: String) async throws -> Token {
        let json = try await post(Self.tokenURL, [
            ("client_id", clientID), ("grant_type", "refresh_token"), ("refresh_token", refreshToken),
        ])
        switch json["error"] as? String {
        case nil: return try token(json)
        case "bad_refresh_token": throw AuthError.signedOut
        case let error?: throw AuthError.github(error)
        }
    }

    func token(_ json: [String: Any]) throws -> Token {
        guard let access = json["access_token"] as? String else { throw AuthError.github("no access token") }
        let at = { (key: String) in (json[key] as? Int).map { self.now().addingTimeInterval(TimeInterval($0)) } }
        return Token(accessToken: access, expiresAt: at("expires_in"), refreshToken: json["refresh_token"] as? String,
                     refreshExpiresAt: at("refresh_token_expires_in"))
    }

    func post(_ url: URL, _ fields: [(String, String)]) async throws -> [String: Any] {
        let reply: HTTPReply
        do {
            reply = try await transport.send(.form(url, fields))
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()  // the caller's task was cancelled, not the network
        } catch is URLError {
            throw AuthError.offline
        }
        guard let json = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any] else {
            throw AuthError.github("HTTP \(reply.status)")
        }
        return json
    }
}

public protocol TokenSafe: Sendable {
    func read() -> Token?
    func write(_ token: Token) throws
    func clear()
    /// Saves `new` only if the store still holds `old`; false when another app changed it first (signed out, signed
    /// in again, or refreshed). The Keychain store does the check and the save in one step (Codex, PR #18).
    func replace(_ old: Token, with new: Token) throws -> Bool
}

extension TokenSafe {
    /// Check, then save: enough for a store only one process uses.
    public func replace(_ old: Token, with new: Token) throws -> Bool {
        guard read() == old else { return false }
        try write(new)
        return true
    }
}

/// One GitHub sign-in for every Hive app (Noah, 2026-11-09: "sign in once"). Reads the shared token first, then
/// the app's own older one, which it moves into the shared store. Saves to the shared store, or to the app's own when
/// sharing fails (e.g. a simulator build without the Keychain group). Sign-out clears both, so it signs out every app.
public struct SharedTokenSafe: TokenSafe {
    let shared: any TokenSafe
    let own: any TokenSafe

    public init(shared: any TokenSafe, own: any TokenSafe) {
        self.shared = shared
        self.own = own
    }

    /// What the shared store holds after a sign-out: a marker, not an empty store, so an app's older own token is
    /// never moved back in and every app stays signed out (Codex, PR #18).
    static let signedOut = Token(accessToken: "", expiresAt: nil, refreshToken: nil, refreshExpiresAt: nil)

    public func read() -> Token? {
        if let token = shared.read() {
            own.clear()  // the shared token (or the sign-out marker) wins over a stale own copy
            return token.accessToken.isEmpty ? nil : token
        }
        guard let token = own.read() else { return nil }
        if (try? shared.write(token)) != nil { own.clear() }  // moved: the other Hive apps see it now
        return token
    }

    public func write(_ token: Token) throws {
        do {
            try shared.write(token)
            own.clear()
        } catch {
            try own.write(token)
        }
    }

    public func clear() {
        if (try? shared.write(Self.signedOut)) == nil { shared.clear() }
        own.clear()
    }

    public func replace(_ old: Token, with new: Token) throws -> Bool {
        if shared.read() != nil { return try shared.replace(old, with: new) }  // the marker never matches a token
        return try own.replace(old, with: new)
    }
}

#if canImport(Security)
extension SharedTokenSafe {
    /// The Keychain store every Hive app shares, plus the app's own (`service` = its bundle id). The group name comes
    /// from the app's Info.plist key `HiveKeychainGroup` (`$(AppIdentifierPrefix)com.noahdabney.hive`), which must
    /// match a `keychain-access-groups` entitlement; without the key the app keeps its own token, as before.
    public static func hive(service: String, bundle: Bundle = .main) -> any TokenSafe {
        let own = KeychainTokenSafe(service: service)
        guard let group = bundle.object(forInfoDictionaryKey: "HiveKeychainGroup") as? String,
              !group.isEmpty, !group.hasPrefix("$(") else { return own }
        return SharedTokenSafe(shared: KeychainTokenSafe(service: "com.noahdabney.hive", accessGroup: group), own: own)
    }
}

public struct KeychainError: Error, Equatable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

/// The Keychain: readable after the first unlock, never synced or restored to another device. Pass the App Group's
/// access group to share the token with the widget.
public struct KeychainTokenSafe: TokenSafe {
    let service: String
    let accessGroup: String?
    static let account = "github"

    /// `service` is the Keychain name (an app's own, e.g. "com.noahdabney.hivetempo", or the shared
    /// "com.noahdabney.hive" with the Hive `accessGroup`; see `SharedTokenSafe.hive`).
    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: Self.account]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    public func read() -> Token? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(Token.self, from: data)
    }

    public func write(_ token: Token) throws {
        clear()
        var q = query
        q[kSecValueData as String] = try JSONEncoder().encode(token)
        q[kSecAttrGeneric as String] = Self.fingerprint(token)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { throw KeychainError(status: status) }
    }

    /// One Keychain update that matches the stored item by `old`'s fingerprint: if another app changed the item
    /// first, nothing matches and nothing is saved.
    public func replace(_ old: Token, with new: Token) throws -> Bool {
        var q = query
        q[kSecAttrGeneric as String] = Self.fingerprint(old)
        let change: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(new),
                                     kSecAttrGeneric as String: Self.fingerprint(new)]
        let status = SecItemUpdate(q as CFDictionary, change as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { throw KeychainError(status: status) }
        // An item saved before 1.5.0 has no fingerprint. Those live only in an app's own store (no access group),
        // which one app uses, so check-then-save is safe there. The shared store is only ever written with a
        // fingerprint, so it never takes this path and stays one atomic step (Codex, PR #18 round 3).
        guard accessGroup == nil, read() == old else { return false }
        try write(new)
        return true
    }

    /// A SHA-256 of the access token: matches the item without keeping the token in a searchable attribute.
    static func fingerprint(_ token: Token) -> Data {
        Data(SHA256.hash(data: Data(token.accessToken.utf8)))
    }

    public func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
#endif

/// The one owner of the token. Refreshes go through this actor one at a time, and callers that arrive during a
/// refresh wait for it instead of spending the (single-use) refresh token again.
public actor TokenKeeper {
    let flow: DeviceFlow
    let safe: any TokenSafe
    /// Refresh this long before the token runs out.
    static let margin: TimeInterval = 300
    private var refreshing: Task<Token, Error>?
    /// Goes up at each sign-out: a refresh started before it must not save its token (Codex review, 2026-11-05).
    private var session = 0

    /// `safe` is usually `KeychainTokenSafe(service: "<the app's bundle id>")`.
    public init(flow: DeviceFlow, safe: any TokenSafe) {
        self.flow = flow
        self.safe = safe
    }

    public var isSignedIn: Bool { safe.read() != nil }

    /// Signs in with the device flow; `show` gets the code to put on screen.
    public func signIn(show: @Sendable (DeviceCode) async -> Void) async throws {
        let started = session
        let code = try await flow.start()
        await show(code)
        let token = try await flow.waitForToken(code)
        // A sign-out while the code was on screen wins (Codex review, 2026-11-07).
        guard session == started else { throw AuthError.signedOut }
        // A new sign-in replaces the session: an older refresh still in flight must not overwrite it.
        session += 1
        refreshing?.cancel()
        refreshing = nil
        try safe.write(token)
    }

    public func signOut() {
        session += 1
        refreshing?.cancel()
        refreshing = nil
        safe.clear()
    }

    /// A token good for at least a few minutes, refreshed first when needed.
    public func accessToken() async throws -> String {
        guard let token = safe.read() else { throw AuthError.signedOut }
        if let expires = token.expiresAt, expires.timeIntervalSince(flow.now()) < Self.margin {
            return try await refresh(token).accessToken
        }
        return token.accessToken
    }

    /// GitHub turned `rejected` down (401). Refreshes unless another caller already has.
    public func tokenAfterRejection(of rejected: String) async throws -> String {
        guard let token = safe.read() else { throw AuthError.signedOut }
        if token.accessToken != rejected { return token.accessToken }
        return try await refresh(token).accessToken
    }

    private func refresh(_ token: Token) async throws -> Token {
        if let refreshing {
            let joined = session
            let fresh = try await refreshing.value
            // Callers that joined a refresh honour a sign-out too (Codex review, 2026-11-07).
            guard session == joined else { throw AuthError.signedOut }
            return fresh
        }
        guard let refreshToken = token.refreshToken,
              token.refreshExpiresAt.map({ $0 > flow.now() }) ?? true else {
            safe.clear()
            throw AuthError.signedOut
        }
        let started = session
        // The refresh saves inside the task, so every caller (the first and those that join) gets the same checked
        // result. It saves only over the token it started from: a sign-out, a new sign-in or another Hive app's
        // refresh in between wins (shared store, Codex PR #18).
        let task = Task { [flow, safe] () throws -> Token in
            let fresh: Token
            do {
                fresh = try await flow.refresh(refreshToken)
            } catch AuthError.signedOut {
                // GitHub refused the refresh token. It works once, so if another app refreshed first, its new token
                // is saved already: use it. Otherwise sign out, but only over the dead token (one Keychain step).
                if try safe.replace(token, with: SharedTokenSafe.signedOut) {
                    if safe.read()?.accessToken == "" { safe.clear() }  // a single app's store keeps no marker
                    throw AuthError.signedOut
                }
                guard let current = safe.read() else { throw AuthError.signedOut }
                return current
            }
            if try safe.replace(token, with: fresh) { return fresh }
            guard let current = safe.read() else { throw AuthError.signedOut }
            return current
        }
        refreshing = task
        defer { if session == started { refreshing = nil } }
        let fresh = try await task.value
        guard session == started else { throw AuthError.signedOut }  // this app signed out or in again meanwhile
        return fresh
    }
}
