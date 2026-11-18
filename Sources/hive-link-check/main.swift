import Foundation
import HiveKit

// hive-link-check [url ...]: what each Hive link opens, or why it is not one (Hive build order #32, Link 62).
// With no arguments it lists every route with an example and checks that each one reads back as itself.
// Exit 0 all good, 1 a link is not a Hive link (or a route doesn't read back).
let args = Array(CommandLine.arguments.dropFirst())
var bad = 0
if args.isEmpty {
    for link in HiveLink.examples {
        let back = HiveLink.parse(link.url)
        if back != link { bad += 1 }
        print("\(back == link ? "ok  " : "BAD ") \(link.url.absoluteString)  →  \(link.place)")
    }
} else {
    for arg in args {
        guard let url = URL(string: arg), let link = HiveLink.parse(url) else {
            bad += 1
            print("not a Hive link: \(arg) (known routes: hive-link-check with no arguments)")
            continue
        }
        print("\(arg)  →  \(link.place)")
    }
}
exit(bad == 0 ? 0 : 1)
