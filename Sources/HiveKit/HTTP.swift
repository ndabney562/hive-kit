import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One HTTP answer: GitHub's rate-limit state lives in the headers, so they come back with the body.
public struct HTTPReply: Sendable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    public var data: Data

    public init(status: Int, headers: [String: String] = [:], data: Data) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        self.data = data
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPReply
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    /// Ephemeral: no cookies or cache are kept between calls.
    public init() {
        session = URLSession(configuration: .ephemeral)
    }

    public func send(_ request: URLRequest) async throws -> HTTPReply {
        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: String]()) {
            $0[String(describing: $1.key)] = String(describing: $1.value)
        }
        return HTTPReply(status: http?.statusCode ?? 0, headers: headers, data: data)
    }
}

extension URLRequest {
    /// A POST with an application/x-www-form-urlencoded body.
    public static func form(_ url: URL, _ fields: [(String, String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        request.httpBody = Data(fields.map {
            "\($0.0)=\($0.1.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").utf8)
        return request
    }
}
