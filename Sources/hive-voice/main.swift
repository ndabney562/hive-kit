import Foundation
import HiveKit

// hive-voice (Hive build order #36, Voice 18): one writing voice, every AI.
//   hive-voice brief <profile.json> [--for claude|chatgpt|gemini|generic] [--max <chars>]   paste-ready style brief
//   hive-voice check <profile.json> <file ...>                                             never-words in files (exit 1)
//   hive-voice correct <profile.json> --before <text> --after <text> [--why <text>]        keeps a correction
// Exit 0 ok, 1 check found never-words, 2 usage or file problem.
func fail(_ s: String) -> Never { FileHandle.standardError.write(Data((s + "\n").utf8)); exit(2) }
let usage = "usage: hive-voice brief|check|correct <profile.json> … (see the top of Sources/hive-voice/main.swift)"

var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2 else { fail(usage) }
let command = args.removeFirst()
let path = args.removeFirst()
@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name) else { return nil }
    guard i + 1 < args.count else { fail("hive-voice: \(name) needs a value") }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let url = URL(fileURLWithPath: path)
guard let data = try? Data(contentsOf: url) else { fail("hive-voice: can't read \(path)") }
var profile: VoiceProfile
do { profile = try VoiceProfile.decode(data) } catch { fail("hive-voice: \(path) is not a voice profile: \(error)") }

switch command {
case "brief":
    let target = option("--for").map { VoiceTarget(rawValue: $0) ?? { fail("hive-voice: --for claude|chatgpt|gemini|generic") }() } ?? .generic
    let max = option("--max").map { Int($0) ?? { fail("hive-voice: --max takes a number") }() } ?? 6000
    print(profile.brief(for: target, maxChars: max), terminator: "")
case "check":
    guard !args.isEmpty else { fail("hive-voice check <profile.json> <file ...>") }
    var found = 0
    for file in args {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { fail("hive-voice: can't read \(file)") }
        for hit in profile.check(text) { print("\(file): \(hit)"); found += 1 }
    }
    if found == 0 { print("ok: no never-words") }
    exit(found == 0 ? 0 : 1)
case "correct":
    guard let before = option("--before"), let after = option("--after") else { fail("hive-voice correct needs --before and --after") }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
    profile.correct(.init(before: before, after: after, why: option("--why"), date: f.string(from: Date())))
    do { try profile.encoded().write(to: url, options: .atomic) } catch { fail("hive-voice: can't save \(path): \(error)") }
    print("kept: \"\(before)\" → \"\(after)\" (\(profile.corrections.count) corrections)")
default:
    fail(usage)
}
