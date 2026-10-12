# RealityKit spike findings

Step 3 of `docs/superpowers/specs/2026-10-11-lantern-plaza-design.md`, run 2026-10-11 on Joe's Mac (macOS 27, ProMotion display). The code lives on the unmerged branch `spike/plaza-realitykit` and is not kept.

**Decision: RealityKit.** Step 4 builds the plaza as a `RealityView` with projected SwiftUI labels. The 2.5D fallback is not needed.

## Criteria

| # | Criterion | Result | Evidence |
|---|---|---|---|
| 1 | A real photo in a lantern looks warm, not like a memorial candle | Pass | Joe: "style photo is great". The full-colour photo disc inside a glass shell with an additive glow was preferred over the framed and monogram variants. |
| 2 | Flying to a person feels great at 60 fps | Pass | 40 lanterns, custom bloom, 1728×967 window: 120 fps, worst frame 10.0 ms, worst frame during a flight 8.4 ms. Five lanterns at 960×600: worst 8.4 ms. |
| 3 | Water reflections read as water | Pass, needs polish | A ripple surface shader with mirrored, dimmed lantern copies reads as water. The lights' highlights on the ripples help most. The reflections look like separate ghost orbs rather than streaks from the waterline. |
| 4 | Projected SwiftUI labels don't lag behind the lanterns | Pass at rest; flight check to confirm | Labels projected with `RealityViewCameraContent.project(point:to:)` in `SceneEvents.Update` sit on their 3D markers. `ViewAttachmentComponent` does not exist on macOS, so projection is the only label path. |
| 5 | Bloom is practical or ruled out | Practical | A custom `PostProcessEffect` (threshold, Gaussian blur, add, using MPS with cached textures) costs no visible frame time at 40 lanterns. Joe chose it. Built-in `BloomComponent` (macOS 27) was available but not chosen. |

## What step 4 must carry over

- **Draw order is the hard part.** Transparent glow, photo disc, glass, mirrored reflections and water must share one `ModelSortGroup` with fixed orders, in this sequence:
  1. Reflections (glow, disc, shell).
  2. Water.
  3. Lanterns (glow, disc, shell).

  Every transparent material needs `writesDepth = false` and `faceCulling = .none`. Without this, the water paints over the lower half of every lantern and reflections disappear.
- **The glow is computed per pixel** in an additive `CustomMaterial` (`blendMode = .add`, unlit), with the tint and strength passed as parameters. A glow drawn from an image texture showed banding and a hard rim.
- **Glass highlights.** A light inside a sharp clearcoat shell puts a hot spot on the face. Use soft clearcoat (about 0.35, roughness 0.2) and low specular.
- **One point light per lantern does not scale.** At 40 lanterns each light makes highlights on its neighbours' glass, and bloom turns them into white blowouts. Step 4 should light faces with emissive and glow only, keeping real lights for at most the focused lantern and the few nearest.
- **Drive camera flights in the per-frame update,** interpolating the camera transform before projecting labels. Don't use `Entity.move(to:duration:)`: its animation may apply after label projection, which would add a frame of label lag.
- **Snapshot people when the plaza opens.** Re-deriving them, which decodes photos, on every model change runs on the main thread.
- **The build needs Xcode's Metal Toolchain** for the `.metal` surface shaders (`xcodebuild -downloadComponent MetalToolchain`).

## Left for step 5 (polish)

- Reflections as stretched, ripple-distorted streaks from the waterline, done in the water shader, instead of mirrored copies.
- Stress-mode placement overlapped badly. Real placement comes from `PlazaLayout` and its minimum angular separation, which the spike didn't test.
- Faces read small inside the shell. Consider a larger photo disc and a thinner shell.
