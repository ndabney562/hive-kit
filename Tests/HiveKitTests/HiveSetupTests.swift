import Foundation
import Testing
@testable import HiveKit

struct HiveSetupTests {
    let steps = [
        SetupStep(id: "github", title: "Sign in to GitHub", why: "The app reads today's plan from your repo.",
                  required: true, action: "Sign in"),
        SetupStep(id: "alerts", title: "Allow notifications", why: "Briefings and nudges ring with sound.",
                  permission: "iOS asks: Allow notifications?", action: "Allow"),
        SetupStep(id: "icloud", title: "Check iCloud", why: "Ticks sync between this iPhone and the Mac.",
                  action: "Check"),
    ]

    func defaults() -> UserDefaults {
        let name = "setup-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func stepsRunInOrderWithProgress() {
        var s = HiveSetup(steps: steps)
        #expect(s.current?.id == "github")
        #expect(s.progressText == "Step 1 of 3")
        #expect(s.fraction == 0)
        s.markDone("github")
        #expect(s.progressText == "Step 2 of 3")
        s.skip("alerts")
        s.markDone("icloud")
        #expect(s.finished)
        #expect(s.progressText == "All set")
        #expect(s.fraction == 1)
    }

    @Test func aRequiredStepCannotBeSkipped() {
        var s = HiveSetup(steps: steps)
        s.skip("github")
        #expect(s.current?.id == "github")
    }

    @Test func interruptedSetupResumesWhereItStopped() {
        let d = defaults()
        #expect(!HiveSetup.started(app: "hive-tempo", defaults: d))
        var s = HiveSetup.load(app: "hive-tempo", steps: steps, defaults: d)
        #expect(s.resumeNote == nil)
        s.markDone("github")
        s.save(app: "hive-tempo", defaults: d)
        // The app quits here; the next launch reads the saved progress.
        let back = HiveSetup.load(app: "hive-tempo", steps: steps, defaults: d)
        #expect(HiveSetup.started(app: "hive-tempo", defaults: d))
        #expect(back.current?.id == "alerts")
        #expect(back.resumeNote == "Welcome back: 1 of 3 done. Pick up where you left off.")
        // Signed out before relaunching: nothing is left done, so no "0 of 3 done".
        var out = back
        out.sync(["github": false])
        #expect(out.resumeNote == nil)
    }

    @Test func theDevicesRealStateMarksAndReopensSteps() {
        var s = HiveSetup(steps: steps)
        s.skip("alerts")
        s.sync(["github": true, "icloud": true, "unknown": true])
        #expect(s.finished)
        #expect(s.state("alerts") == .skipped)
        s.sync(["github": false, "alerts": false])  // signed out since
        #expect(s.current?.id == "github")
        #expect(s.state("alerts") == .skipped)
    }

    @Test func savedEntriesForStepsThatAreGoneAreDropped() {
        let d = defaults()
        d.set(["old": "done", "github": "nonsense", "alerts": "skipped"], forKey: HiveSetup.key(app: "x"))
        let s = HiveSetup.load(app: "x", steps: steps, defaults: d)
        #expect(s.states == ["alerts": .skipped])
    }

    @Test func theCheckFindsBadSteps() {
        #expect(HiveSetup.problems(steps).isEmpty)
        let bad = [SetupStep(id: "a", title: "", why: "short", permission: " ", action: "A very long button title"),
                   SetupStep(id: "a", title: "T", why: "A reason that is long enough here.", action: "Go")]
        #expect(HiveSetup.problems(bad) == ["a: no title", "a: say why in a sentence", "a: permission text is empty",
                                            "a: button title should be 1-16 characters", "a: id used twice"])
        #expect(HiveSetup.problems([]) == ["no steps"])
    }
}
