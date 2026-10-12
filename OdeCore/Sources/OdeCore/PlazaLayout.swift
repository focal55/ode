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
