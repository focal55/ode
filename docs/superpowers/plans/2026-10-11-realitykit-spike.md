# RealityKit Spike Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Answer the spec's five rendering questions with a throwaway `RealityView` of five real lanterns over water, so step 4 builds on RealityKit or on the 2.5D fallback with evidence, not hope.

**Architecture:** A second window ("Plaza spike", opened from a Spike menu with ⌥⌘P) inside the existing Ode app, so it gets real Contacts photos and real waiting state without new permissions. All code lives in `Ode/Spike/` on branch `spike/plaza-realitykit`, which is **never merged**. The only thing that reaches main is the findings note, written on main after Joe's verdicts.

**Tech Stack:** RealityKit (`RealityView`, `PerspectiveCamera`, `BillboardComponent`, `PhysicallyBasedMaterial`, `CustomMaterial` with a Metal surface shader, `ParticleEmitterComponent`, `BloomComponent`), SwiftUI overlays, macOS 27 deployment target.

**Spec:** `docs/superpowers/specs/2026-10-11-lantern-plaza-design.md` (sections Scene, Spike, Rendering).

## Global Constraints

- Throwaway: "No code from it is kept." Step 4 rewrites what it needs from scratch against OdeCore's `PlazaLayout`.
- Pass criteria, verbatim:
  1. A real Contacts photo in a lantern looks warm, not like a memorial candle (Joe judges).
  2. Flying to a person feels great at 60 fps.
  3. The water reflections read as water.
  4. Projected SwiftUI labels don't lag behind the lanterns.
  5. Bloom is either practical or ruled out.
- Fallback rule: if 3 or 4 fail, the backdrop falls back to 2.5D (SwiftUI `Canvas` plus Metal shader effects). If 1 fails, the lantern design changes, not the plan.
- A photo is a camera-facing disc inside the shell, never wrapped onto the sphere.
- Budget: 60 fps at full window size on Joe's Mac.
- Privacy: the spike shows first names only, never message text. Nothing is written to disk; nothing leaves the Mac. The findings note names no people.
- Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Ode.xcodeproj -scheme Ode -destination 'platform=macOS' build`. `Ode/` is a synchronized folder, so new `.swift` and `.metal` files are picked up without editing the project.

## Verified SDK facts (macOS 27 SDK, checked while writing this plan)

- `RealityViewCameraContent` has `camera` (`.virtual`), `renderingEffects.customPostProcessing` (`.effect(some PostProcessEffect)`), and `project(point:to:)` returning `CGPoint?` into any SwiftUI coordinate space.
- `BloomComponent(scope:)` and `BloomOptionsComponent` (`strength`, `threshold`, `blurRadius`) exist from macOS 27. The deployment target is 27.0, so no availability checks are needed.
- `ViewAttachmentComponent` is not available on macOS, so projected SwiftUI labels are the only label path. Criterion 4 is decisive.
- `Entity.move(to:relativeTo:duration:timingFunction:)`, `OpacityComponent`, `ModelSortGroupComponent`, and the `PostProcessEffect` protocol are available.

## Testing approach

There are no unit tests: this is a throwaway prototype, the TDD exception Joe approves with this plan. Each task's gate is a clean build plus a named visual check. The frame meter (Task 1) and lag markers (Task 2) make criteria 2 and 4 measurable rather than vibes.

## Review Focus

The end-of-plan review looks at whether the spike's answers are honest, not at code quality:
- The fps reading during a flight is the **worst** frame, not the average. A 0.9 s flight that hitches once feels bad even at 60 average.
- Full window size on Joe's display, not the default window size. Measure both.
- Five lanterns is not the real load. Run the stress mode (Task 5) at 40 lanterns before calling criterion 2 passed.
- At least one lantern with no photo (monogram) and one with a low-quality or dark photo, so criterion 1 isn't judged on the best photo only.
- Labels during the flight, not at rest. At rest every approach looks right.

---

### Task 1: Spike window, world shell and frame meter

**Files:**
- Create: `Ode/Spike/SpikePerson.swift`
- Create: `Ode/Spike/SpikeStage.swift`
- Create: `Ode/Spike/PlazaSpikeView.swift`
- Modify: `Ode/OdeApp.swift`

**Interfaces:**
- Produces: `SpikePerson` (`id: Int64`, `name: String`, `photo: CGImage?`, `owed: Bool`, `hue: Double`), `SpikePerson.pick(from: AppModel) -> [SpikePerson]`, `SpikeStage` (`@MainActor @Observable`) with `root: Entity`, `camera: PerspectiveCamera`, `rig: Entity`, `fps: Double`, `worstMs: Double`, `build(people:into:)`, `tick(dt:content:)`. `SpikeStage.space = "plaza"` is the SwiftUI coordinate-space name.

- [ ] **Step 1: Branch**

```bash
git checkout -b spike/plaza-realitykit
```

- [ ] **Step 2: Write `SpikePerson.swift`**

```swift
import AppKit
import OdeCore

