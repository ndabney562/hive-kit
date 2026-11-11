import Foundation

/// Where the owner's Mac hub (HiveMind) is and the pairing key it gave this phone. Moved from HiveMind's iPhone app
/// so every Hive app can reach the hub; the JSON shape is unchanged, so HiveMind's saved pairing still decodes.
public struct HubConfig: Codable, Equatable, Sendable {
    /// `https://<mac>.<tailnet>.ts.net`.
    public var baseURL: URL
    /// The pairing key, sent as `X-HiveMind-Token`.
    public var key: String

    public init(baseURL: URL, key: String) {
        self.baseURL = baseURL
        self.key = key
    }
}

/// Whether the hub can be used right now.
public enum HubReach: Equatable, Sendable {
    /// It answered within 3 s and knows this phone.
    case reachable
    /// No answer in time (Mac asleep, off the tailnet, hub not running).
    case unreachable
    /// This app holds no pairing, or the hub no longer knows the key (HTTP 403).
    case unpaired
}
