import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Why `HubLink.ask` failed. A cancelled task never lands here: it throws `CancellationError`.
public enum HubLinkError: Error, Equatable, Sendable {
    /// No pairing, or the hub answered 403.
    case unpaired
    /// The hub did not answer (Mac asleep, off the tailnet).
    case unreachable
    /// The job did not finish within the link's `timeout`.
    case timedOut
    /// The hub refused the request (HTTP status and its `error` text).
    case rejected(status: Int, message: String)
    /// The hub ran the job and reported failure; the hub's own message.
    case failed(String)
    /// The hub's answer was not the expected JSON.
    case badResponse
}

/// The part of HiveMind's API (docs/api/v1.md) a Hive app needs to ask the Mac hub one question: `GET /api/ping`,
/// `POST /api/run` (async, returns a job id) and `GET /api/job?id=` until the job is done. Moved from HiveMind's
/// iPhone `HubClient`; the full client (threads, uploads, settings) stays in HiveMind.
public struct HubLink: Sendable {
    private let config: HubConfig?
    private let transport: any HTTPTransport
    private let pollEvery: Duration
    private let timeout: Duration
    private let pingTimeout: Duration

    /// `config` nil means this app is not paired (`PairingSafe.load()`). `timeout` bounds one whole `ask`; a sleeping
    /// Mac would otherwise hold it. `pingTimeout` is 3 s, as in HiveMind.
    public init(config: HubConfig?, transport: any HTTPTransport = URLSessionTransport(),
                pollEvery: Duration = .seconds(2), timeout: Duration = .seconds(120),
                pingTimeout: Duration = .seconds(3)) {
        self.config = config
        self.transport = transport
        self.pollEvery = pollEvery
        self.timeout = timeout
        self.pingTimeout = pingTimeout
    }

    /// Whether the hub answers within the ping timeout and still knows this phone. Never throws; a cancelled task
    /// gets `.unreachable`.
    public func ping() async -> HubReach {
        guard let config else { return .unpaired }
        let request = Self.request("GET", "/api/ping", config: config, timeout: pingTimeout.seconds)
        let transport = self.transport, wait = pingTimeout
        return await withTaskGroup(of: HubReach.self) { group in
            group.addTask {
                guard let status = try? await transport.send(request).status else { return .unreachable }
                return status == 200 ? .reachable : status == 403 ? .unpaired : .unreachable
            }
            group.addTask {
                try? await Task.sleep(for: wait)
                return .unreachable
            }
            let first = await group.next() ?? .unreachable
            group.cancelAll()
            return first
        }
    }

    /// Sends `task` to the hub and waits for the answer text. `project` is the name of a folder the hub lists
    /// (`projects` in `GET /api/state`; the task may read it, never change it; an unlisted name is a 400, so pass
    /// nil unless the name came from the hub). Throws `HubLinkError`, or `CancellationError` when the caller's task
    /// is cancelled.
    public func ask(_ task: String, project: String?) async throws -> String {
        guard let config else { throw HubLinkError.unpaired }
        let wait = timeout
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.run(task, project: project, config: config) }
            group.addTask {
                try await Task.sleep(for: wait)
                throw HubLinkError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func run(_ task: String, project: String?, config: HubConfig) async throws -> String {
        struct Body: Encodable { var task: String; var async = true; var project: String? }
        struct Started: Decodable { var jobId: String }
        var start = Self.request("POST", "/api/run", config: config, timeout: 30)
        start.httpBody = try JSONEncoder().encode(Body(task: task, project: project))
        let startReply = try await perform(start)
        guard let started = try? JSONDecoder().decode(Started.self, from: startReply) else {
            throw HubLinkError.badResponse
        }
        struct Job: Decodable {
            struct Result: Decodable { var ok: Bool; var text: String }
            var done: Bool
            var result: Result?
        }
        while true {
            try Task.checkCancellation()
            var poll = Self.request("GET", "/api/job", config: config, timeout: 5)
            poll.url = Self.url(config, "/api/job", query: [URLQueryItem(name: "id", value: started.jobId)])
            let pollReply = try await perform(poll)
            guard let job = try? JSONDecoder().decode(Job.self, from: pollReply) else {
                throw HubLinkError.badResponse
            }
            if job.done {
                guard let result = job.result else { throw HubLinkError.badResponse }
                if result.ok { return result.text }
                throw HubLinkError.failed(result.text)
            }
            try await Task.sleep(for: pollEvery)  // throws CancellationError when cancelled
        }
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let reply: HTTPReply
        do {
            reply = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()  // the caller's task was cancelled, not the network (as GitHubClient)
        } catch {
            try Task.checkCancellation()
            throw HubLinkError.unreachable
        }
        if reply.status == 403 { throw HubLinkError.unpaired }
        guard (200..<300).contains(reply.status) else {
            let body = (try? JSONSerialization.jsonObject(with: reply.data)) as? [String: Any]
            throw HubLinkError.rejected(status: reply.status, message: (body?["error"] ?? body?["message"]) as? String ?? "")
        }
        return reply.data
    }

    private static func url(_ config: HubConfig, _ path: String, query: [URLQueryItem]? = nil) -> URL {
        var parts = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        parts.path = path
        parts.queryItems = query
        return parts.url!
    }

    private static func request(_ method: String, _ path: String, config: HubConfig, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url(config, path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue(config.key, forHTTPHeaderField: "X-HiveMind-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
}

private extension Duration {
    var seconds: TimeInterval { TimeInterval(components.seconds) + TimeInterval(components.attoseconds) / 1e18 }
}

/// The Mac hub as a `HiveAIEngine`, so HiveBeat's coach (and any Hive app) can try it before falling back to the
/// phone's own model or a paste prompt.
public struct HubEngine: HiveAIEngine {
    private let link: HubLink

    public init(link: HubLink) {
        self.link = link
    }

    public var name: String { "HiveMind" }

    /// nil only when the hub answers a ping now.
    public func unavailableReason() async -> String? {
        switch await link.ping() {
        case .reachable: return nil
        case .unpaired: return "This phone isn't paired with your Mac's HiveMind."
        case .unreachable: return "Your Mac's HiveMind isn't reachable right now."
        }
    }

    /// The hub takes one `task` string, so the instructions go first, a blank line, then the prompt. No `project` is
    /// sent: HiveMind's `project` is a folder name the hub lists, and an unlisted name is rejected with a 400.
    public func answer(_ prompt: String, instructions: String) async throws -> String {
        try await link.ask(instructions + "\n\n" + prompt, project: nil)
    }
}
