import Foundation
import Testing
@testable import HiveKit

/// Counts calls, so a test can prove an engine was (or was not) reached.
actor CallCount {
    private(set) var n = 0
    func bump() { n += 1 }
}

struct StubEngine: HiveAIEngine {
    var name: String
    var reason: String?
    var result: Result<String, Error>
    var calls = CallCount()

    func unavailableReason() async -> String? { reason }
    func answer(_ prompt: String, instructions: String) async throws -> String {
        await calls.bump()
        return try result.get()
    }
}

struct Boom: Error {}

struct HiveAITests {
    @Test func firstReadyEngineAnswers() async {
        let off = StubEngine(name: "off", reason: "nope", result: .success("no"))
        let on = StubEngine(name: "on", reason: nil, result: .success("hi"))
        let out = await HiveAI(engines: [off, on]).answer("p", instructions: "i")
        #expect(out == .answer("hi", engine: "on"))
        #expect(await off.calls.n == 0)
    }

    @Test func failingEngineFallsThrough() async {
        let bad = StubEngine(name: "bad", reason: nil, result: .failure(Boom()))
        let on = StubEngine(name: "on", reason: nil, result: .success("hi"))
        let out = await HiveAI(engines: [bad, on]).answer("p", instructions: "i")
        #expect(out == .answer("hi", engine: "on"))
        #expect(await bad.calls.n == 1)
    }

    @Test func noEngineGivesPastePrompt() async {
        let out = await HiveAI(engines: []).answer("question", instructions: "rules")
        #expect(out == .pastePrompt("rules\n\nquestion"))
    }

    @Test func allEnginesFailingGivesPastePrompt() async {
        let bad = StubEngine(name: "bad", reason: nil, result: .failure(Boom()))
        let out = await HiveAI(engines: [bad]).answer("q", instructions: "r")
        #expect(out == .pastePrompt("r\n\nq"))
    }

    @Test func cancellationStopsTheChain() async {
        let cancels = StubEngine(name: "c", reason: nil, result: .failure(CancellationError()))
        let later = StubEngine(name: "later", reason: nil, result: .success("late"))
        let out = await Task { await HiveAI(engines: [cancels, later]).answer("q", instructions: "r") }.value
        #expect(out == .pastePrompt("r\n\nq"))
        #expect(await later.calls.n == 0)
    }

    @Test func alreadyCancelledTaskCallsNoEngine() async {
        let first = StubEngine(name: "f", reason: nil, result: .success("x"))
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return await HiveAI(engines: [first]).answer("q", instructions: "r")
        }
        task.cancel()
        #expect(await task.value == .pastePrompt("r\n\nq"))
        #expect(await first.calls.n == 0)
    }

    @Test func linkIsCappedAt4000() throws {
        let long = String(repeating: "a", count: 5000)
        for app in OpenInApp.allCases {
            let url = app.link(for: long)
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            #expect((q?.count ?? 0) <= OpenInApp.linkMax)
        }
        #expect(OpenInApp.claude.link(for: long).absoluteString == "https://claude.ai/new")
    }

    @Test func linksMatchHiveMind() {
        #expect(OpenInApp.claude.link(for: "a b&c").absoluteString == "https://claude.ai/new?q=a%20b%26c")
        #expect(OpenInApp.chatgpt.link(for: "x/y").absoluteString == "https://chatgpt.com/?q=x%2Fy")
        #expect(OpenInApp.gemini.link(for: "hi").absoluteString == "https://gemini.google.com/app")
        #expect(OpenInApp.allCases.map(\.name) == ["Claude", "ChatGPT", "Gemini"])
    }
}
