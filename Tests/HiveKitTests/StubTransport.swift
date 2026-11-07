import Foundation
import Synchronization
@testable import HiveKit

/// Records every request and answers with `reply` (copied from HiveMindKit, with headers).
final class StubTransport: HTTPTransport {
    let sent = Mutex<[URLRequest]>([])
    let reply: @Sendable (URLRequest) async throws -> HTTPReply

    init(reply: @escaping @Sendable (URLRequest) async throws -> HTTPReply) {
        self.reply = reply
    }

    /// Answers each request with the next JSON in `script`, in order.
    convenience init(script: [Any]) {
        let queue = Mutex(script.map { try! JSONSerialization.data(withJSONObject: $0) })
        self.init { _ in HTTPReply(status: 200, data: queue.withLock { $0.removeFirst() }) }
    }

    func send(_ request: URLRequest) async throws -> HTTPReply {
        sent.withLock { $0.append(request) }
        return try await reply(request)
    }

    var requests: [URLRequest] { sent.withLock { $0 } }

    /// The form fields of request `i`.
    func form(_ i: Int) -> [String: String] {
        let body = String(decoding: requests[i].httpBody ?? Data(), as: UTF8.self)
        return Dictionary(uniqueKeysWithValues: body.split(separator: "&").map {
            let kv = $0.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding! }
            return (kv[0], kv.count > 1 ? kv[1] : "")
        })
    }
}

func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> HTTPReply {
    HTTPReply(status: status, headers: headers, data: try! JSONSerialization.data(withJSONObject: object))
}

/// A token store in memory.
final class MemorySafe: TokenSafe {
    let token: Mutex<Token?>
    init(_ token: Token? = nil) { self.token = Mutex(token) }
    func read() -> Token? { token.withLock { $0 } }
    func write(_ t: Token) throws { token.withLock { $0 = t } }
    func clear() { token.withLock { $0 = nil } }
}

/// A clock the test moves by hand.
final class TestClock: Sendable {
    let time: Mutex<Date>
    let slept = Mutex<[Duration]>([])
    init(_ iso: String = "2026-11-03T12:00:00Z") { time = Mutex(ISO8601DateFormatter().date(from: iso)!) }
    var now: @Sendable () -> Date { { self.time.withLock { $0 } } }
    /// Records the wait and moves the clock on by it, without waiting.
    var sleep: @Sendable (Duration) async throws -> Void {
        { d in
            self.slept.withLock { $0.append(d) }
            self.time.withLock { $0 = $0.addingTimeInterval(TimeInterval(d.components.seconds)) }
        }
    }
}
