import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FetchError: Error, Equatable {
    case offline
    /// GitHub's rate limit; `until` is when it resets, when GitHub says.
    case rateLimited(until: Date?)
    case signedOut
    /// The App can't see this repo (removed from "Only select repositories", renamed or deleted).
    case repoNotFound(String)
    case github(status: Int, message: String)

    /// GitHub's side failed (a 5xx, or a reply cut off mid-way): a smaller query may get through.
    public var serverSide: Bool {
        if case .github(let status, let message) = self { return status >= 500 || message == "not JSON" }
        return false
    }
}

/// Read-only GitHub API calls with the signed-in user's token. Only GET requests and GraphQL queries: the app never
/// writes to GitHub.
public struct GitHubClient: Sendable {
    public static let api = URL(string: "https://api.github.com")!

    let keeper: TokenKeeper
    let transport: any HTTPTransport
    let now: @Sendable () -> Date

    public init(keeper: TokenKeeper, transport: any HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = Date.init) {
        self.keeper = keeper
        self.transport = transport
        self.now = now
    }

    /// GET a REST path ("/repos/o/r/git/trees/…"); nil for the statuses in `missing` (e.g. 403/404 when a feature is off).
    public func rest(_ path: String, missing: Set<Int> = []) async throws -> Data? {
        var components = URLComponents(url: Self.api, resolvingAgainstBaseURL: false)!
        let parts = path.split(separator: "?", maxSplits: 1)
        components.percentEncodedPath = String(parts[0])
        components.percentEncodedQuery = parts.count > 1 ? String(parts[1]) : nil
        var request = URLRequest(url: components.url!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let reply = try await send(request)
        // A rate limit can come back as a 403: report it, never mistake it for "feature off".
        if isRateLimited(reply) { throw FetchError.rateLimited(until: resetDate(reply)) }
        if missing.contains(reply.status) { return nil }
        try check(reply)
        return reply.data
    }

    /// A GraphQL query; returns `data`. Errors for one repo come back as `.repoNotFound`.
    public func graphql(_ query: String, variables: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: Self.api.appendingPathComponent("graphql"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])
        let reply = try await send(request)
        try check(reply)
        guard let json = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any] else {
            throw FetchError.github(status: reply.status, message: "not JSON")
        }
        let errors = json["errors"] as? [[String: Any]] ?? []
        if errors.contains(where: { $0["type"] as? String == "RATE_LIMITED" }) {
            throw FetchError.rateLimited(until: resetDate(reply))
        }
        if let missing = errors.first(where: { $0["type"] as? String == "NOT_FOUND" }) {
            let path = (missing["path"] as? [Any])?.first as? String ?? "?"
            throw FetchError.repoNotFound(path)
        }
        guard let data = json["data"] as? [String: Any], errors.isEmpty else {
            throw FetchError.github(status: reply.status, message: errors.first?["message"] as? String ?? "no data")
        }
        return data
    }

    /// Sends with the current token; on a 401, refreshes once (through the keeper) and tries again.
    public func send(_ request: URLRequest) async throws -> HTTPReply {
        var request = request
        do {
            var token = try await keeper.accessToken()
            for attempt in 0..<2 {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let reply = try await transport.send(request)
                if reply.status != 401 { return reply }
                if attempt == 0 { token = try await keeper.tokenAfterRejection(of: token) }
            }
            throw FetchError.signedOut
        } catch is URLError {
            throw FetchError.offline
        } catch AuthError.offline {
            throw FetchError.offline
        } catch AuthError.signedOut {
            throw FetchError.signedOut
        }
    }

    func isRateLimited(_ reply: HTTPReply) -> Bool {
        reply.status == 429 || (reply.status == 403 &&
            (reply.headers["x-ratelimit-remaining"] == "0" || reply.headers["retry-after"] != nil))
    }

    public func check(_ reply: HTTPReply) throws {
        if isRateLimited(reply) { throw FetchError.rateLimited(until: resetDate(reply)) }
        guard (200..<300).contains(reply.status) else {
            let json = try? JSONSerialization.jsonObject(with: reply.data) as? [String: Any]
            throw FetchError.github(status: reply.status, message: json?["message"] as? String ?? "")
        }
    }

    public func resetDate(_ reply: HTTPReply) -> Date? {
        if let after = reply.headers["retry-after"].flatMap(TimeInterval.init) {
            return now().addingTimeInterval(after)
        }
        return reply.headers["x-ratelimit-reset"].flatMap(TimeInterval.init).map(Date.init(timeIntervalSince1970:))
    }
}

