import Foundation
import Testing
@testable import HiveKit

struct IncomeGoalTests {
    func business(_ income: [String: Any]?) throws -> BusinessSummary {
        var summary: [String: Any] = ["day": 9, "days_total": 90, "ends": "2027-02-06", "earned_usd": 19.24,
                                      "routes": [] as [Any], "next_checkpoint": NSNull()]
        if let income { summary["income"] = income }
        let doc: [String: Any] = ["schema": 1, "app": "ai-business-db", "written_at": "2026-11-17T17:00:00Z",
                                  "stale_after_minutes": 360, "summary": summary]
        return try #require(try HiveFeed.decode(JSONSerialization.data(withJSONObject: doc), as: BusinessSummary.self)).summary
    }

    let november: [String: Any] = [
        "net_usd": 19.24, "month_net_usd": 19.24, "pending_usd": 19.24, "sales": 3,
        "by_route": ["Dink & Paw": 11.0, "Notion templates": 8.24],
        "month": "2026-11", "month_by_route": ["Dink & Paw": 11.0, "Notion templates": 8.24], "goal_usd": 100.0,
        "last_sale": ["date": "2026-11-16", "route": "Notion templates", "item": "MCAT planner", "net_usd": 8.24],
    ]

    @Test func decodesIncomeBlock() throws {
        let income = try #require(try business(november).income)
        #expect(income.monthNetUsd == 19.24)
        #expect(income.sales == 3)
        #expect(income.monthByRoute?["Notion templates"] == 8.24)
        #expect(income.lastSale?.route == "Notion templates")
    }

    @Test func decodesPayouts() throws {
        var income = november
        income["payouts"] = ["next": ["date": "2026-11-27", "usd": 34.89], "waiting_usd": 66.65, "paid_usd": 0,
                             "overdue": [["date": "2026-11-20", "route": "Clipping", "usd": 5.0]], "overdue_usd": 5.0]
        let p = try #require(try business(income).income?.payouts)
        #expect(p.next == .init(date: "2026-11-27", usd: 34.89))
        #expect(p.waitingUsd == 66.65)
        #expect(p.overdue.first?.route == "Clipping")
        #expect(p.overdueUsd == 5.0)
        #expect(try business(november).income?.payouts == nil, "older feeds have no payouts")
    }

    @Test func decodesBudget() throws {
        var summary: [String: Any] = ["day": 9, "days_total": 90, "ends": "2027-02-06", "earned_usd": 19.24,
                                      "routes": [] as [Any], "next_checkpoint": NSNull()]
        summary["budget"] = ["month_usd": 158.25, "estimates": 1,
                             "items": [["name": "Claude Max", "usd_month": 125.0, "estimate": false],
                                       ["name": "Apple Developer Program", "usd_month": 8.25, "estimate": true]],
                             "credit": [["project": "HiveMind", "allot_usd": 25.0, "used_usd": 9.17],
                                        ["project": "AI business", "allot_usd": 50.0, "used_usd": NSNull()]]]
        let doc: [String: Any] = ["schema": 1, "app": "ai-business-db", "written_at": "2026-11-17T17:00:00Z",
                                  "stale_after_minutes": 360, "summary": summary]
        let b = try #require(try HiveFeed.decode(JSONSerialization.data(withJSONObject: doc), as: BusinessSummary.self)?.summary.budget)
        #expect(b.monthUsd == 158.25)
        #expect(b.items.last?.estimate == true)
        #expect(b.credit.first?.usedUsd == 9.17)
        #expect(b.credit.last?.usedUsd == nil)
        #expect(try business(november).budget == nil, "older feeds have no budget")
    }

    @Test func bestRouteMeasuredAgainstGoal() throws {
        let goal = try #require(IncomeGoal(try business(november)))
        #expect(goal.month == "2026-11")
        #expect(goal.bestRoute == "Dink & Paw")
        #expect(goal.best == 11.0)
        #expect(goal.goal == 100)
        #expect(goal.met == false)
        #expect(abs(goal.progress - 0.11) < 0.0001)
        #expect(abs(goal.left - 89.0) < 0.0001)
        #expect(goal.monthNet == 19.24)
    }

    @Test func metAndCappedAtOne() throws {
        var dec = november
        dec["month"] = "2026-12"
        dec["month_by_route"] = ["Dink & Paw": 130.0, "Clipping": 5.0]
        let goal = try #require(IncomeGoal(try business(dec)))
        #expect(goal.met)
        #expect(goal.progress == 1)
        #expect(goal.left == 0)
        #expect(goal.bestRoute == "Dink & Paw")
    }

    @Test func emptyMonthHasNoBestRoute() throws {
        var dec = november
        dec["month_by_route"] = [String: Double]()
        let goal = try #require(IncomeGoal(try business(dec)))
        #expect(goal.bestRoute == nil)
        #expect(goal.best == 0)
        #expect(goal.progress == 0)
    }

    @Test func olderFeedsHaveNoGoal() throws {
        #expect(IncomeGoal(try business(nil)) == nil)
        var old = november
        old.removeValue(forKey: "month_by_route")
        #expect(try business(old).income?.netUsd == 19.24)
        #expect(IncomeGoal(try business(old)) == nil)
    }
}
