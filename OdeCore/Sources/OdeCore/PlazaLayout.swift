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
        public let row: Int
        public var id: Int64 { conversationID }
    }

    /// A row the plaza can hold: distance from the viewpoint and height above the water, in metres.
    public struct Tier: Sendable, Equatable {
        public let radius: Double
        public let height: Double
    }

    /// How one prominence is drawn: the rows it may stand in (front first), how far its edge may stray from straight
    /// ahead (the view is about 0.52 rad each side at 16:10), its size with a little clearance so neighbours never touch, and whether it carries a name label.
    public struct Ring: Sendable {
        public let tiers: [Tier]
        public let halfSpan: Double
        public let clearance: Double
        public let labelled: Bool
    }

    /// The ground point under the camera. The camera looks level toward -z from `eyeHeight` above it, with a 40 degree
    /// vertical field of view.
    public static let viewpoint = SIMD3<Float>(0, 0, 7)
    public static let eyeHeight = 1.6
    public static let aroundCap = 40
    /// Labels hang below each lantern and keep their size on screen, so they're measured as angles.
    static let labelDrop = 0.7
    static let labelHalfWidth = 0.045
    static let labelHalfHeight = 0.014

    /// Named rows rise as they recede, so each one's lanterns and labels clear the tops of the row in front: one
    /// level arc couldn't hold more than a handful of labelled people without hiding some behind others.
    static let namedTiers = [Tier(radius: 6, height: 1.2), Tier(radius: 9.5, height: 2.7), Tier(radius: 13, height: 4.8)]

    public static func ring(_ prominence: Prominence) -> Ring {
        switch prominence {
        case .owed: Ring(tiers: namedTiers, halfSpan: 0.5, clearance: 0.56, labelled: true)
        case .quiet: Ring(tiers: Array(namedTiers.dropFirst()), halfSpan: 0.5, clearance: 0.46, labelled: true)
        case .around:
            Ring(tiers: (0..<6).map { Tier(radius: 18, height: 1.9 + 0.6 * Double($0)) }, halfSpan: 0.5, clearance: 0.36,
                 labelled: false)
        case .horizon:
            Ring(tiers: (0..<6).map { Tier(radius: 60, height: 1.6 + 0.4 * Double($0)) }, halfSpan: 0.5, clearance: 0.12,
                 labelled: false)
        }
    }

    /// Each row is divided into slots one lantern-or-label wide, so rows pack fully instead of fragmenting. Everyone
    /// is placed in turn, most urgent first: in the free slot nearest their seeded angle, otherwise in the next row
    /// back. Named people clear every
    /// named lantern and label; unnamed lights only clear each other and may sit behind named ones. So a person keeps
    /// their angle across launches unless someone placed before them needs that spot.
    public static func compute(people: [Person], waiting: [Waiting]) -> [Placement] {
        var tracked: [Int64: Person] = [:]
        let unique = people.filter { tracked.updateValue($0, forKey: $0.id) == nil }
        var seen = Set<Int64>()
        var queue: [(Int64, Prominence)] = []
        for item in waiting where tracked[item.conversationID] != nil && seen.insert(item.conversationID).inserted {
            queue.append((item.conversationID, item.kind == .quiet ? .quiet : .owed))
        }
        queue.sort { $0.1 < $1.1 }
        let rest = unique.filter { !seen.contains($0.id) }.sorted {
            ($0.lastActive ?? .distantPast, $1.id) > ($1.lastActive ?? .distantPast, $0.id)
        }.map(\.id)
        queue += rest.prefix(aroundCap).map { ($0, .around) } + rest.dropFirst(aroundCap).map { ($0, .horizon) }

        var placed: [Placement] = []
        var named: [Box] = []
        var lights: [Prominence: [Box]] = [:]
        for (id, prominence) in queue {
            let labelled = ring(prominence).labelled
            let placement = place(id, prominence, avoiding: labelled ? named : lights[prominence, default: []])
            placed.append(placement)
            if labelled { named += boxes(placement) } else { lights[prominence, default: []] += boxes(placement) }
        }
        return placed
    }

    /// Owed people first, then each prominence's rows front to back, each row left to right.
    public static func readingOrder(_ placements: [Placement]) -> [Int64] {
        placements.sorted { ($0.prominence, $0.row, $0.position.x) < ($1.prominence, $1.row, $1.position.x) }
            .map(\.conversationID)
    }

    /// A rectangle in view angles: azimuth and elevation from the eye, with half-sizes.
    struct Box {
        let azimuth: Double
        let elevation: Double
        let halfWidth: Double
        let halfHeight: Double

        func overlaps(_ other: Box) -> Bool {
            abs(azimuth - other.azimuth) < halfWidth + other.halfWidth
                && abs(elevation - other.elevation) < halfHeight + other.halfHeight
        }
    }

    private static func place(_ id: Int64, _ prominence: Prominence, avoiding taken: [Box]) -> Placement {
        let ring = ring(prominence)
        let seed = (unit(id) * 2 - 1) * ring.halfSpan
        for (row, tier) in ring.tiers.enumerated() {
            let slot = slotWidth(tier, ring)
            let reach = Int(((ring.halfSpan - ring.clearance / tier.radius) / slot).rounded(.down))
            let slots = (-reach...reach).map { Double($0) * slot }.sorted { (abs($0 - seed), $0) < (abs($1 - seed), $1) }
            for angle in slots {
                let candidate = placement(id, prominence, row: row, angle: angle)
                if !boxes(candidate).contains(where: { box in taken.contains { box.overlaps($0) } }) { return candidate }
            }
        }
        return placement(id, prominence, row: ring.tiers.count - 1, angle: seed)
    }

    /// Named rows share one lattice wide enough for the largest named lantern or a label, so owed and quiet people in
    /// the same row never half-overlap.
    private static func slotWidth(_ tier: Tier, _ ring: Ring) -> Double {
        let width = ring.labelled
            ? max(2 * Self.ring(.owed).clearance / tier.radius, 2 * labelHalfWidth)
            : 2 * ring.clearance / tier.radius
        return width * 1.02
    }

    private static func placement(_ id: Int64, _ prominence: Prominence, row: Int, angle: Double) -> Placement {
        let tier = ring(prominence).tiers[row]
        return Placement(conversationID: id, prominence: prominence,
                         position: SIMD3(viewpoint.x + Float(tier.radius * sin(angle)), Float(tier.height),
                                         viewpoint.z - Float(tier.radius * cos(angle))),
                         row: row)
    }

    /// Only named people carry a label.
    static func boxes(_ placement: Placement) -> [Box] {
        let ring = ring(placement.prominence)
        let dx = Double(placement.position.x - viewpoint.x)
        let dz = Double(viewpoint.z - placement.position.z)
        let distance = (dx * dx + dz * dz).squareRoot()
        let azimuth = atan2(dx, dz)
        let height = Double(placement.position.y)
        let size = ring.clearance / distance
        let lantern = Box(azimuth: azimuth, elevation: atan((height - eyeHeight) / distance), halfWidth: size, halfHeight: size)
        guard ring.labelled else { return [lantern] }
        let label = Box(azimuth: azimuth, elevation: atan((height - labelDrop - eyeHeight) / distance),
                        halfWidth: labelHalfWidth, halfHeight: labelHalfHeight)
        return [lantern, label]
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