/// Throwaway (RealityKit spike). Never merged.
struct SpikePerson: Identifiable {
    let id: Int64
    let name: String
    let photo: CGImage?
    let owed: Bool
    let hue: Double

    /// Owed people first, then people with photos, so the spike is judged on real faces. Always keeps one without a
    /// photo so the monogram is judged too.
    @MainActor static func pick(from model: AppModel, count: Int = 5) -> [SpikePerson] {
        let owed = Set(model.waiting.map(\.conversationID))
        let all = model.people.filter { !$0.conversation.isGroup }.map { person in
            SpikePerson(id: person.id,
                        name: String(person.title.split(separator: " ").first ?? Substring(person.title)),
                        photo: person.photo.flatMap { NSImage(data: $0)?.cgImage(forProposedRect: nil, context: nil, hints: nil) },
                        owed: owed.contains(person.id),
                        hue: Double(abs(person.id) % 360) / 360)
        }
        let withPhoto = all.filter { $0.photo != nil }.sorted { $0.owed && !$1.owed }
        let withoutPhoto = all.filter { $0.photo == nil }
        return Array((withPhoto.prefix(count - 1) + withoutPhoto.prefix(1) + withPhoto.dropFirst(count - 1)).prefix(count))
    }
}
```

- [ ] **Step 3: Write `SpikeStage.swift`**

```swift
import AppKit
import RealityKit
import SwiftUI

/// Throwaway (RealityKit spike). Owns the scene graph and per-frame state.
@MainActor @Observable
final class SpikeStage {
    static let space = "plaza"

    let root = Entity()
    let rig = Entity()
    let camera = PerspectiveCamera()
    private(set) var fps = 0.0
    private(set) var worstMs = 0.0
    private(set) var labelPoints: [Int64: CGPoint] = [:]
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var elapsed = 0.0
    @ObservationIgnored private var worst = 0.0
    @ObservationIgnored var update: EventSubscription?
    @ObservationIgnored var clock = 0.0

    func build(people: [SpikePerson], into content: inout RealityViewCameraContent) {
        content.camera = .virtual
        camera.camera.fieldOfViewInDegrees = 40
        rig.addChild(camera)
        rig.position = [0, 1.6, 7]
        camera.look(at: [0, 1.1, 0], from: rig.position, relativeTo: nil)
        root.addChild(rig)
        root.addChild(Self.sky())
        root.addChild(Self.flatWater())
        content.add(root)
    }

    func tick(dt: Double, content: RealityViewCameraContent) {
        clock += dt
        frames += 1
        elapsed += dt
        worst = max(worst, dt)
        if elapsed >= 0.5 {
            fps = Double(frames) / elapsed
            worstMs = worst * 1000
            (frames, elapsed, worst) = (0, 0, 0)
        }
    }

    private static func sky() -> Entity {
        let stops: [(Double, NSColor)] = [
            (0, NSColor(red: 0.07, green: 0.09, blue: 0.20, alpha: 1)),
            (0.42, NSColor(red: 0.30, green: 0.24, blue: 0.42, alpha: 1)),
            (0.5, NSColor(red: 0.93, green: 0.62, blue: 0.47, alpha: 1)),
            (1, NSColor(red: 0.10, green: 0.10, blue: 0.18, alpha: 1)),
        ]
        var material = UnlitMaterial()
        if let texture = try? TextureResource(image: SpikeImages.verticalGradient(stops), options: .init(semantic: .color)) {
            material.color = .init(texture: .init(texture))
        }
        let dome = ModelEntity(mesh: .generateSphere(radius: 200), materials: [material])
        dome.scale = [-1, 1, 1]
        return dome
    }

    private static func flatWater() -> Entity {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: NSColor(red: 0.04, green: 0.07, blue: 0.16, alpha: 1))
        material.roughness = 0.2
        let water = ModelEntity(mesh: .generatePlane(width: 400, depth: 400), materials: [material])
        water.name = "water"
        return water
    }
}

/// Throwaway image helpers for textures drawn in code.
enum SpikeImages {
    static func verticalGradient(_ stops: [(Double, NSColor)], height: Int = 256) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let gradient = CGGradient(colorsSpace: nil, colors: stops.map(\.1.cgColor) as CFArray,
                                  locations: stops.map { CGFloat($0.0) })!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])
        return context.makeImage()!
    }
}
```

`TextureResource(image:options:)` may be `async` in this SDK. If the build says so, make `build` `async`, `await` the texture calls, and `await` `build` in the `RealityView` make closure (it is async). Ledger it as a ruling.

- [ ] **Step 4: Write `PlazaSpikeView.swift`**

```swift
import RealityKit
import SwiftUI

/// Throwaway (RealityKit spike). Never merged.
struct PlazaSpikeView: View {
    let people: [SpikePerson]
    @State private var stage = SpikeStage()

