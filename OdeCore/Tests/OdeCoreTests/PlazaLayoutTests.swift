import Foundation
import Testing
@testable import OdeCore

@Suite struct PlazaLayoutTests {
    let now = Date(timeIntervalSince1970: 1_792_058_400)

    func person(_ id: Int64, daysAgo: Double? = 1) -> PlazaLayout.Person {
        PlazaLayout.Person(id: id, lastActive: daysAgo.map { now.addingTimeInterval(-$0 * 86_400) })
    }

    func waiting(_ id: Int64, _ kind: Waiting.Kind) -> Waiting {
        Waiting(conversationID: id, kind: kind, text: "", steer: "", since: now, newestMessageID: 1)
    }

    /// Angle from straight ahead, and distance from the viewpoint, of a placement.
    func polar(_ placement: PlazaLayout.Placement) -> (angle: Double, radius: Double) {
        let dx = Double(placement.position.x - PlazaLayout.viewpoint.x)
        let dz = Double(PlazaLayout.viewpoint.z - placement.position.z)
        return (atan2(dx, dz), (dx * dx + dz * dz).squareRoot())
    }

    @Test func prominenceFollowsWhatTheyAreWaitingFor() {
        let people = (1...5).map { person(Int64($0)) }
        let placements = PlazaLayout.compute(people: people, waiting: [
            waiting(1, .asked), waiting(2, .unanswered), waiting(3, .promised), waiting(4, .quiet),
        ])
        let prominence = Dictionary(uniqueKeysWithValues: placements.map { ($0.conversationID, $0.prominence) })
        #expect(prominence == [1: .owed, 2: .owed, 3: .owed, 4: .quiet, 5: .around])
    }

    @Test func waitingForAnUntrackedConversationIsIgnored() {
        let placements = PlazaLayout.compute(people: [person(1)], waiting: [waiting(99, .asked)])
        #expect(placements.map(\.conversationID) == [1])
        #expect(placements[0].prominence == .around)
    }

    @Test func theSameInputGivesTheSamePositions() {
        let people = (1...12).map { person(Int64($0) * 7_919) }
        let waits = [waiting(7_919, .asked), waiting(15_838, .quiet)]
        #expect(PlazaLayout.compute(people: people, waiting: waits) == PlazaLayout.compute(people: people, waiting: waits))
    }

    @Test func someoneElsesChangeDoesNotMoveYou() {
        let before = PlazaLayout.compute(people: [person(1), person(2)], waiting: [waiting(1, .asked)])
        let after = PlazaLayout.compute(people: [person(1), person(2), person(3)], waiting: [waiting(1, .asked)])
        #expect(before.first { $0.conversationID == 1 } == after.first { $0.conversationID == 1 })
    }

    @Test func owedStandsNearestThenQuietThenAroundThenHorizon() {
        var people = [person(1), person(2), person(3)]
        people += (10..<52).map { person(Int64($0), daysAgo: Double($0)) }
        let placements = PlazaLayout.compute(people: people, waiting: [waiting(1, .asked), waiting(2, .quiet)])
        let nearest = Dictionary(grouping: placements, by: \.prominence).mapValues { $0.map { polar($0).radius }.min()! }
        #expect(nearest[.owed]! < nearest[.quiet]!)
        #expect(nearest[.quiet]! < nearest[.around]!)
        #expect(nearest[.around]! < nearest[.horizon]!)
    }

    @Test func aroundBeyondTheFortyMostRecentGoesToTheHorizon() {
        var people = (1...44).map { person(Int64($0), daysAgo: Double($0)) }
        people.append(person(45, daysAgo: nil))
        let placements = PlazaLayout.compute(people: people, waiting: [])
        let horizon = Set(placements.filter { $0.prominence == .horizon }.map(\.conversationID))
        #expect(horizon == [41, 42, 43, 44, 45])
    }

    @Test func lanternsInARowKeepTheirDistance() {
        let people = (1...30).map { person(Int64($0) * 104_729) }
        let placements = PlazaLayout.compute(people: people, waiting: [])
        let rows = Dictionary(grouping: placements.map(polar), by: { ($0.radius * 10).rounded() })
        for row in rows.values {
            let angles = row.map(\.angle).sorted()
            for (left, right) in zip(angles, angles.dropFirst()) {
                #expect(right - left >= PlazaLayout.ring(.around).gap - 1e-4)
            }
        }
    }

    @Test func everyoneStaysInsideTheVisibleArc() {
        // Consecutive ids give clumped seeds often enough to exercise the relaxation at the edges.
        let people = (1...60).map { person(Int64($0), daysAgo: Double($0)) }
        let waits = (1...9).map { waiting(Int64($0), $0 % 3 == 0 ? .quiet : .asked) }
        for placement in PlazaLayout.compute(people: people, waiting: waits) {
            #expect(abs(polar(placement).angle) <= PlazaLayout.ring(placement.prominence).halfSpan + 1e-4)
        }
    }

    @Test func overflowWrapsIntoARowFurtherBackAndHigher() {
        let people = (1...7).map { person(Int64($0)) }
        let placements = PlazaLayout.compute(people: people, waiting: (1...7).map { waiting(Int64($0), .asked) })
        let capacity = PlazaLayout.ring(.owed).capacity
        let front = placements.filter { polar($0).radius < PlazaLayout.ring(.owed).radius + 0.5 }
        let back = placements.filter { polar($0).radius >= PlazaLayout.ring(.owed).radius + 0.5 }
        #expect(front.count == capacity)
        #expect(back.count == 7 - capacity)
        #expect(back.allSatisfy { b in front.allSatisfy { b.position.y > $0.position.y } })
        // The most urgent people (first in the waiting list) are in the front row.
        #expect(Set(front.map(\.conversationID)) == Set((1...Int64(capacity)).map { $0 }))
    }

    @Test func readingOrderIsOwedFirstThenLeftToRight() {
        let people = (1...6).map { person(Int64($0) * 31) }
        let placements = PlazaLayout.compute(people: people, waiting: [waiting(31, .asked), waiting(62, .asked)])
        let order = PlazaLayout.readingOrder(placements)
        #expect(Set(order.prefix(2)) == [31, 62])
        let owed = placements.filter { $0.prominence == .owed }.sorted { $0.position.x < $1.position.x }
        #expect(Array(order.prefix(2)) == owed.map(\.conversationID))
        #expect(order.count == 6)
    }
}
