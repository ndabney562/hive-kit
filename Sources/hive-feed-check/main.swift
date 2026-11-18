import Foundation
import HiveKit

// hive-feed-check <app> <file>: does this feed file pass what the Hive apps' readers decode? (Hive build order #11)
// Run it before `hivemind feed publish <app> <file>`, or on a changed example, to see a break before it ships.
// Exit 0 passes (or no hive-kit reader for that app), 1 problems, 2 usage.
let args = CommandLine.arguments.dropFirst()
guard args.count == 2, let app = args.first, let path = args.last else {
    FileHandle.standardError.write(Data("usage: hive-feed-check <app> <file.json>\n".utf8))
    exit(2)
}
guard let contract = FeedContract.known.first(where: { $0.app == app }) else {
    print("\(app): no reader in hive-kit, nothing to check")
    exit(0)
}
guard let data = FileManager.default.contents(atPath: path) else {
    FileHandle.standardError.write(Data("can't read \(path)\n".utf8))
    exit(2)
}
let problems = await FeedContract.check({ $0 == app ? data : nil }, contracts: [contract]).first?.problems ?? []
if problems.isEmpty {
    print("\(app): passes \(contract.reader)")
    exit(0)
}
print("\(app): \(problems.count) problem(s) for \(contract.reader)")
for p in problems { print("  - \(p)") }
exit(1)