    var body: some View {
        ZStack(alignment: .topLeading) {
            RealityView { content in
                stage.build(people: people, into: &content)
                let stage = stage
                stage.update = content.subscribe(to: SceneEvents.Update.self) { [content] event in
                    MainActor.assumeIsolated { stage.tick(dt: event.deltaTime, content: content) }
                }
            }
            hud
        }
        .coordinateSpace(.named(SpikeStage.space))
        .frame(minWidth: 960, minHeight: 600)
        .background(.black)
    }

    private var hud: some View {
        Text(String(format: "%.0f fps  worst %.1f ms", stage.fps, stage.worstMs))
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
            .padding(10)
    }
}
```

- [ ] **Step 5: Add the window and menu in `OdeApp.swift`**

Below the existing `WindowGroup { ... }.windowStyle(.hiddenTitleBar)`, add the commands to the group and a second scene:

```swift
        .commands { SpikeCommands() }

        Window("Plaza spike", id: "plaza-spike") {
            PlazaSpikeView(people: SpikePerson.pick(from: model))
        }
```

And at the bottom of `OdeApp.swift`:

```swift
/// Throwaway (RealityKit spike).
struct SpikeCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Spike") {
            Button("Open Plaza Spike") { openWindow(id: "plaza-spike") }
                .keyboardShortcut("p", modifiers: [.command, .option])
        }
    }
}
```

- [ ] **Step 6: Build**

Run: the Global Constraints build command, piped to `grep -E "BUILD (SUCCEEDED|FAILED)|error:"`.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Look**

Run Ode, then ⌥⌘P. Expected: a dusk gradient sky, dark water, and the HUD reading close to 60 fps (120 on a ProMotion display).

- [ ] **Step 8: Commit**

```bash
git add Ode/Spike Ode/OdeApp.swift
git commit -m "spike(plaza): window, sky, water and frame meter"
```

---

### Task 2: Lanterns, photo styles and projected labels

**Files:**
- Create: `Ode/Spike/SpikeLantern.swift`
- Modify: `Ode/Spike/SpikeStage.swift`, `Ode/Spike/PlazaSpikeView.swift`

**Interfaces:**
- Consumes: `SpikePerson`, `SpikeStage`, `SpikeImages`.
- Produces: `SpikeLantern.Style` (`.photo`, `.framed`, `.monogram`), `SpikeLantern.make(_:style:) -> Entity` (children named `"label"` and `"lagMarker"`), `SpikeStage.lanterns: [Int64: Entity]`, `SpikeStage.style`, `SpikeStage.cycleStyle()`, `SpikeStage.showLag`, `SpikeStage.labelPoints`.

The three styles are criterion 1's experiment. **photo**: the full-color photo, warmed slightly, with a soft edge. **framed**: the photo slightly desaturated inside a paper-colored (`#F6F4EF`) rim, like a portrait in a frame rather than a flame. **monogram**: initials on the person's hue, with the photo hidden.

- [ ] **Step 1: Write `SpikeLantern.swift`**

```swift
import AppKit
import RealityKit

/// Throwaway (RealityKit spike).
@MainActor enum SpikeLantern {
    enum Style: Int, CaseIterable { case photo, framed, monogram }

    static func make(_ person: SpikePerson, style: Style) -> Entity {
        let lantern = Entity()
        let tint = person.photo.map(averageColor) ?? NSColor(hue: person.hue, saturation: 0.45, brightness: 0.95, alpha: 1)
        let group = ModelSortGroup()

        let glow = billboard(SpikeImages.radialGlow(tint), size: 2.4)
        glow.components.set(ModelSortGroupComponent(group: group, order: 0))
        lantern.addChild(glow)

        let disc = billboard(face(person, style: style, tint: tint), size: 0.62)
        disc.components.set(ModelSortGroupComponent(group: group, order: 1))
        lantern.addChild(disc)

        var glass = PhysicallyBasedMaterial()
        glass.baseColor = .init(tint: .white)
        glass.roughness = 0.04
        glass.metallic = 0
        glass.clearcoat = 1
        glass.clearcoatRoughness = 0.02
        glass.emissiveColor = .init(color: tint)
        glass.emissiveIntensity = 0.25
        glass.blending = .transparent(opacity: 0.16)
        let shell = ModelEntity(mesh: .generateSphere(radius: 0.5), materials: [glass])
        shell.components.set(ModelSortGroupComponent(group: group, order: 2))
        lantern.addChild(shell)

        let light = PointLight()
        light.light.color = tint
        light.light.intensity = 1800
        light.light.attenuationRadius = 3
        lantern.addChild(light)

        let label = Entity()
        label.name = "label"
        label.position = [0, -0.72, 0]
        lantern.addChild(label)

        let marker = ModelEntity(mesh: .generateSphere(radius: 0.025), materials: [UnlitMaterial(color: .systemRed)])
        marker.name = "lagMarker"
        marker.isEnabled = false
        label.addChild(marker)
        return lantern
    }

    private static func billboard(_ image: CGImage, size: Float) -> ModelEntity {
        var material = UnlitMaterial()
        if let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            material.color = .init(tint: .white, texture: .init(texture))
        }
        material.blending = .transparent(opacity: 1)
        let plane = ModelEntity(mesh: .generatePlane(width: size, height: size), materials: [material])
        plane.components.set(BillboardComponent())
        return plane
    }

    private static func face(_ person: SpikePerson, style: Style, tint: NSColor) -> CGImage {
        switch (style, person.photo) {
        case (.photo, let photo?): SpikeImages.disc(photo: photo, saturation: 1, warmth: 0.12, rim: nil)
        case (.framed, let photo?): SpikeImages.disc(photo: photo, saturation: 0.8, warmth: 0.05,
                                                     rim: NSColor(red: 0.965, green: 0.957, blue: 0.937, alpha: 1))
        default: SpikeImages.monogram(person.name, tint: tint)
        }
    }

    /// Softened toward white so a saturated shirt doesn't turn the whole lantern that color.
    private static func averageColor(_ image: CGImage) -> NSColor {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let soften = { (c: UInt8) in 0.55 * Double(c) / 255 + 0.45 }
        return NSColor(red: soften(pixel[0]), green: soften(pixel[1]), blue: soften(pixel[2]), alpha: 1)
    }
}
```

