# Plaza Core (Step 4a) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the two pure decisions the Plaza draws from: where each person stands (`PlazaLayout`) and what the headline says (`PlazaHeadline`). Both are fully tested before any scene code exists.

**Architecture:** Both live in OdeCore with no UI imports, following the spec's rule that "the scene draws state and never decides anything". `PlazaLayout` turns tracked people plus the ranked waiting list into prominence and world positions on arcs in front of the camera. `PlazaHeadline` turns the same waiting list plus today's kept events into one or two sentences.

**Tech Stack:** Swift 6, OdeCore Swift package, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-11-lantern-plaza-design.md` (OdeCore section `PlazaLayout`, the Kept section's headline copy, Testing). Spike carry-overs: `docs/superpowers/spikes/2026-10-11-realitykit-spike-findings.md`.

## How step 4 is split

Step 4 ("The Plaza as home") is three plans, each mergeable and verifiable on its own:

- **4a (this plan): Plaza core.** `PlazaLayout` and `PlazaHeadline` in OdeCore, test-first. Nothing visible changes.
- **4b: The scene as home.** `PlazaScene`, a `RealityView` built to the spike's findings. It shows lanterns from `PlazaLayout`, projected labels, the camera rig, flights, water, reflections and custom bloom. `PlazaView` becomes home behind the `plazaHome` setting (on by default for Joe). Clicking or voice-routing to a person flies there and opens the existing composer in a right-hand panel.
- **4c: The finished plaza.**
  - `ReplyPanel` with the spec's contents.
  - The headline, and Ode's own mark.
  - The kept animation: the mark closes, turns blue, a ring pulses and the lantern drifts back.
  - Hover context lines.
  - Keyboard navigation, VoiceOver and Reduce Motion.
  - Pausing rendering when the window is hidden.

Decisions taken for all three, for Joe to confirm with this plan:

- **Groups are one lantern each until step 5.** The spec's constellations (member lights joined by threads) are step 5 polish. Until then, a group stands in the plaza like a person, with a monogram. A group with an unanswered message therefore never disappears from home.
- **The loop mark is drawn in SwiftUI, projected like the labels**, not as a shader on a 3D plane. It needs the same `close` and `blue` inputs, faces the camera just as well, and is crisp at every size. It also lets one `LoopMark` shape serve both the lanterns and Ode's own mark.
- **Dusk is fixed until step 5.** `Daylight` (time-of-day lighting) belongs to step 5 polish, as the build order already says.
- **The reply panel wraps the existing `DraftComposerView`** for the draft, chips and actions, instead of rebuilding them. The spec's panel contents largely are the composer. Duplicating it would fork drafting logic that already works and is verified.
- **`PlazaLayout` takes no `kept` input.** A kept send clears that person's waiting item, which already moves them to `around`. The drift-back animation is 4c's job. The spec's `compute(people:waiting:kept:now:)` signature becomes `compute(people:waiting:)`.

## Global Constraints

- The scene draws state and never decides anything. All decisions live in OdeCore as pure, tested code.
- Prominence: `asked` / `unanswered` / `promised` waiting kinds map to `owed`; `quiet` maps to `quiet`; tracked with nothing waiting maps to `around`; beyond the 40 most recent `around` people maps to `horizon`.
- Position is seeded from the conversation id, so a person keeps the same angle across launches. Prominence sets depth: `owed` is near, `quiet` is middle, `around` is back, `horizon` is on the horizon line.
- Lanterns at the same depth keep a minimum angular separation, so labels never overlap.
- Headline copy, verbatim from the spec: "Three people would love to hear from you." / "Start with Maya. …" / "One more." / "Everyone's heard from you." No scores, no streaks, no guilt.
- Tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore` (the suite is 245 tests on main today).
- No emojis; comments only where the why is non-obvious; conventional commits.

## Review Focus

- **More owed people than fit in one arc.** Joe has 7 waiting today, and one arc holds about 4. The overflow must wrap into a row further back and higher, never pile up on the same spot or leave the screen. Pinned by `overflowWrapsIntoARowFurtherBackAndHigher` (Task 1).
- **Seeds that clump at one edge of the arc.** Relaxing them must not push a lantern outside the visible arc. Pinned by `everyoneStaysInsideTheVisibleArc` with ids chosen to clump (Task 1).
- **A waiting item for a conversation that isn't tracked.** The layout ignores it, and the headline doesn't count or name it. Pinned in both tasks.
- **People with no last-message date** sort as the oldest for the 40 cap, rather than crashing or sorting first. Pinned by `aroundBeyondTheFortyMostRecentGoesToTheHorizon` (Task 1).
- **A group conversation in the headline.** Its title isn't a person's name, so it isn't cut to a first name ("Start with Book Club Crew.", never "Start with Book."). Pinned by `groupsAreNamedByTheirTitle` (Task 2).

