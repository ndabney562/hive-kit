import Foundation
import HiveKit

// hive-pattern (Hive build order #57, Pattern 96): find repeated interface or workflow solutions across Hive apps,
// propose shared implementations in hive-design / hive-kit, and estimate migration cost.
// Usage:
//   hive-pattern scan <repoDir ...> [--shared <dir>]... [--isolated <repoName>]...
//                     [--min-repos N] [--category interface|workflow] [--json]
// Exit: 0 ok, 2 usage or directory problem.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

private let usage = "usage: hive-pattern scan <repoDir ...> [--shared <dir>]... [--isolated <repoName>]... [--min-repos N] [--category interface|workflow] [--json]"

private func takeOption(_ name: String, from args: inout [String]) -> String? {
    guard let idx = args.firstIndex(of: name) else { return nil }
    guard idx + 1 < args.count else { fail("hive-pattern: \(name) needs a value") }
    let value = args[idx + 1]
    args.removeSubrange(idx...(idx + 1))
    return value
}

private func takeRepeated(_ name: String, from args: inout [String]) -> [String] {
    var out: [String] = []
    while let value = takeOption(name, from: &args) {
        out.append(value)
    }
    return out
}

private func takeFlag(_ name: String, from args: inout [String]) -> Bool {
    guard let idx = args.firstIndex(of: name) else { return false }
    args.remove(at: idx)
    return true
}

private func existingRepo(at raw: String) -> PatternRepo {
    let expanded = (raw as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
        fail("hive-pattern: directory not found: \(raw)")
    }
    return PatternRepo(name: url.lastPathComponent, root: url)
}

var cliArgs = Array(CommandLine.arguments.dropFirst())
guard let subcommand = cliArgs.first, subcommand == "scan" else { fail(usage) }
cliArgs.removeFirst()

let asJSON = takeFlag("--json", from: &cliArgs)
let sharedDirs = takeRepeated("--shared", from: &cliArgs).map(existingRepo)
let isolatedNames = Set(takeRepeated("--isolated", from: &cliArgs))
let minRepos = takeOption("--min-repos", from: &cliArgs).map {
    guard let n = Int($0), n >= 1 else { fail("hive-pattern: --min-repos requires an integer >= 1") }
    return n
} ?? 2
let categoryFilter: PatternCategory? = takeOption("--category", from: &cliArgs).map {
    guard let c = PatternCategory(rawValue: $0) else { fail("hive-pattern: --category must be interface or workflow") }
    return c
}

if let badFlag = cliArgs.first(where: { $0.hasPrefix("-") }) {
    fail("hive-pattern: unknown option \(badFlag)")
}
guard !cliArgs.isEmpty else { fail(usage) }

let repos = cliArgs.map(existingRepo)
var proposals = HivePattern.scan(
    repos: repos,
    sharedPackages: sharedDirs,
    isolatedRepos: isolatedNames,
    minRepos: minRepos
)
if let categoryFilter {
    proposals = proposals.filter { $0.category == categoryFilter }
}

if asJSON {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(proposals) else { fail("hive-pattern: JSON encoding failed") }
    print(String(decoding: data, as: UTF8.self))
} else {
    print(HivePattern.renderMarkdown(proposals), terminator: "")
}