- [ ] **Step 2: Add the image helpers to `SpikeImages` in `SpikeStage.swift`**

```swift
    static func radialGlow(_ tint: NSColor, size: Int = 256) -> CGImage {
        let context = square(size)
        let colors = [tint.withAlphaComponent(0.55).cgColor, tint.withAlphaComponent(0.12).cgColor,
                      tint.withAlphaComponent(0).cgColor] as CFArray
        let gradient = CGGradient(colorsSpace: nil, colors: colors, locations: [0, 0.35, 1])!
        let center = CGPoint(x: size / 2, y: size / 2)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                   endRadius: CGFloat(size) / 2, options: [])
        return context.makeImage()!
    }

    static func disc(photo: CGImage, saturation: Double, warmth: Double, rim: NSColor?, size: Int = 512) -> CGImage {
        let context = square(size)
        let bounds = CGRect(x: 0, y: 0, width: size, height: size)
        let inset = rim == nil ? 0 : CGFloat(size) * 0.06
        if let rim {
            context.setFillColor(rim.cgColor)
            context.fillEllipse(in: bounds)
        }
        context.saveGState()
        context.addEllipse(in: bounds.insetBy(dx: inset, dy: inset))
        context.clip()
        let side = CGFloat(min(photo.width, photo.height))
        let crop = photo.cropping(to: CGRect(x: (CGFloat(photo.width) - side) / 2, y: (CGFloat(photo.height) - side) / 2,
                                             width: side, height: side)) ?? photo
        context.draw(crop, in: bounds.insetBy(dx: inset, dy: inset))
        if saturation < 1 {
            context.setBlendMode(.saturation)
            context.setFillColor(NSColor(white: 0.5, alpha: 1 - saturation).cgColor)
            context.fill(bounds)
        }
        context.setBlendMode(.softLight)
        context.setFillColor(NSColor(red: 1, green: 0.72, blue: 0.45, alpha: warmth).cgColor)
        context.fill(bounds)
        context.restoreGState()
        return context.makeImage()!
    }

    static func monogram(_ name: String, tint: NSColor, size: Int = 512) -> CGImage {
        let context = square(size)
        context.setFillColor(tint.cgColor)
        context.fillEllipse(in: CGRect(x: 0, y: 0, width: size, height: size))
        let text = NSAttributedString(string: String(name.prefix(1)).uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: CGFloat(size) * 0.42, weight: .heavy),
            .foregroundColor: NSColor(red: 0.078, green: 0.086, blue: 0.11, alpha: 0.85),
        ])
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let bounds = text.size()
        text.draw(at: CGPoint(x: (CGFloat(size) - bounds.width) / 2, y: (CGFloat(size) - bounds.height) / 2))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    private static func square(_ size: Int) -> CGContext {
        CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }
```

- [ ] **Step 3: Place lanterns, bob them and project labels in `SpikeStage`**

Add the stored state:

```swift
    private(set) var style = SpikeLantern.Style.photo
    var showLag = false { didSet { lanterns.values.forEach { $0.findEntity(named: "lagMarker")?.isEnabled = showLag } } }
    @ObservationIgnored private(set) var lanterns: [Int64: Entity] = [:]
    @ObservationIgnored private var homes: [Int64: SIMD3<Float>] = [:]
    @ObservationIgnored private var people: [SpikePerson] = []
```

Add these to `build`, before `content.add(root)`:

```swift
        self.people = people
        placeLanterns()
```

And add the methods:

