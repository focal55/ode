# Lantern Plaza: design

Approved in conversation on 2026-10-11. Interactive mockup: `.superpowers/brainstorm/12306-1791740464/content/lanterns-v3.html` (a 2D canvas sketch; speech recognition there is scripted).

## Goal

Replace the list home with an immersive, voice-forward world where the people you care about are present, and the one who needs you is obvious. You open Ode, hold Space, say what you want to tell someone, and land in Messages with your words ready to send.

Success is measured by one number: **kept events per day** (messages you sent that started in Ode). The Plaza is only a success if that number beats the list home it replaces. See [Judging it](#judging-it).

## Decisions

| Question | Decision | Why |
|---|---|---|
| Metaphor | A plaza where **you go to people** | A "king's court" turns loved ones into petitioners you dismiss, which inverts the Soul. |
| Art direction | **Lanterns at dusk**: glass orbs over reflective water | Native 3D lighting earns its place, and nobody is turned into a toy. |
| Companion | Ode is **the loop mark itself**, glowing ink blue | The brand mark becomes a character, not a mascot. |
| Voice trigger | **Push-to-talk**: hold Space | No surprise listening; works in a quiet room. |
| Ode speaking | Ode speaks **its own lines only** | Other people's messages are never read aloud. |
| Voice drafting | **Voice keeps your words** | Coach first, ghostwriter second. Ode never adds content you didn't say; its context is offered as chips. |
| App shape | **The Plaza replaces home** | One front door. Classic screens stay one menu away. |
| Groups | **Constellations**: member lanterns clustered and linked by threads of light | Keeps people visible without a per-member breakdown. |
| Rendering | **RealityKit `RealityView` + SwiftUI overlays**, gated by a spike | Real 3D camera, light and particles; the fallback is 2.5D (SwiftUI `Canvas` plus Metal shaders) for the backdrop only. |

Three critiques the design must answer:

1. The 3D earns its place through **transitions** (the flight to a person, the loop closing), not through idle beauty. The panel does the work.
2. The light follows the **real time of day**, not permanent dusk.
3. Real photos inside glowing orbs may read as **memorial candles**. This is tested with real Contacts before committing.

## Build order

Each step gets its own implementation plan.

1. **Contacts avatars and handoff logging.** It improves the current app immediately and starts the metric baseline.
2. **Voice.** Push-to-talk, transcription, routing and Ode's spoken lines, working in the current composer.
3. **RealityKit spike (throwaway).** Answers the rendering questions below. No code from it is kept.
4. **The Plaza as home.** Scene, panel, kept detection and the `plazaHome` setting.
5. **Polish.** Time-of-day lighting, constellations and sound design.

## Architecture

The rule: **the scene draws state and never decides anything.** All decisions live in OdeCore as pure, tested code, so the renderer can be swapped without touching logic.

### OdeCore (new)

- **`PlazaLayout`**: `compute(people:waiting:kept:now:) -> [Placement]`. Each placement holds the conversation id, prominence (`owed`, `quiet`, `around`, `horizon`), a world position, and a group id for constellations.
  - Prominence: `asked` / `unanswered` / `promised` waiting kinds → `owed`; `quiet` → `quiet`; tracked with nothing waiting → `around`; beyond the 40 most recent `around` people → `horizon`.
  - Position is seeded from the conversation id, so a person keeps the same angle across launches. Prominence sets depth: `owed` is near, `quiet` is middle, `around` is back, `horizon` is on the horizon line.
  - Members of a group conversation are placed in a cluster around the group's seeded position. The cluster draws each member as a small unlabeled light. A member who also has a tracked 1:1 conversation keeps their own full lantern elsewhere; the group cluster never shows a second labeled lantern for them.
  - Lanterns at the same depth keep a minimum angular separation so labels never overlap.
- **`VoiceIntent`**: `parse(transcript:people:focused:) -> Intent`, where `Intent` is one of:
  - `.reply(personID, request)`: verbs "tell", "reply to", "text", "message", "ask", "check in on", "let … know", followed by a name.
  - `.edit(instruction)`: anything said while a person is focused.
  - `.ask(question)`: questions to Ode ("who should I check on?").
  - `.ambiguous([personID], request)`: a name matching more than one person.
  - `.unknown(transcript)`.
  
  Name matching is deterministic: full name, first name and Contacts nickname, case- and punctuation-insensitive, with leading filler ("um", "okay so", "hey Ode") ignored. The local LLM is asked only when deterministic matching finds no verb and name; it must return a person from the given list or nothing.
- **`KeptDetector`**: given a set of `Handoff(conversationID, at)` records and newly synced messages, it returns kept events. A handoff is kept by any message from you in that conversation after `at` and within 24 hours. It never compares against draft text. Unkept handoffs expire silently after 24 hours.
- **`Daylight`**: `parameters(at: Date) -> Lighting`: sky gradient stops, sun direction and color, water tint, lantern glow strength (stronger at night) and mote type (dust by day, fireflies at night). Uses local sunrise and sunset from a fixed default latitude; no location permission.
- **`HandleDirectory.Entry`** gains `photo: Data?` and `nickname: String?`. A person's photo comes from the contact found through the existing contact key, so merged phone and email chats share one photo.

### App (new and changed)

- **`ContactsLoader`** also fetches `CNContactThumbnailImageDataKey` and `CNContactNicknameKey`.
- **`MessagesHandoff`**: extracted from `DraftComposerView.sendViaMessages`. `open(person:text:)` copies the text, opens Messages to the thread, and appends a `Handoff` to `~/Library/Application Support/Ode/handoffs.json`. Both the composer and the Plaza use it. Kept events are appended to `kept.json` in the same folder, which is the metric log.
- **`VoiceController`**: push-to-talk capture and on-device transcription, with results passed to `VoiceIntent`. See [Voice](#voice).
- **`OdeVoice`**: speaks Ode's lines through `AVSpeechSynthesizer` with the best installed system voice.
- **`PlazaView`**: the new home. It is a `ZStack` of `PlazaScene` with SwiftUI overlays: the headline, the lantern labels, `ReplyPanel` and `VoiceDock`. A small menu reaches the classic screens (health, threads, memory, settings) and "Change conversations".
- **`PlazaScene`**: a `RealityView` rendering placements and lighting. See [Scene](#scene).
- **`ReplyPanel`**: see [Reply panel](#reply-panel).
- **`MainView`**: when `plazaHome` is on, home shows `PlazaView` full-window with the sidebar hidden. `WaitingView` stays as the classic home when the setting is off.

## Voice

**Capture.** Hold Space while no text field has focus, or hold the on-screen key. A local key monitor handles it while the Ode window is active; there is no global hotkey. Microphone permission is requested on the first press, not at launch. Transcription uses `SpeechAnalyzer` with `SpeechTranscriber` on-device, showing in-progress results live. After release, capture continues for 300 ms so the last word isn't clipped, then the result is finalized. If the speech model for the system language isn't installed, it is downloaded on the first press and the dock shows progress.

**Routing.**
- `.reply`: the camera flies to the person and the panel opens with a draft built from your words (below).
- `.edit`: the current draft is revised by the instruction.
- `.ask`: Ode answers with one spoken line from the waiting list ("Priya, maybe. It's been five days, and she just started a new job.") and flies to that person.
- `.ambiguous`: the candidates' lanterns brighten, Ode asks "Which Sam?", and the next utterance or a click picks one.
- `.unknown`: Ode says "Who's it for?" and the transcript is placed in the type box for correction.

**Voice keeps your words.** The draft from a `.reply` request:
- converts reported speech into direct speech ("tell her I'm in for Saturday" becomes "I'm in for Saturday"),
- removes filler,
- adjusts to your writing style with this person (existing style data),
- adds no facts, questions or sentiments you didn't say.

Context Ode knows (open loops, memory) appears as **suggestion chips** under the draft, for example "Mention her mom's surgery?". Tapping one revises the draft to include it. "Redraft" still produces Ode's own full draft on request. This needs a new prompt path in `ReplyPrompt`; `ode-eval` runs before and after the change.

**Ode's lines.** Built from reviewed templates, plus at most one remembered fact when recall is confident. Examples: "Evening. Maya asked you something on Tuesday." / "Kept. Sam is next, if you have a minute." / "That's everyone. Nicely done." Speech is on by default with a toggle, and stops when Space is pressed. Ode never reads other people's messages aloud.

**Typing** is a full equal path: "or type" opens a field that goes through the same `VoiceIntent` parsing.

**Failures.**
- Mic denied: the dock reads "Mic is off. Type instead" with a link to System Settings.
- Speech model missing: download with progress.
- LM Studio down: deterministic routing still works; drafting falls back to Apple's model with the existing visible notice.

## Scene

**Lanterns.**
- A glass shell: transparent physically based material with clearcoat.
- Inside, a **camera-facing photo disc** (the Contacts photo, or a monogram on the person's hue). A photo is never wrapped onto the sphere.
- A soft point light inside, tinted by the photo's dominant color (softened) or a hue seeded from the conversation id.
- The loop mark: a camera-facing plane whose shader draws the master geometry (240 viewBox: arc from -31° to 241° clockwise, radius 74, stroke 60, round caps; dot at (139.2, 48.5), r 23). Two inputs:
  - `close` (0 to 1): grows both ends by `close × 44°` until they meet at the dot.
  - `blue` (0 to 1): blends the ring from paper to the accent `#2F4BE0`.
- Prominence drives scale, glow and idle pulse: `owed` lanterns pulse gently; `quiet` are cooler and dimmer; `around` are small and dim; `horizon` are points of light.
- Hovering brightens a lantern and shows its context line ("Asked if you're still in for Saturday").

**World.**
- A sky dome with a gradient shader driven by `Daylight`, with stars at night.
- A layer of hills on the horizon.
- A water plane with a ripple shader; reflections are mirrored, dimmed copies of the lanterns beneath it.
- `ParticleEmitterComponent` motes.
- Constellations: member lanterns joined by thin emissive threads.

**Glow.** The baseline is camera-facing additive glow sprites. True bloom through a custom post-process effect is an upgrade only if the spike shows it's practical; nothing depends on it.

**Camera.**
- Idle breathing plus mouse parallax.
- Focusing a person is an eased move of about 0.9 s that frames the lantern left of center, leaving room for the panel. The other lanterns dim and soften.
- Esc, "Not now" or clicking empty water returns the camera.
- With Reduce Motion: crossfades instead of flights, and no bobbing or parallax.

**Labels.** Names and "since Tuesday" are SwiftUI `Text` positioned by projecting each lantern's position to the view every frame. They are accessibility elements, so VoiceOver can read and activate them.

**Keyboard.** Arrow keys move a highlight between lanterns in reading order, Return opens the highlighted one, and Esc returns.

**Budget.** 60 fps at full window size on Joe's Mac. Rendering pauses when the window isn't visible.

## Reply panel

A glass panel on the right when a person is focused, containing:

1. Name and status ("waiting since Tuesday").
2. Their last message as a bubble.
3. Ode's one context line.
4. The draft, editable. From a click it shows Ode's pre-drafted reply, labeled "Ode's start". From voice it shows your words.
5. Suggestion chips.
6. Actions:
   - **Open in Messages ⌘↵**: through `MessagesHandoff`.
   - **Redraft**
   - **Check mine**: the existing draft review.
   - **Not now** (Esc): walks away.

   A menu holds **Not needed** (the existing dismissal, renamed from Done, which earns no ring) and **Open thread** (the classic thread view).
7. Footnote: "Ode never sends. You press send in Messages."

Holding Space while the panel is open edits the draft by voice.

## Kept

On a kept event:
1. The lantern's mark closes (`close` 0 → 1 over 0.9 s).
2. It turns blue (`blue` 0 → 1 over 0.5 s).
3. A soft accent ring pulses outward once.
4. The lantern drifts back to `around` depth.

The headline updates, and a ring is added to "Kept today". When nothing is waiting, the headline reads "Everyone's heard from you." and Ode's own mark closes into a full ring.

Headline copy comes from templates: "Three people would love to hear from you." / "Start with Maya. She asked about Saturday." / "One more." / "Everyone's heard from you." No scores, no streaks, no guilt.

## Spike (step 3, throwaway)

A minimal `RealityView` with five lanterns, water and sky. It passes if:

1. A real Contacts photo in a lantern looks warm, not like a memorial candle (Joe judges).
2. Flying to a person feels great at 60 fps.
3. The water reflections read as water.
4. Projected SwiftUI labels don't lag behind the lanterns.
5. Bloom is either practical or ruled out.

If 3 or 4 fail, the backdrop (sky, water, glow) falls back to 2.5D in SwiftUI `Canvas` with Metal shader effects, keeping the same layout, panel and voice. If 1 fails, the lantern design changes, not the plan.

## Testing

**Unit tests (OdeCore, Swift Testing):**
- `PlazaLayout`: stable positions across refreshes, prominence from waiting kind, group clustering, the 40-lantern cap, minimum separation.
- `VoiceIntent`: a table of real-shaped transcripts covering each verb, first names, nicknames, ambiguity, no name, edits while focused, and filler.
- `KeptDetector`: a send after the handoff counts; before it, in another conversation, or after 24 hours doesn't; it survives a reload.
- `Daylight`: dawn, noon, dusk and night boundaries.
- `HandleDirectory`: the photo attaches through the contact key; merged chats share it.

**Drafting.** Run `ode-eval run` before and after the "voice keeps your words" prompt path. Add a check that voice drafts keep the spoken substance and invent no new claims.

**Plaza walk (manual, every build):**
1. Launch, hold Space, speak, see the panel, press ⌘↵, send in Messages, and watch the ring close.
2. Repeat with Reduce Motion on, with VoiceOver, keyboard-only, with LM Studio off, and with the mic denied.

## Judging it

- **Step 1 starts handoff logging**, so a baseline accumulates before the Plaza exists.
- The Plaza ships behind a `plazaHome` setting, on for Joe.
- For two weeks after it lands, compare kept events per day against the two weeks before.
- If the Plaza doesn't beat the list, it becomes an optional view and the list returns as home. Beautiful but slower counts as a failure.

## Out of scope

- A global hotkey or always-listening wake word.
- Reading other people's messages aloud.
- Cloud speech recognition or cloud voices.
- Avatars generated from message content.
- Sending messages from Ode.
- Onboarding for anyone other than Joe's circle.