---

### Task 1: PlazaLayout

**Files:**
- Create: `OdeCore/Sources/OdeCore/PlazaLayout.swift`
- Create: `OdeCore/Tests/OdeCoreTests/PlazaLayoutTests.swift`

**Interfaces:**
- Consumes: `Waiting` (`conversationID: Int64`, `kind: Waiting.Kind` with cases `.asked`, `.unanswered`, `.promised`, `.quiet`), already in OdeCore.
- Produces:
  - `PlazaLayout.Prominence` (`.owed`, `.quiet`, `.around`, `.horizon`; `Comparable`).
  - `PlazaLayout.Person(id: Int64, lastActive: Date?)`.
  - `PlazaLayout.Placement` (`conversationID: Int64`, `prominence: Prominence`, `position: SIMD3<Float>`, `id: Int64`).
  - `PlazaLayout.viewpoint: SIMD3<Float>` = `(0, 0, 7)`, the ground point under the camera.
  - `PlazaLayout.compute(people: [Person], waiting: [Waiting]) -> [Placement]`.
  - `PlazaLayout.readingOrder(_ placements: [Placement]) -> [Int64]`.
  - `PlazaLayout.aroundCap` = 40.

The world: the camera stands above `viewpoint` looking toward −z. Each prominence is an arc around `viewpoint` at its own radius, inside a horizontal half-span the camera can see, at its own height. People who don't fit in one arc wrap into further rows, each one step further back and a little higher, with odd rows offset by half a gap. Within a row, people are spread by their seeded angle, then relaxed so neighbours are at least `gap` apart without leaving the half-span.

Owed and quiet rows fill in the waiting list's order (already ranked, most urgent first), so the most urgent person is always in the front row. Around rows fill most recent first.

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter PlazaLayoutTests`
Expected: compile failure, "cannot find 'PlazaLayout' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Where each person stands in the Plaza. The scene draws these placements and decides nothing itself.
public enum PlazaLayout {
    public enum Prominence: Int, Sendable, Comparable, CaseIterable {
        case owed, quiet, around, horizon

        public static func < (lhs: Prominence, rhs: Prominence) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Person: Sendable, Equatable {
        public let id: Int64
        public let lastActive: Date?

        public init(id: Int64, lastActive: Date?) {
            self.id = id
            self.lastActive = lastActive
        }
    }

    public struct Placement: Sendable, Equatable, Identifiable {
        public let conversationID: Int64
        public let prominence: Prominence
        public let position: SIMD3<Float>
        public var id: Int64 { conversationID }
    }

    /// One prominence's arc around the viewpoint. Angles are radians from straight ahead.
    public struct Ring: Sendable {
        public let radius: Double
        public let halfSpan: Double
        public let height: Double
        public let gap: Double
        public let rowStep: Double
        public let rowLift: Double

        public var capacity: Int { Int((2 * halfSpan / gap).rounded(.down)) + 1 }
    }

    /// The ground point under the camera, which looks toward -z.
    public static let viewpoint = SIMD3<Float>(0, 0, 7)
    public static let aroundCap = 40

    /// Gaps are about a lantern's width plus its label at that distance; half-spans stay inside the camera's view.
    public static func ring(_ prominence: Prominence) -> Ring {
        switch prominence {
        case .owed: Ring(radius: 6, halfSpan: 0.42, height: 1.2, gap: 0.27, rowStep: 2, rowLift: 0.45)
        case .quiet: Ring(radius: 9.5, halfSpan: 0.45, height: 1.4, gap: 0.15, rowStep: 2.5, rowLift: 0.5)
        case .around: Ring(radius: 13, halfSpan: 0.48, height: 1.7, gap: 0.085, rowStep: 3, rowLift: 0.6)
        case .horizon: Ring(radius: 60, halfSpan: 0.5, height: 1.6, gap: 0.02, rowStep: 6, rowLift: 0.4)
        }
    }

    public static func compute(people: [Person], waiting: [Waiting]) -> [Placement] {
        let tracked = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int64>()
        var owed: [Int64] = []
        var quiet: [Int64] = []
        for item in waiting where tracked[item.conversationID] != nil && seen.insert(item.conversationID).inserted {
            if item.kind == .quiet { quiet.append(item.conversationID) } else { owed.append(item.conversationID) }
        }
        let rest = people.filter { !seen.contains($0.id) }.sorted {
            ($0.lastActive ?? .distantPast, $1.id) > ($1.lastActive ?? .distantPast, $0.id)
        }.map(\.id)
        return arrange(owed, .owed) + arrange(quiet, .quiet) + arrange(Array(rest.prefix(aroundCap)), .around)
            + arrange(Array(rest.dropFirst(aroundCap)), .horizon)
    }

    /// Owed people first, then each prominence's rows front to back, each row left to right.
    public static func readingOrder(_ placements: [Placement]) -> [Int64] {
        placements.sorted { ($0.prominence, row($0), $0.position.x) < ($1.prominence, row($1), $1.position.x) }
            .map(\.conversationID)
    }

    /// Distance from the viewpoint to the nearest metre. Rows are at least two metres apart, and z alone would
    /// interleave an arc's edges with its middle.
    private static func row(_ placement: Placement) -> Float {
        let offset = placement.position - viewpoint
        return (offset.x * offset.x + offset.z * offset.z).squareRoot().rounded()
    }

    private static func arrange(_ ids: [Int64], _ prominence: Prominence) -> [Placement] {
        let ring = ring(prominence)
        return stride(from: 0, to: ids.count, by: ring.capacity).enumerated().flatMap { row, start in
            let members = ids[start..<min(start + ring.capacity, ids.count)]
            let offset = row.isMultiple(of: 2) ? 0 : ring.gap / 2
            let seeded = members.map { ($0, (unit($0) * 2 - 1) * ring.halfSpan + offset) }.sorted { $0.1 < $1.1 }
            let angles = relax(seeded.map(\.1), ring: ring)
            let radius = ring.radius + Double(row) * ring.rowStep
            let height = Float(ring.height + Double(row) * ring.rowLift)
            return zip(seeded, angles).map { member, angle in
                Placement(conversationID: member.0, prominence: prominence,
                          position: SIMD3(viewpoint.x + Float(radius * sin(angle)), height,
                                          viewpoint.z - Float(radius * cos(angle))))
            }
        }
    }

    /// Pushes neighbours apart left to right, then pulls them back inside the right edge. A row never holds more than
    /// `capacity`, so the left edge holds too.
    private static func relax(_ seeds: [Double], ring: Ring) -> [Double] {
        var angles = seeds.map { min(max($0, -ring.halfSpan), ring.halfSpan) }
        for index in angles.indices.dropFirst() { angles[index] = max(angles[index], angles[index - 1] + ring.gap) }
        for index in angles.indices.reversed() {
            let limit = index == angles.count - 1 ? ring.halfSpan : angles[index + 1] - ring.gap
            angles[index] = min(angles[index], limit)
        }
        return angles
    }

    /// A stable value in [0, 1) from a conversation id (splitmix64), so a person keeps their angle across launches.
    static func unit(_ id: Int64) -> Double {
        var z = UInt64(bitPattern: id) &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(UInt64(1) << 53)
    }
}
```