```swift
    /// Owed people stand nearer, like the spec's `owed` depth; the rest stand back.
    private func placeLanterns() {
        lanterns.values.forEach { $0.removeFromParent() }
        lanterns = [:]
        let xs: [Float] = [-3.2, -1.6, 0, 1.6, 3.2]
        for (index, person) in people.enumerated() {
            let lantern = SpikeLantern.make(person, style: style)
            let home = SIMD3<Float>(xs[index % xs.count], 1.2, person.owed ? -0.6 : -2.4)
            lantern.position = home
            homes[person.id] = home
            lanterns[person.id] = lantern
            root.addChild(lantern)
        }
    }

    func cycleStyle() {
        style = SpikeLantern.Style(rawValue: (style.rawValue + 1) % SpikeLantern.Style.allCases.count)!
        placeLanterns()
    }
```

In `tick`, after the frame-meter lines:

```swift
        for (id, lantern) in lanterns {
            guard let home = homes[id] else { continue }
            lantern.position.y = home.y + 0.06 * Float(sin(clock * 1.1 + Double(id % 7)))
        }
        var points: [Int64: CGPoint] = [:]
        for (id, lantern) in lanterns {
            guard let anchor = lantern.findEntity(named: "label") else { continue }
            points[id] = content.project(point: anchor.position(relativeTo: nil), to: .named(Self.space))
        }
        labelPoints = points
```

- [ ] **Step 4: Labels, lag markers and keys in `PlazaSpikeView`**

Inside the `ZStack`, between `RealityView` and `hud`:

```swift
            ForEach(people) { person in
                if let point = stage.labelPoints[person.id] {
                    VStack(spacing: 2) {
                        if stage.showLag { Circle().fill(.red).frame(width: 7, height: 7) }
                        Text(person.name).font(.system(size: 13, weight: .semibold))
                        if person.owed { Text("since Tuesday").font(.system(size: 11)).opacity(0.7) }
                    }
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 4)
                    .fixedSize()
                    .position(x: point.x, y: point.y + (stage.showLag ? 0 : 14))
                    .allowsHitTesting(false)
                }
            }
```

"since Tuesday" is a fixed string: the spike tests how a status line looks, and it never shows real waiting text.

On the `ZStack`, after `.coordinateSpace(...)`:

```swift
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(characters: .init(charactersIn: "vl")) { press in
            switch press.characters {
            case "v": stage.cycleStyle()
            default: stage.showLag.toggle()
            }
            return .handled
        }
```

Extend the HUD string to `"%.0f fps  worst %.1f ms  style %@  [V]style [L]lag"` with `String(describing: stage.style)`.

- [ ] **Step 5: Build**

Run: the build command.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Look**

Open the spike. Expected: five lanterns with faces (one monogram), glass catching light, a glow around each, and first names under them. V cycles photo, framed and monogram. L shows the red 3D marker and the red SwiftUI dot, which should sit on top of each other.

- [ ] **Step 7: Commit**

```bash
git add Ode/Spike
git commit -m "spike(plaza): lanterns with three photo styles and projected labels"
```

---

### Task 3: Flight, parallax and breathing

**Files:**
- Modify: `Ode/Spike/SpikeStage.swift`, `Ode/Spike/PlazaSpikeView.swift`

**Interfaces:**
- Consumes: `SpikeStage.lanterns`, `rig`, `camera`.
- Produces: `SpikeStage.focus(_ index: Int)`, `SpikeStage.returnHome()`, `SpikeStage.pointer(_ unit: CGPoint?)`, `SpikeStage.flightWorstMs: Double` (the worst frame during the last flight).

The camera's flight moves `camera` inside `rig`. Breathing and parallax move `rig`, so the two never fight over one transform.

- [ ] **Step 1: Add flight state and methods to `SpikeStage`**

```swift
    private(set) var flightWorstMs = 0.0
    @ObservationIgnored private var flightUntil = 0.0
    @ObservationIgnored private var flightWorst = 0.0
    @ObservationIgnored private var parallax = CGPoint.zero
    @ObservationIgnored private let rigHome = SIMD3<Float>(0, 1.6, 7)

    func focus(_ index: Int) {
        guard people.indices.contains(index), let lantern = lanterns[people[index].id] else { return }
        let target = lantern.position(relativeTo: nil)
        // Offset right and back so the lantern sits left of center, leaving room for the reply panel.
        let from = target + SIMD3<Float>(1.0, 0.25, 2.8) - rigHome
        let pose = Entity()
        pose.look(at: target + SIMD3<Float>(0.75, 0, 0) - rigHome, from: from, relativeTo: nil)
        fly(to: pose.transform)
        for (id, other) in lanterns {
            other.components.set(OpacityComponent(opacity: id == people[index].id ? 1 : 0.35))
        }
    }

    func returnHome() {
        let pose = Entity()
        pose.look(at: [0, 1.1, 0] - rigHome, from: .zero, relativeTo: nil)
        fly(to: pose.transform)
        lanterns.values.forEach { $0.components.set(OpacityComponent(opacity: 1)) }
    }

    func pointer(_ unit: CGPoint?) { parallax = unit ?? .zero }

    private func fly(to transform: Transform) {
        camera.move(to: transform, relativeTo: rig, duration: 0.9, timingFunction: .easeInOut)
        flightUntil = clock + 0.9
        flightWorst = 0
    }
```

