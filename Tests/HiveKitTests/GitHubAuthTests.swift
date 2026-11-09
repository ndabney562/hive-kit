import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import HiveKit

struct GitHubAuthTests {
    let clock = TestClock()
    let tokenReply: [String: Any] = ["access_token": "ghu_new", "expires_in": 28800, "refresh_token": "ghr_new",
                                     "refresh_token_expires_in": 15_811_200, "token_type": "bearer", "scope": ""]

    func flow(_ transport: StubTransport) -> DeviceFlow {
        DeviceFlow(clientID: "Iv1.test", transport: transport, now: clock.now, sleep: clock.sleep)
    }

    func expiring(in seconds: TimeInterval, refresh: String? = "ghr_old") -> Token {
        Token(accessToken: "ghu_old", expiresAt: clock.now().addingTimeInterval(seconds), refreshToken: refresh,
              refreshExpiresAt: clock.now().addingTimeInterval(86400 * 180))
    }

    @Test func deviceFlowPollsUntilTheUserTypesTheCode() async throws {
        let stub = StubTransport(script: [
            ["device_code": "dc", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device",
             "expires_in": 900, "interval": 5],
            ["error": "authorization_pending"],
            ["error": "slow_down", "interval": 10],
            tokenReply,
        ])
        let flow = flow(stub)
        let code = try await flow.start()
        #expect(code.userCode == "WDJB-MJHT")
        #expect(code.verificationURI.absoluteString == "https://github.com/login/device")
        let token = try await flow.waitForToken(code)

        #expect(token.accessToken == "ghu_new" && token.refreshToken == "ghr_new")
        #expect(token.expiresAt == clock.now().addingTimeInterval(28800))
        #expect(clock.slept.withLock { $0 } == [.seconds(5), .seconds(5), .seconds(10)])
        #expect(stub.requests[0].url == DeviceFlow.codeURL && stub.form(0) == ["client_id": "Iv1.test"])
        #expect(stub.form(1) == ["client_id": "Iv1.test", "device_code": "dc",
                                 "grant_type": "urn:ietf:params:oauth:grant-type:device_code"])
        #expect(stub.requests.allSatisfy { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Accept") == "application/json" })
    }

    @Test func deviceFlowStopsOnCancelOrExpiry() async throws {
        let code = DeviceCode(userCode: "A-B", verificationURI: URL(string: "https://github.com/login/device")!,
                              expiresAt: clock.now().addingTimeInterval(900), deviceCode: "dc", interval: 5)
        await #expect(throws: AuthError.denied) {
            try await flow(StubTransport(script: [["error": "access_denied"]])).waitForToken(code)
        }
        await #expect(throws: AuthError.codeExpired) {
            try await flow(StubTransport(script: [["error": "expired_token"]])).waitForToken(code)
        }
        // The code runs out while the user is still away: no request after expiry.
        var fresh = code
        fresh.expiresAt = clock.now().addingTimeInterval(900)
        let pending = StubTransport { _ in json(["error": "authorization_pending"]) }
        await #expect(throws: AuthError.codeExpired) { try await flow(pending).waitForToken(fresh) }
        #expect(pending.requests.count == 179)
    }

    /// The user is in Safari typing the code, so iOS drops the app's poll: keep polling (iPhone, 2026-11-05).
    @Test func deviceFlowKeepsPollingThroughADroppedRequest() async throws {
        let code = DeviceCode(userCode: "A-B", verificationURI: URL(string: "https://github.com/login/device")!,
                              expiresAt: clock.now().addingTimeInterval(900), deviceCode: "dc", interval: 5)
        let calls = Mutex(0)
        let reply = json(tokenReply)
        let stub = StubTransport { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            if n == 1 { throw URLError(.networkConnectionLost) }
            if n == 2 { throw URLError(.notConnectedToInternet) }
            return n == 3 ? json(["error": "authorization_pending"]) : reply
        }
        let token = try await flow(stub).waitForToken(code)
        #expect(token.accessToken == "ghu_new")
        #expect(stub.requests.count == 4)
    }

    @Test func refreshSendsNoClientSecret() async throws {
        let stub = StubTransport(script: [tokenReply])
        _ = try await flow(stub).refresh("ghr_old")
        #expect(stub.form(0) == ["client_id": "Iv1.test", "grant_type": "refresh_token", "refresh_token": "ghr_old"])
    }

    @Test func keeperReturnsAFreshTokenWithoutTheNetwork() async throws {
        let stub = StubTransport(script: [])
        let keeper = TokenKeeper(flow: flow(stub), safe: MemorySafe(expiring(in: 3600)))
        #expect(try await keeper.accessToken() == "ghu_old")
        #expect(stub.requests.isEmpty)
    }

    @Test func concurrentCallersShareOneRefresh() async throws {
        let reply = json(tokenReply)
        let stub = StubTransport { _ in
            try await Task.sleep(for: .milliseconds(50))
            return reply
        }
        let safe = MemorySafe(expiring(in: 60))
        let keeper = TokenKeeper(flow: flow(stub), safe: safe)
        let tokens = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { try await keeper.accessToken() } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(tokens == Array(repeating: "ghu_new", count: 5))
        #expect(stub.requests.count == 1)
        #expect(safe.read()?.refreshToken == "ghr_new")
    }

    /// A refresh that answers after sign-out must not sign the user back in.
    @Test func signOutDuringRefreshStaysSignedOut() async throws {
        let reply = json(tokenReply)
        // The reply ignores cancellation, as a request already on the wire can.
        let stub = StubTransport { _ in
            try? await Task.sleep(for: .milliseconds(200))
            return reply
        }
        let safe = MemorySafe(expiring(in: 60))
        let keeper = TokenKeeper(flow: flow(stub), safe: safe)
        let call = Task { try? await keeper.accessToken() }
        try await Task.sleep(for: .milliseconds(50))
        await keeper.signOut()
        _ = await call.value
        #expect(safe.read() == nil)
        #expect(await !keeper.isSignedIn)
    }

    @Test func signOutWhileTheCodeIsOnScreenWins() async throws {
        let stub = StubTransport(script: [
            ["device_code": "dc", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device",
             "expires_in": 900, "interval": 5],
            tokenReply,
        ])
        let safe = MemorySafe()
        let keeper = TokenKeeper(flow: flow(stub), safe: safe)
        await #expect(throws: AuthError.signedOut) {
            try await keeper.signIn { _ in await keeper.signOut() }   // the user taps Sign out mid-sign-in
        }
        #expect(safe.read() == nil)
    }

    @Test func callersJoiningARefreshHonourSignOut() async throws {
        // The refresh answers only after sign-out (a gate, not a sleep: slow CI runners overslept, 2026-11-07).
        let reply = json(tokenReply)
        let open = Mutex(false)
        let stub = StubTransport { _ in
            while !open.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
            return reply
        }
        let keeper = TokenKeeper(flow: flow(stub), safe: MemorySafe(expiring(in: 60)))
        let first = Task { try await keeper.accessToken() }
        while stub.requests.isEmpty { try await Task.sleep(for: .milliseconds(5)) }   // the refresh is in flight
        let joined = Task { try await keeper.accessToken() }
        try await Task.sleep(for: .milliseconds(30))   // joins the refresh; if late, it finds no token: also signed out
        await keeper.signOut()
        open.withLock { $0 = true }
        #expect((try? await first.value) == nil)
        #expect((try? await joined.value) == nil, "a joined caller must not get a token after sign-out")
    }

    @Test func aNewSignInBeatsAnOlderRefresh() async throws {
        // The old account's refresh is slow; the new sign-in finishes first.
        let refreshed = json(tokenReply.merging(["access_token": "ghu_old_refreshed"]) { $1 })
        let fresh = json(tokenReply)
        let code = json(["device_code": "dc", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device",
                         "expires_in": 900, "interval": 5])
        let stub = StubTransport { request in
            let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
            if body.contains("refresh_token") {
                try? await Task.sleep(for: .milliseconds(200))
                return refreshed
            }
            return request.url?.path == "/login/device/code" ? code : fresh
        }
        let safe = MemorySafe(expiring(in: 60))
        let keeper = TokenKeeper(flow: flow(stub), safe: safe)
        let old = Task { try? await keeper.accessToken() }
        try await Task.sleep(for: .milliseconds(30))
        try await keeper.signIn { _ in }
        _ = await old.value
        #expect(safe.read()?.accessToken == "ghu_new", "the new account's token must stay")
    }

    @Test func aDeadRefreshTokenSignsOut() async throws {
        let safe = MemorySafe(expiring(in: 60))
        let keeper = TokenKeeper(flow: flow(StubTransport(script: [["error": "bad_refresh_token"]])), safe: safe)
        await #expect(throws: AuthError.signedOut) { try await keeper.accessToken() }
        #expect(safe.read() == nil)

        let noRefresh = MemorySafe(expiring(in: 60, refresh: nil))
        await #expect(throws: AuthError.signedOut) {
            try await TokenKeeper(flow: flow(StubTransport(script: [])), safe: noRefresh).accessToken()
        }
    }

    @Test func offlineRefreshKeepsTheToken() async throws {
        let safe = MemorySafe(expiring(in: 60))
        let keeper = TokenKeeper(flow: flow(StubTransport { _ in throw URLError(.notConnectedToInternet) }), safe: safe)
        await #expect(throws: AuthError.offline) { try await keeper.accessToken() }
        #expect(safe.read()?.accessToken == "ghu_old")
    }

    @Test func signInStoresTheTokenAndSignOutClearsIt() async throws {
        let stub = StubTransport(script: [
            ["device_code": "dc", "user_code": "WDJB-MJHT", "verification_uri": "https://github.com/login/device",
             "expires_in": 900, "interval": 5],
            tokenReply,
        ])
        let safe = MemorySafe()
        let keeper = TokenKeeper(flow: flow(stub), safe: safe)
        let shown = Mutex<String?>(nil)
        try await keeper.signIn { code in shown.withLock { $0 = code.userCode } }
        #expect(shown.withLock { $0 } == "WDJB-MJHT")
        #expect(try await keeper.accessToken() == "ghu_new")
        await keeper.signOut()
        #expect(safe.read() == nil)
        #expect(await !keeper.isSignedIn)
    }

    // Sign in once (Noah, 2026-11-09): HiveScore and HiveTempo share one GitHub sign-in.
    @Test func sharedSafeMovesAnAppsOwnTokenIntoTheSharedOne() throws {
        let own = MemorySafe(expiring(in: 3600)), shared = MemorySafe()
        let safe = SharedTokenSafe(shared: shared, own: own)
        #expect(safe.read()?.accessToken == "ghu_old")
        #expect(shared.read()?.accessToken == "ghu_old")
        #expect(own.read() == nil)
    }

    @Test func sharedSafeFallsBackToTheAppsOwnWhenSharingFails() throws {
        let own = MemorySafe(), safe = SharedTokenSafe(shared: BrokenSafe(), own: own)
        try safe.write(expiring(in: 3600))
        #expect(own.read()?.accessToken == "ghu_old")
        #expect(safe.read()?.accessToken == "ghu_old")
    }

    @Test func sharedSafeSignOutClearsBoth() throws {
        let own = MemorySafe(expiring(in: 3600)), shared = MemorySafe(expiring(in: 3600))
        let safe = SharedTokenSafe(shared: shared, own: own)
        safe.clear()
        #expect(own.read() == nil && safe.read() == nil)
        #expect(shared.read() == SharedTokenSafe.signedOut)  // a marker, so no app's old token moves back in
    }

    /// Two apps share one token; refresh tokens work once. When the other app refreshed first, GitHub turns this
    /// app's refresh down: use the other app's new token, never sign both apps out.
    @Test func anotherAppsRefreshWinsInsteadOfSigningOut() async throws {
        let safe = MemorySafe(expiring(in: 60))
        let other = Token(accessToken: "ghu_other", expiresAt: clock.now().addingTimeInterval(28800),
                          refreshToken: "ghr_other", refreshExpiresAt: clock.now().addingTimeInterval(86400 * 180))
        let stub = StubTransport { _ in
            try safe.write(other)  // the other app saved its refresh while this one was asking GitHub
            return json(["error": "bad_refresh_token"])
        }
        let keeper = TokenKeeper(flow: flow(stub), safe: safe)
        #expect(try await keeper.accessToken() == "ghu_other")
        #expect(safe.read() == other)
    }

    /// Codex, PR #18: a sign-out in one app must not be undone by another app's older own token.
    @Test func aSharedSignOutIsNotUndoneByAnotherAppsOldToken() throws {
        let shared = MemorySafe(), ownB = MemorySafe(expiring(in: 3600))
        SharedTokenSafe(shared: shared, own: MemorySafe()).clear()   // app A signs out
        let b = SharedTokenSafe(shared: shared, own: ownB)
        #expect(b.read() == nil)
        #expect(ownB.read() == nil)
        try b.write(expiring(in: 3600))                               // signing in again works
        #expect(SharedTokenSafe(shared: shared, own: MemorySafe()).read()?.accessToken == "ghu_old")
    }

    @Test func readingTheSharedTokenDropsTheAppsStaleOwnCopy() throws {
        let shared = MemorySafe(expiring(in: 3600)), own = MemorySafe(expiring(in: 3600))
        _ = SharedTokenSafe(shared: shared, own: own).read()
        #expect(own.read() == nil)
    }

    /// Codex, PR #18: a refresh that finishes after another app signed out must not sign every app back in.
    @Test func aRefreshFinishingAfterAnotherAppsSignOutIsDropped() async throws {
        let safe = SharedTokenSafe(shared: MemorySafe(expiring(in: 60)), own: MemorySafe())
        let reply = json(tokenReply)
        let stub = StubTransport { _ in
            safe.clear()   // the other app signs out while this refresh is in flight
            return reply
        }
        let keeper = TokenKeeper(flow: flow(stub), safe: safe)
        await #expect(throws: AuthError.signedOut) { try await keeper.accessToken() }
        #expect(safe.read() == nil)
    }

    @Test func aRefreshFinishingAfterAnotherAppsNewSignInKeepsTheNewSignIn() async throws {
        let safe = MemorySafe(expiring(in: 60))
        let other = Token(accessToken: "ghu_other", expiresAt: clock.now().addingTimeInterval(28800),
                          refreshToken: "ghr_other", refreshExpiresAt: clock.now().addingTimeInterval(86400 * 180))
        let reply = json(tokenReply)
        let stub = StubTransport { _ in
            try safe.write(other)
            return reply
        }
        #expect(try await TokenKeeper(flow: flow(stub), safe: safe).accessToken() == "ghu_other")
        #expect(safe.read() == other)
    }

    #if canImport(Security)
    @Test func keychainRoundTrip() throws {
        let safe = KeychainTokenSafe(service: "com.noahdabney.hivekit.tests.\(UUID().uuidString)")
        defer { safe.clear() }
        #expect(safe.read() == nil)
        let token = expiring(in: 3600)
        try safe.write(token)
        try safe.write(token)  // a refresh replaces the old token
        #expect(safe.read() == token)
        safe.clear()
        #expect(safe.read() == nil)
    }
    #endif

    /// A real sign-in with the GitHub App, then a fetch, a forced refresh and a second fetch. Needs a person to type
    /// the code: `HIVEKIT_LIVE_SIGNIN=1 swift test --filter liveSignIn`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HIVEKIT_LIVE_SIGNIN"] != nil), .timeLimit(.minutes(15)))
    func liveSignIn() async throws {
        let safe = MemorySafe()
        let keeper = TokenKeeper(flow: DeviceFlow(clientID: DeviceFlow.appClientID), safe: safe)
        try await keeper.signIn { code in
            let line = "SIGN-IN CODE: \(code.userCode) at \(code.verificationURI)\n"
            print(line, terminator: "")
            // swift test holds a test's output until the run ends; a file shows the code straight away.
            if let path = ProcessInfo.processInfo.environment["HIVEKIT_CODE_FILE"] {
                try? line.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let first = try #require(safe.read())
        print("signed in; token expires \(String(describing: first.expiresAt)), refresh token: \(first.refreshToken != nil)")
        let client = GitHubClient(keeper: keeper)
        let before = try #require(try await client.rest("/user"))
        print("fetch 1:", before.count, "bytes")

        _ = try await keeper.tokenAfterRejection(of: first.accessToken)
        let second = try #require(safe.read())
        #expect(second.accessToken != first.accessToken && second.refreshToken != first.refreshToken)
        let after = try #require(try await client.rest("/user"))
        print("refreshed without a client secret; fetch 2:", after.count, "bytes")
        #expect(after == before)
    }
}