The `readingOrder` tuple comparison uses `Prominence` as its first element. Swift compares tuples whose elements are all `Comparable`, so this works.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter PlazaLayoutTests`
Expected: all 10 tests pass.

If `everyoneStaysInsideTheVisibleArc` fails on the left edge, the cause is an odd row's half-gap offset pushing its first seed past `-halfSpan`. That's already handled by the clamp at the top of `relax`. Check the clamp runs before the forward sweep.

- [ ] **Step 5: Run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore`
Expected: 255 tests pass (245 plus 10).

- [ ] **Step 6: Commit**

```bash
git add OdeCore/Sources/OdeCore/PlazaLayout.swift OdeCore/Tests/OdeCoreTests/PlazaLayoutTests.swift
git commit -m "feat(core): where each person stands in the plaza"
```

---

### Task 2: PlazaHeadline

**Files:**
- Create: `OdeCore/Sources/OdeCore/PlazaHeadline.swift`
- Create: `OdeCore/Tests/OdeCoreTests/PlazaHeadlineTests.swift`

**Interfaces:**
- Consumes: `Waiting` (`conversationID`), `Kept` (`sentAt: Date`), `OdeLines.firstName(_:)`.
- Produces: `PlazaHeadline.Line` (`title: String`, `subtitle: String?`) and `PlazaHeadline.make(waiting: [Waiting], titles: [Int64: String], groups: Set<Int64>, kept: [Kept], now: Date, calendar: Calendar) -> Line`.

The headline's rules:

| Waiting (tracked) | Kept today | Title | Subtitle |
|---|---|---|---|
| 0 | any | "Everyone's heard from you." | none |
| 1 | 0 | "Maya would love to hear from you." | none |
| 1 | 1 or more | "One more." | "Maya would love to hear from you." |
| 2 to 10 | any | "Three people would love to hear from you." | "Start with Maya." |
| more than 10 | any | "12 people would love to hear from you." | "Start with Maya." |

"Maya" is the first waiting item's name. A person is named by first name; a group by its full title. Waiting items for conversations without a title (untracked) are neither counted nor named. Kept today means `sentAt` falls on `now`'s calendar day.

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import OdeCore