Because `rig` is the camera's parent, `rig`-relative poses are world poses minus `rigHome` while `rig` sits at home. The breathing offset is a few centimetres, which is close enough for the spike.

Change the camera setup in `build` to be rig-relative:

```swift
        camera.look(at: [0, 1.1, 0] - rig.position, from: .zero, relativeTo: rig)
```

- [ ] **Step 2: Breathing, parallax and the flight meter in `tick`**

```swift
        if clock < flightUntil {
            flightWorst = max(flightWorst, dt)
        } else if flightWorst > 0 {
            flightWorstMs = flightWorst * 1000
            flightWorst = 0
        }
        let breathe = Float(sin(clock * 0.5)) * 0.03
        rig.position = rigHome + SIMD3<Float>(Float(parallax.x) * 0.25, breathe + Float(parallax.y) * -0.12, 0)
```

- [ ] **Step 3: Keys and pointer in `PlazaSpikeView`**

Extend the `onKeyPress` characters to `"vl12345"`, and handle digits:

```swift
            case let digit where Int(digit) != nil: stage.focus(Int(digit)! - 1)
```

Add Esc:

```swift
        .onKeyPress(.escape) { stage.returnHome(); return .handled }
```

Add parallax with a `GeometryReader` around the `ZStack`, or with `onContinuousHover` on it:

```swift
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location):
                stage.pointer(CGPoint(x: location.x / max(width, 1) * 2 - 1, y: location.y / max(height, 1) * 2 - 1))
            case .ended: stage.pointer(nil)
            }
        }
```

Here `width` and `height` come from a `GeometryReader { proxy in ... }` wrapping the `ZStack` body (`proxy.size`). Add `"  flight worst %.1f ms  [1-5] fly  [esc] back"` to the HUD, showing `stage.flightWorstMs`.

- [ ] **Step 4: Build**

Run: the build command.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Look**

Press 1 through 5 and Esc, at default size and then full screen. Expected: a 0.9 s eased flight that frames the lantern left of center while the others dim. The flight worst-frame stays under 16.7 ms (60 fps), and labels stay attached during the flight (check with L on).

- [ ] **Step 6: Commit**

```bash
git add Ode/Spike
git commit -m "spike(plaza): flight to a person, parallax and breathing"
```

---

### Task 4: Water, reflections, hills and motes

**Files:**
- Create: `Ode/Spike/SpikeWater.metal`
- Modify: `Ode/Spike/SpikeStage.swift`, `Ode/Spike/PlazaSpikeView.swift`

**Interfaces:**
- Consumes: `SpikeStage.lanterns`, `root`.
- Produces: `SpikeStage.showReflections`, `SpikeStage.useRippleWater`.

The spec says reflections are mirrored, dimmed copies of the lanterns beneath the water. This task builds exactly that, so criterion 3 judges the spec's own design.

- [ ] **Step 1: Write the ripple surface shader**

```metal
#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// Throwaway (RealityKit spike).
[[visible]]
void spikeWater(realitykit::surface_parameters params) {
    float2 p = params.geometry().world_position().xz;
    float t = params.uniforms().time();
    float a = p.x * 1.7 + t * 0.9;
    float b = p.y * 2.3 - t * 1.3;
    float wave = 0.5 * sin(a) + 0.5 * sin(b);
    float3 deep = float3(0.04, 0.07, 0.16);
    float3 glint = float3(0.95, 0.62, 0.42);
    params.surface().set_base_color(half3(deep + glint * smoothstep(0.55, 1.0, wave) * 0.22));
    params.surface().set_roughness(half(0.12));
    params.surface().set_metallic(half(0));
    params.surface().set_opacity(half(0.8));
    params.surface().set_normal(half3(normalize(float3(cos(a) * 0.09, cos(b) * 0.09, 1))));
}
```

- [ ] **Step 2: Swap the water and add reflections, hills and motes in `SpikeStage`**

