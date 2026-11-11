import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import HiveKit

private let config = HubConfig(baseURL: URL(string: "https://mac.tail1234.ts.net")!, key: "k_abcdefghijklmnopqrstu")

private func fastLink(_ transport: StubTransport, timeout: Duration = .seconds(5)) -> HubLink {
    HubLink(config: config, transport: transport, pollEvery: .milliseconds(5), timeout: timeout)
}

/// A PairingStore in memory (the Keychain stand-in, as MemorySafe is for tokens).
final class MemoryPairingStore: PairingStore {
    let value = Mutex<HubConfig?>(nil)
    func read() -> HubConfig? { value.withLock { $0 } }
    func write(_ c: HubConfig) throws { value.withLock { $0 = c } }
    func clear() { value.withLock { $0 = nil } }
}

@Suite struct HiveMindLinkTests {
    @Test func pingReachable() async {
        let stub = StubTransport { _ in json(["ok": true]) }
        #expect(await fastLink(stub).ping() == .reachable)
        #expect(stub.requests[0].url?.path == "/api/ping")
        #expect(stub.requests[0].value(forHTTPHeaderField: "X-HiveMind-Token") == config.key)
        #expect(stub.requests[0].timeoutInterval == 3)
    }

    @Test func pingForbiddenIsUnpaired() async {
        let stub = StubTransport { _ in json(["error": "no"], status: 403) }
        #expect(await fastLink(stub).ping() == .unpaired)
    }

    @Test func pingUnpairedSendsNothing() async {
        let stub = StubTransport { _ in json([:]) }
        #expect(await HubLink(config: nil, transport: stub).ping() == .unpaired)
        #expect(stub.requests.isEmpty)
    }

    @Test func pingTimeout() async {
        let stub = StubTransport { _ in try await Task.sleep(for: .seconds(30)); return json([:]) }
        let link = HubLink(config: config, transport: stub, pingTimeout: .milliseconds(50))
        #expect(await link.ping() == .unreachable)
    }

    @Test func askPollsUntilDone() async throws {
        let jobs = Mutex(0)
        let stub = StubTransport { request in
            switch request.url?.path {
            case "/api/run": return json(["job_id": "j1"])
            default:
                let n = jobs.withLock { $0 += 1; return $0 }
                return n == 1 ? json(["done": false]) : json(["done": true, "result": ["ok": true, "text": "answer"]])
            }
        }
        #expect(try await fastLink(stub).ask("hi", project: nil) == "answer")
        let sent = stub.requests
        #expect(sent.count == 3)
        #expect(sent[0].httpMethod == "POST" && sent[0].url?.path == "/api/run")
        #expect(sent[1].url?.path == "/api/job" && sent[1].url?.query == "id=j1")
        #expect(sent.allSatisfy { $0.value(forHTTPHeaderField: "X-HiveMind-Token") == config.key })
        let body = try JSONSerialization.jsonObject(with: sent[0].httpBody!) as! [String: Any]
        #expect(body["task"] as? String == "hi" && body["async"] as? Bool == true && body["project"] == nil)
    }

    @Test func askSendsProjectWhenGiven() async throws {
        let stub = StubTransport { request in
            request.url?.path == "/api/run" ? json(["job_id": "j1"]) : json(["done": true, "result": ["ok": true, "text": "x"]])
        }
        _ = try await fastLink(stub).ask("hi", project: "hive-kit")
        let body = try JSONSerialization.jsonObject(with: stub.requests[0].httpBody!) as! [String: Any]
        #expect(body["project"] as? String == "hive-kit")
    }

