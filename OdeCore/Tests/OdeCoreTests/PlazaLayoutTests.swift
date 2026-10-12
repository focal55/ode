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

    /// Physical sizes as the scene will draw them, independent of the layout's own padded constants: a lantern's radius
    /// in metres, and a label's angular half-size, hanging 0.7 m below the lantern, seen from 1.6 m up.
    func boxes(_ p: PlazaLayout.Placement) -> [(az: Double, el: Double, w: Double, h: Double)] {
        let (az, r) = polar(p)
        let size: Double = [.owed: 0.5, .quiet: 0.4, .around: 0.3, .horizon: 0.1][p.prominence]!
        let lantern = (az, atan(Double(p.position.y - 1.6) / r), size / r, size / r)
        guard p.prominence != .horizon else { return [lantern] }
        return [lantern, (az, atan(Double(p.position.y - 0.7 - 1.6) / r), 0.04, 0.012)]
    }

    @Test(arguments: [(7, 12, 60), (12, 0, 20), (3, 3, 45), (1, 0, 1), (9, 9, 80)])
    func nothingHidesBehindAnotherLanternOrLabel(owed: Int, quiet: Int, tracked: Int) {
        for scale in [1, 7_919, 104_729] as [Int64] {
            let people = (1...tracked).map { person(Int64($0) * scale, daysAgo: Double($0)) }
            let waits = (1...max(1, owed + quiet)).filter { $0 <= owed + quiet }
                .map { waiting(Int64($0) * scale, $0 <= owed ? .asked : .quiet) }
            let placements = PlazaLayout.compute(people: people, waiting: waits)
            let named: Set<PlazaLayout.Prominence> = [.owed, .quiet]
            for (index, a) in placements.enumerated() {
                for b in placements.dropFirst(index + 1) {
                    // Named people never hide each other or each other's labels. Unnamed lights only keep apart
                    // from their own kind; sitting behind a named lantern is ordinary depth.
                    let both = named.contains(a.prominence) && named.contains(b.prominence)
                    guard both || a.prominence == b.prominence else { continue }
                    let clash = boxes(a).prefix(both ? 2 : 1).contains { x in
                        boxes(b).prefix(both ? 2 : 1).contains { y in
                            abs(x.az - y.az) < x.w + y.w && abs(x.el - y.el) < x.h + y.h
                        }
                    }
                    #expect(!clash, "\(a.conversationID) and \(b.conversationID) overlap")
                }
                // Inside a level 40 degree view at 16:10: about 0.35 rad up or down, 0.52 rad left or right.
                for box in boxes(a) where named.contains(a.prominence) {
                    #expect(abs(box.el) + box.h <= 0.35 && abs(box.az) + box.w <= 0.52, "\(a.conversationID) is off screen")
                }
            }
        }
    }

    @Test func seedsAreTheSameOnEveryLaunch() {
        #expect(PlazaLayout.unit(1) == 0.5665615751722809)
    }

    @Test func aNewcomerInYourRingDoesNotMoveYou() {
        let before = PlazaLayout.compute(people: [person(1), person(2)], waiting: [waiting(1, .quiet)])
        let after = PlazaLayout.compute(people: [person(1), person(2)], waiting: [waiting(1, .quiet), waiting(2, .quiet)])
        #expect(before.first { $0.conversationID == 1 } == after.first { $0.conversationID == 1 })
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
        let people = (1...9).map { person(Int64($0)) }
        let placements = PlazaLayout.compute(people: people, waiting: (1...9).map { waiting(Int64($0), .asked) })
        let byID = Dictionary(uniqueKeysWithValues: placements.map { ($0.conversationID, $0) })
        let rows = (1...9).map { byID[Int64($0)]!.row }
        #expect(rows.max()! >= 1)
        #expect(rows == rows.sorted(), "a more urgent person stands behind a less urgent one")
        let front = placements.filter { $0.row == 0 }
        let back = placements.filter { $0.row > 0 }
        #expect(back.allSatisfy { b in front.allSatisfy { b.position.y > $0.position.y && polar(b).radius > polar($0).radius } })
    }

    @Test func quietRowReadsLeftToRight() {
        let placements = PlazaLayout.compute(people: [person(1), person(47)], waiting: [waiting(1, .quiet), waiting(47, .quiet)])
        #expect(PlazaLayout.readingOrder(placements) == placements.sorted { $0.position.x < $1.position.x }.map(\.conversationID))
    }

    @Test func readingOrderTakesTheFrontRowBeforeTheBackRow() {
        let people = (1...9).map { person(Int64($0)) }
        let placements = PlazaLayout.compute(people: people, waiting: (1...9).map { waiting(Int64($0), .asked) })
        let expected = placements.sorted { ($0.row, $0.position.x) < ($1.row, $1.position.x) }.map(\.conversationID)
        #expect(PlazaLayout.readingOrder(placements) == expected)
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