```swift
    var showReflections = true { didSet { reflections.forEach { $0.isEnabled = showReflections } } }
    @ObservationIgnored private var reflections: [Entity] = []

    private static func rippleWater() -> Entity? {
        guard let library = MTLCreateSystemDefaultDevice()?.makeDefaultLibrary() else { return nil }
        let shader = CustomMaterial.SurfaceShader(named: "spikeWater", in: library)
        guard var material = try? CustomMaterial(surfaceShader: shader, lightingModel: .lit) else { return nil }
        material.blending = .transparent(opacity: 0.8)
        let water = ModelEntity(mesh: .generatePlane(width: 400, depth: 400), materials: [material])
        water.name = "water"
        return water
    }

    private static func hills() -> Entity {
        let hills = Entity()
        let ink = UnlitMaterial(color: NSColor(red: 0.08, green: 0.08, blue: 0.14, alpha: 1))
        for (x, width, height) in [(-40, 60, 7), (10, 80, 10), (55, 50, 6)] as [(Float, Float, Float)] {
            let hill = ModelEntity(mesh: .generateSphere(radius: 1), materials: [ink])
            hill.scale = [width / 2, height, 6]
            hill.position = [x, 0, -90]
            hills.addChild(hill)
        }
        return hills
    }

    private static func motes() -> Entity {
        var particles = ParticleEmitterComponent()
        particles.emitterShape = .box
        particles.emitterShapeSize = [14, 2.5, 10]
        particles.speed = 0.04
        particles.mainEmitter.birthRate = 8
        particles.mainEmitter.lifeSpan = 7
        particles.mainEmitter.size = 0.018
        particles.mainEmitter.color = .constant(.single(NSColor(red: 1, green: 0.85, blue: 0.6, alpha: 0.8)))
        let motes = Entity()
        motes.position = [0, 1.4, -1]
        motes.components.set(particles)
        return motes
    }
```

In `build`, replace `root.addChild(Self.flatWater())` with:

```swift
        root.addChild(Self.rippleWater() ?? Self.flatWater())
        root.addChild(Self.hills())
        root.addChild(Self.motes())
```

At the end of `placeLanterns()`, mirror every lantern:

```swift
        reflections.forEach { $0.removeFromParent() }
        reflections = lanterns.values.map { lantern in
            let mirror = lantern.clone(recursive: true)
            mirror.scale = [1, -1, 1]
            mirror.position = [lantern.position.x, -lantern.position.y, lantern.position.z]
            mirror.components.set(OpacityComponent(opacity: 0.3))
            mirror.findEntity(named: "lagMarker")?.removeFromParent()
            mirror.isEnabled = showReflections
            root.addChild(mirror)
            return mirror
        }
```

In `tick`, keep each mirror under its bobbing lantern, with a slow wobble so it reads as moving water:

```swift
        for (mirror, lantern) in zip(reflections, lanterns.values) {
            mirror.position = [lantern.position.x + 0.03 * Float(sin(clock * 2.1)), -lantern.position.y, lantern.position.z]
        }
```

Rebuild both arrays in the same `placeLanterns()` call, from the same `lanterns.values`, so the `zip` lines up. A `Dictionary`'s `values` order is stable while the dictionary isn't mutated.

- [ ] **Step 3: Key R toggles reflections**

Add `"r"` to the `onKeyPress` set: `case "r": stage.showReflections.toggle()`. Add `[R]eflect` to the HUD.

- [ ] **Step 4: Build**

Run: the build command.
Expected: `** BUILD SUCCEEDED **`. If `spikeWater` fails to compile, the build log names the line. If `CustomMaterial` throws at runtime, the flat water stays and the HUD should say so. Add `water: flat` or `water: ripple` to the HUD from `root.findEntity(named: "water")`'s material type.

- [ ] **Step 5: Look**

Expected: ripples with warm glints, dim wobbling mirrored lanterns below, hill silhouettes, and slow motes. Toggle R and compare. Check fps with everything on.

- [ ] **Step 6: Commit**

```bash
git add Ode/Spike
git commit -m "spike(plaza): ripple water, reflections, hills and motes"
```

---

### Task 5: Bloom and the 40-lantern stress test

**Files:**
- Create: `Ode/Spike/SpikeBloom.swift`
- Modify: `Ode/Spike/SpikeStage.swift`, `Ode/Spike/PlazaSpikeView.swift`

**Interfaces:**
- Consumes: `root`, `camera`, `placeLanterns`.
- Produces: `SpikeStage.bloom: Bool`, `SpikeStage.stress: Bool`.

- [ ] **Step 1: Built-in bloom toggle in `SpikeStage`**

```swift
    var bloom = false { didSet { applyBloom() } }

    private func applyBloom() {
        if bloom {
            var options = BloomOptionsComponent()
            options.strength = 0.8
            options.threshold = 0.7
            options.blurRadius = 12
            root.components.set(BloomComponent(scope: .unbounded))
            root.components.set(options)
        } else {
            root.components.remove(BloomComponent.self)
            root.components.remove(BloomOptionsComponent.self)
        }
    }
```

The docs don't say which entity bloom belongs on. Try `root` first. If B shows no visible change, move both components to `camera`. If there's still no change, put `BloomComponent(scope: .hierarchical)` on each lantern's glow and shell. Ledger which placement worked.

- [ ] **Step 2: Fallback only if built-in bloom shows nothing anywhere: a custom post-process**

Write `SpikeBloom.swift`:

