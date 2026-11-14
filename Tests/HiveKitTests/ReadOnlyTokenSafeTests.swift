import Foundation
import Testing
import HiveKit

/// The widgets' read-only sign-in (moved from HiveScore's HealthScoreKit and HiveWorld's widget, 1.11.0).
@Suite struct ReadOnlyTokenSafeTests {
    final class Box: TokenSafe, @unchecked Sendable {
        var token: Token? = Token(accessToken: "a", expiresAt: Date(), refreshToken: "r", refreshExpiresAt: nil)
        var writes = 0, clears = 0
        func read() -> Token? { token }
        func write(_ token: Token) throws { writes += 1; self.token = token }
        func clear() { clears += 1; token = nil }
    }

    @Test func handsOutTheAccessTokenWithoutItsRefreshToken() {
        let t = ReadOnlyTokenSafe(Box()).read()
        #expect(t?.accessToken == "a" && t?.refreshToken == nil && t?.expiresAt == nil && t?.refreshExpiresAt == nil)
    }

    @Test func neverWritesReplacesOrSignsOut() {
        let box = Box()
        let safe = ReadOnlyTokenSafe(box)
        let new = Token(accessToken: "b", expiresAt: nil, refreshToken: nil, refreshExpiresAt: nil)
        #expect(throws: AuthError.signedOut) { try safe.write(new) }
        #expect(throws: AuthError.signedOut) { _ = try safe.replace(safe.read()!, with: new) }
        safe.clear()
        #expect(box.writes == 0 && box.clears == 0 && box.token?.accessToken == "a")
    }

    @Test func signedOutStaysSignedOut() {
        let box = Box()
        box.token = nil
        #expect(ReadOnlyTokenSafe(box).read() == nil)
    }
}
