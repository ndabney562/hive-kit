import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HiveKit

struct GitHubClientTests {
    let clock = TestClock()

    func client(_ stub: StubTransport, token: Token? = nil, refresh: StubTransport = StubTransport(script: [])) -> GitHubClient {
        let flow = DeviceFlow(clientID: "Iv1.test", transport: refresh, now: clock.now, sleep: clock.sleep)
        let safe = MemorySafe(token ?? Token(accessToken: "ghu_a", expiresAt: clock.now().addingTimeInterval(3600),
                                             refreshToken: "ghr_a", refreshExpiresAt: clock.now().addingTimeInterval(86400)))
        return GitHubClient(keeper: TokenKeeper(flow: flow, safe: safe), transport: stub, now: clock.now)
    }

    @Test func sendsTheTokenAndOnlyReads() async throws {
        let stub = StubTransport { _ in json(["tree": []]) }
        _ = try await client(stub).rest("/repos/o/r/git/trees/abc?recursive=1")
        let request = stub.requests[0]
        #expect(request.url?.absoluteString == "https://api.github.com/repos/o/r/git/trees/abc?recursive=1")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_a")
    }

    @Test func rateLimitsCarryTheResetTime() async throws {
        let primary = StubTransport { _ in
            json(["message": "API rate limit exceeded"], status: 403,
                 headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1793800000"])
        }
        await #expect(throws: FetchError.rateLimited(until: Date(timeIntervalSince1970: 1_793_800_000))) {
            try await client(primary).rest("/repos/o/r")
        }
        // A rate limit is not "feature off", even where 403 means that.
        await #expect(throws: FetchError.rateLimited(until: Date(timeIntervalSince1970: 1_793_800_000))) {
            try await client(primary).rest("/repos/o/r/dependabot/alerts", missing: [403, 404])
        }
        // A secondary limit can arrive as a bare 403 with only its message.
        let bare = StubTransport { _ in json(["message": "You have exceeded a secondary rate limit."], status: 403) }
        await #expect(throws: FetchError.rateLimited(until: nil)) {
            try await client(bare).rest("/repos/o/r/dependabot/alerts", missing: [403, 404])
        }
        let secondary = StubTransport { _ in json(["message": "slow down"], status: 429, headers: ["Retry-After": "60"]) }
        await #expect(throws: FetchError.rateLimited(until: clock.now().addingTimeInterval(60))) {
            try await client(secondary).rest("/repos/o/r")
        }
        let graphql = StubTransport { _ in
            json(["data": NSNull(), "errors": [["type": "RATE_LIMITED", "message": "API rate limit exceeded"]]],
                 headers: ["x-ratelimit-reset": "1793800000"])
        }
        await #expect(throws: FetchError.rateLimited(until: Date(timeIntervalSince1970: 1_793_800_000))) {
            try await client(graphql).graphql("query { viewer { login } }", variables: [:])
        }
    }

    @Test func offlineIsItsOwnError() async throws {
        let stub = StubTransport { _ in throw URLError(.notConnectedToInternet) }
        await #expect(throws: FetchError.offline) { try await client(stub).rest("/repos/o/r") }
    }

    @Test func a401RefreshesOnceAndRetries() async throws {
        let stub = StubTransport { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer ghu_new" ? json([:]) : json([:], status: 401)
        }
        let refresh = StubTransport(script: [["access_token": "ghu_new", "expires_in": 28800, "refresh_token": "ghr_new"]])
        _ = try await client(stub, refresh: refresh).rest("/repos/o/r")
        #expect(stub.requests.count == 2 && refresh.requests.count == 1)

        let always = StubTransport { _ in json([:], status: 401) }
        let refresh2 = StubTransport(script: [["access_token": "ghu_new", "expires_in": 28800, "refresh_token": "ghr_new"]])
        await #expect(throws: FetchError.signedOut) { try await client(always, refresh: refresh2).rest("/repos/o/r") }
        #expect(always.requests.count == 2)
    }

    @Test func otherErrorsKeepGitHubsMessage() async throws {
        let stub = StubTransport { _ in json(["message": "Server Error"], status: 502) }
        await #expect(throws: FetchError.github(status: 502, message: "Server Error")) {
            try await client(stub).rest("/repos/o/r")
        }
        let missing = StubTransport { _ in json(["message": "Not Found"], status: 404) }
        #expect(try await client(missing).rest("/repos/o/r/dependabot/alerts", missing: [403, 404]) == nil)
    }
}