```swift
import Metal
import MetalPerformanceShaders
import RealityKit

/// Throwaway (RealityKit spike): threshold, blur, add.
struct SpikeBloomEffect: PostProcessEffect {
    nonisolated func postProcess(context: borrowing PostProcessEffectContext<any MTLCommandBuffer>) {
        let source = context.sourceColorTexture
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: source.pixelFormat, width: source.width,
                                                                  height: source.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let bright = context.device.makeTexture(descriptor: descriptor),
              let blurred = context.device.makeTexture(descriptor: descriptor) else { return }
        MPSImageThresholdToZero(device: context.device, thresholdValue: 0.7, linearGrayColorTransform: nil)
            .encode(commandBuffer: context.commandBuffer, sourceTexture: source, destinationTexture: bright)
        MPSImageGaussianBlur(device: context.device, sigma: 12)
            .encode(commandBuffer: context.commandBuffer, sourceTexture: bright, destinationTexture: blurred)
        MPSImageAdd(device: context.device)
            .encode(commandBuffer: context.commandBuffer, primaryTexture: source, secondaryTexture: blurred,
                    destinationTexture: context.targetColorTexture)
    }
}
```

In `PlazaSpikeView`'s make closure, when bloom is turned on, set `content.renderingEffects.customPostProcessing = .effect(SpikeBloomEffect())`. Because `content` is only reachable in the closures, use the `RealityView` `update:` closure, which reads `stage.bloom`, and set `.none` when it's off. Allocating textures every frame is wasteful; that is fine for a yes/no answer, and the fps it costs is an upper bound.

- [ ] **Step 3: Stress mode**

```swift
    var stress = false { didSet { placeLanterns() } }
```

In `placeLanterns()`, iterate `stress ? Array(repeating: people, count: 8).flatMap { $0 } : people` and give extra lanterns positions on a wider arc, further back:

```swift
            let ring = index / 5
            let home = ring == 0
                ? SIMD3<Float>(xs[index % 5], 1.2, person.owed ? -0.6 : -2.4)
                : SIMD3<Float>(Float(index % 5 - 2) * 2.4 + Float(ring % 2) * 1.2, 1.0 + Float(ring) * 0.08, -2.4 - Float(ring) * 2.2)
```

Repeated people share an id, so key `lanterns` and `homes` by `Int64(index)` in stress mode. Labels then show only for the first five; that's fine, because the stress test measures frames, not labels.

- [ ] **Step 4: Keys B and S, plus a HUD line**

Add `"bs"` to the key set: `case "b": stage.bloom.toggle()`, `case "s": stage.stress.toggle()`. Add `bloom on/off  lanterns N  [B]loom [S]tress` to the HUD.

- [ ] **Step 5: Build**

Run: the build command.
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Measure**

Full screen, everything on. Record for each case the HUD's fps, worst ms and flight worst ms:
1. 5 lanterns, bloom off
2. 5 lanterns, bloom on
3. 40 lanterns, bloom off
4. 40 lanterns, bloom on

Bloom is "practical" if case 2 holds 60 fps and visibly improves the glow over the sprites alone.

- [ ] **Step 7: Commit**

```bash
git add Ode/Spike
git commit -m "spike(plaza): bloom toggle and 40-lantern stress mode"
```

---

### Task 6: Joe's verdicts and the findings note

**Files:**
- Create (on **main**): `docs/superpowers/spikes/2026-10-11-realitykit-spike-findings.md`

- [ ] **Step 1: Joe runs the checklist**

Hand Joe this list:
1. **Warm or memorial?** Press V through photo, framed and monogram, on at least one good photo, one dark photo and the monogram. Which reads warm? Do any read like candles at a vigil?
2. **Flight.** Press 1 to 5 and Esc, full screen. Does it feel great? Note the flight-worst reading.
3. **Water.** Toggle R. Does it read as water, or as glass or a mirror floor?
4. **Labels.** Turn on L and fly. Do the red dots separate from the red markers at any point in the flight?
5. **Bloom.** Toggle B. Is it worth it, and what's the fps cost (Task 5's four readings)?

- [ ] **Step 2: Write the findings note on main**

```bash
git checkout main
```

The note holds, for each criterion: pass or fail, the evidence (readings and Joe's words), and the consequence for step 4. It ends with one of three decisions:
- **RealityKit**, possibly with a changed lantern design.
- **Hybrid**: RealityKit lanterns over a 2.5D backdrop.
- **2.5D**.

No names, photos or screenshots of real people go in the note.

```bash
git add docs/superpowers/spikes/2026-10-11-realitykit-spike-findings.md
git commit -m "docs(spike): RealityKit plaza findings"
```

- [ ] **Step 3: Keep or delete the spike branch**

The branch stays local until step 4's plan exists, so Joe can re-open the spike for comparison. Then it's deleted with `git branch -D spike/plaza-realitykit`, which needs Joe's confirmation because the branch is unmerged.