@Suite struct PlazaHeadlineTests {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    // Thursday 2026-10-15, 10:00 UTC.
    let now = Date(timeIntervalSince1970: 1_792_058_400)
    let titles: [Int64: String] = [1: "Maya Chen", 2: "Sam Ortiz", 3: "Priya", 4: "Book Club Crew", 5: "Dev", 6: "Ana", 7: "Bo",
                                   8: "Cy", 9: "Di", 10: "Ed", 11: "Flo", 12: "Gus"]

    func waiting(_ ids: [Int64]) -> [Waiting] {
        ids.map { Waiting(conversationID: $0, kind: .asked, text: "", steer: "", since: now, newestMessageID: 1) }
    }

    func kept(hoursAgo: Double) -> Kept {
        Kept(conversationID: 9, handoffAt: now.addingTimeInterval(-hoursAgo * 3_600 - 60),
             sentAt: now.addingTimeInterval(-hoursAgo * 3_600), messageID: 1)
    }

    func line(_ ids: [Int64], kept: [Kept] = [], groups: Set<Int64> = []) -> PlazaHeadline.Line {
        PlazaHeadline.make(waiting: waiting(ids), titles: titles, groups: groups, kept: kept, now: now, calendar: calendar)
    }

    @Test func nobodyWaiting() {
        #expect(line([]) == .init(title: "Everyone's heard from you.", subtitle: nil))
        #expect(line([], kept: [kept(hoursAgo: 1)]) == .init(title: "Everyone's heard from you.", subtitle: nil))
    }

    @Test func oneWaitingNamesThem() {
        #expect(line([1]) == .init(title: "Maya would love to hear from you.", subtitle: nil))
    }

    @Test func oneLeftAfterKeepingSomeoneToday() {
        #expect(line([1], kept: [kept(hoursAgo: 2)]) == .init(title: "One more.", subtitle: "Maya would love to hear from you."))
    }

    @Test func keptYesterdayDoesNotCount() {
        #expect(line([1], kept: [kept(hoursAgo: 11)]) == .init(title: "Maya would love to hear from you.", subtitle: nil))
    }

    @Test func severalWaitingAreCountedInWords() {
        #expect(line([2, 1, 3]) == .init(title: "Three people would love to hear from you.", subtitle: "Start with Sam."))
        #expect(line(Array(1...10)) == .init(title: "Ten people would love to hear from you.", subtitle: "Start with Maya."))
    }

    @Test func moreThanTenUseDigits() {
        #expect(line(Array(1...12)).title == "12 people would love to hear from you.")
    }

    @Test func groupsAreNamedByTheirTitle() {
        #expect(line([4, 1], groups: [4]).subtitle == "Start with Book Club Crew.")
    }

    @Test func untrackedConversationsAreNotCountedOrNamed() {
        #expect(line([99, 1]) == .init(title: "Maya would love to hear from you.", subtitle: nil))
    }
}
```

`keptYesterdayDoesNotCount` uses 11 hours before 10:00 UTC Thursday, which is 23:00 Wednesday.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter PlazaHeadlineTests`
Expected: compile failure, "cannot find 'PlazaHeadline' in scope".

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The Plaza's headline: who would love to hear from you, without scores, streaks or guilt.
public enum PlazaHeadline {
    public struct Line: Sendable, Equatable {
        public let title: String
        public let subtitle: String?

        public init(title: String, subtitle: String?) {
            self.title = title
            self.subtitle = subtitle
        }
    }

    public static func make(waiting: [Waiting], titles: [Int64: String], groups: Set<Int64>, kept: [Kept], now: Date,
                            calendar: Calendar = .current) -> Line {
        let names = waiting.compactMap { item in
            titles[item.conversationID].map { groups.contains(item.conversationID) ? $0 : OdeLines.firstName($0) }
        }
        guard let first = names.first else { return Line(title: "Everyone's heard from you.", subtitle: nil) }
        guard names.count > 1 else {
            let keptToday = kept.contains { calendar.isDate($0.sentAt, inSameDayAs: now) }
            let line = "\(first) would love to hear from you."
            return keptToday ? Line(title: "One more.", subtitle: line) : Line(title: line, subtitle: nil)
        }
        return Line(title: "\(count(names.count)) people would love to hear from you.", subtitle: "Start with \(first).")
    }

    private static func count(_ number: Int) -> String {
        let words = ["Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"]
        return (2...10).contains(number) ? words[number - 2] : String(number)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore --filter PlazaHeadlineTests`
Expected: all 8 tests pass.

- [ ] **Step 5: Run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path OdeCore`
Expected: 263 tests pass.

- [ ] **Step 6: Commit**

```bash
git add OdeCore/Sources/OdeCore/PlazaHeadline.swift OdeCore/Tests/OdeCoreTests/PlazaHeadlineTests.swift
git commit -m "feat(core): the plaza headline"
```