    @Test func askTimesOut() async {
        let stub = StubTransport { request in
            request.url?.path == "/api/run" ? json(["job_id": "j1"]) : json(["done": false])
        }
        await #expect(throws: HubLinkError.timedOut) {
            try await HubLink(config: config, transport: stub, pollEvery: .milliseconds(10), timeout: .milliseconds(50))
                .ask("hi", project: nil)
        }
    }

    @Test func askUnpaired() async {
        let stub = StubTransport { _ in json([:]) }
        await #expect(throws: HubLinkError.unpaired) { try await HubLink(config: nil, transport: stub).ask("hi", project: nil) }
        #expect(stub.requests.isEmpty)
        let forbidden = StubTransport { _ in json([:], status: 403) }
        await #expect(throws: HubLinkError.unpaired) { try await fastLink(forbidden).ask("hi", project: nil) }
    }

    @Test func askUnreachableAndRejectedAndFailed() async {
        let down = StubTransport { _ in throw URLError(.cannotConnectToHost) }
        await #expect(throws: HubLinkError.unreachable) { try await fastLink(down).ask("hi", project: nil) }
        let bad = StubTransport { _ in json(["error": "unlisted project"], status: 400) }
        await #expect(throws: HubLinkError.rejected(status: 400, message: "unlisted project")) {
            try await fastLink(bad).ask("hi", project: "x")
        }
        let failed = StubTransport { request in
            request.url?.path == "/api/run" ? json(["job_id": "j1"])
                : json(["done": true, "result": ["ok": false, "text": "HiveMind error: boom"]])
        }
        await #expect(throws: HubLinkError.failed("HiveMind error: boom")) { try await fastLink(failed).ask("hi", project: nil) }
    }

    @Test func cancelledAskIsCancellation() async {
        let started = Mutex(false)
        let stub = StubTransport { _ in
            started.withLock { $0 = true }
            try await Task.sleep(for: .seconds(30))
            return json([:])
        }
        let link = fastLink(stub)
        let task = Task { try await link.ask("hi", project: nil) }
        while !started.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func urlCancelledIsCancellation() async {
        let stub = StubTransport { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) { try await fastLink(stub).ask("hi", project: nil) }
    }

    @Test func cancelDuringPollIsCancellation() async {
        let polls = Mutex(0)
        let stub = StubTransport { request in
            if request.url?.path == "/api/run" { return json(["job_id": "j1"]) }
            polls.withLock { $0 += 1 }
            return json(["done": false])
        }
        let link = HubLink(config: config, transport: stub, pollEvery: .milliseconds(5), timeout: .seconds(30))
        let task = Task { try await link.ask("hi", project: nil) }
        while polls.withLock({ $0 }) < 2 { try? await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    // MARK: HubEngine

    @Test func engineReadyWhenReachable() async {
        let engine = HubEngine(link: fastLink(StubTransport { _ in json(["ok": true]) }))
        #expect(engine.name == "HiveMind")
        #expect(await engine.unavailableReason() == nil)
    }

    @Test func engineReasonsInPlainEnglish() async {
        let unpaired = HubEngine(link: HubLink(config: nil, transport: StubTransport { _ in json([:]) }))
        #expect(await unpaired.unavailableReason() != nil)
        let down = HubEngine(link: fastLink(StubTransport { _ in throw URLError(.cannotConnectToHost) }))
        #expect(await down.unavailableReason() != nil)
    }

    @Test func engineSendsInstructionsThenPrompt() async throws {
        let stub = StubTransport { request in
            request.url?.path == "/api/run" ? json(["job_id": "j1"]) : json(["done": true, "result": ["ok": true, "text": "coach says"]])
        }
        let answer = try await HubEngine(link: fastLink(stub)).answer("How was my week?", instructions: "You are a coach.")
        #expect(answer == "coach says")
        let body = try JSONSerialization.jsonObject(with: stub.requests[0].httpBody!) as! [String: Any]
        #expect(body["task"] as? String == "You are a coach.\n\nHow was my week?")
        #expect(body["project"] == nil)
    }

    // MARK: PairingSafe

    @Test func pairingRoundTrip() throws {
        let store = MemoryPairingStore()
        #expect(PairingSafe.load(from: store) == nil)
        try PairingSafe.save(config, to: store)
        #expect(PairingSafe.load(from: store) == config)
        PairingSafe.clear(from: store)
        #expect(PairingSafe.load(from: store) == nil)
    }

    #if canImport(Security)
    @Test func pairingStoreNames() {
        // The account and service every Hive app and HiveMind agree on.
        #expect(KeychainPairingStore.account == "hivemind-pairing")
        #expect(KeychainPairingStore.service == "com.noahdabney.hive")
    }

    @Test func pairingKeychainWriteReplaces() throws {
        let store = KeychainPairingStore(service: "com.noahdabney.hivekit.tests.\(UUID().uuidString)", accessGroup: nil)
        defer { store.clear() }
        try store.write(config)
        let other = HubConfig(baseURL: URL(string: "https://other.ts.net")!, key: "k_zzzzzzzzzzzzzzzzzzzzz")
        try store.write(other)
        #expect(store.read() == other)
    }

    @Test func pairingKeychainRoundTrip() throws {
        let store = KeychainPairingStore(service: "com.noahdabney.hivekit.tests.\(UUID().uuidString)", accessGroup: nil)
        defer { store.clear() }
        try store.write(config)
        #expect(store.read() == config)
        store.clear()
        #expect(store.read() == nil)
    }
    #endif
}
