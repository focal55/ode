# Ode

The product is named **Ode** (formerly ionship). The bundle id is `com.focal55.ode`; the repository folder and GitHub repo are still named ionship.

## Soul

**Ode helps you show up for the people who matter to you.**

It all started with one problem: laboring over what to text someone. That isn't really about wording. You struggle because the relationship matters and you're afraid of getting it wrong: too curt, too late, forgetting what they told you, breaking a promise. Ode exists for the moment before you hit send, and for knowing who needs to hear from you at all.

The test for every feature: **does it help me say the right thing to someone I care about, at the right time?** If not, it goes backstage or gets cut.

## User

Ode is a personal tool for Joe and a small circle of people he can set up in person, built around a local LLM. It is explored with a business mindset but with no pressure to launch publicly (decided October 2026). If it goes public one day, the likely buyers are people who care about their people and feel guilty about being bad at texting: anxious texters, people with ADHD, and busy founders.

What this means for the work:
- Judge a feature by whether Joe actually reaches for it, not by what it would cost to ship to strangers.
- Local compute is free. Expensive background work is fine: pre-drafting, nightly per-person summaries, re-judging every promise.
- Keep the door open cheaply: stable identifiers, the drafting eval, and journey notes on what actually helped. Skip launch-only work (onboarding for strangers, notarization, trademark filing) until there's evidence it's worth it.

## Product shape

Front stage, the core loop:

1. **Who's waiting on me** (home screen): unanswered messages from them, open loops (promises you made), and important people who have gone quiet. Each item has one action: help me reply.
2. **Help me reply:** the composer, using the context Ode already has (open loops, recalled memory, your writing style with this person, relationship history).
3. **Check my draft:** feedback on a reply *you* wrote ("reads colder than you usually are with her", "didn't answer her question about Saturday", "you said you'd send the photos"). Coach first, ghostwriter second.
4. **Hard messages:** apologies, condolences, saying no, reconnecting after a long silence. This is where history matters most and generic AI is worst.

Backstage. Keep these, but show them only as context in the loop above and don't invest further:

- Health metrics, temperature, patterns: shown as context while composing, not as a place you go.
- Group per-member breakdown: one "Sam went quiet in the group" item on the home list.
- Memory search (Cmd-K): memory should appear in the composer on its own.
- Multi-provider AI settings: cloud providers (Anthropic, OpenAI) are hidden behind `AISettings.cloudEnabled = false`. The code stays so they can come back.

Positioning: "never wonder what to text, and never drop the ball on people you love." Not "relationship analytics", which reads as creepy.

What we measure: messages sent that started in Ode. If Joe isn't reaching for it most days, the problem is the product, not distribution.

## Why we win

Apple will always rewrite text more generically and more conveniently, right inside Messages. Ode wins on **context**: it knows the history, the promises, and how you sound with this one person. It also wins on **reviewing what you wrote**, which keeps you as the author. Relationships turning into AI talking to AI is the long-term failure mode of this category; Ode should not contribute to it.

Competitors as of October 2026:
- **attune** (iPhone): you paste a draft and it explains what the text communicates, then rewrites it. $12.99 a month or $129.99 a year. It only sees the one draft.
- **Dear: Stay in Touch**, **KeepTouch**, **Kindest**, **Garden**, **Fabriq**, **Poppy**: apps that remind you to reach out, some with AI drafts. None of them read the actual conversation history.

## Brand

- **Name:** Ode. A poem to someone you care about; it sounds like "owed" (open loops); "an ode to" is a tribute.
- **Mark:** a heavy round-capped loop with a gap near the top, and a dot sitting inside the gap. The dot is what you owe, and closing the loop is keeping the promise. The dot never leaves the gap.
- **Wordmark:** the loop is the "o", followed by "de" in Nunito ExtraBold. The loop matches the letters' stroke weight and is about 5% taller than the "e".
- **Color:** ink `#14161C` on paper `#F6F4EF`; the accent is ink blue `#2F4BE0` (`Theme.accent`).
- **Motion:** owed (dot in the gap), then sent (the ends close on the dot), then kept (a full ring in the accent color).
- **Logo concepts and the final version:** https://claude.ai/artifact/L2TfmtpSWiFwrDidAvMPdT
- **Master geometry** (240 × 240 viewBox): path `M 183.4 81.9 A 74 74 0 1 1 84.1 55.3`, stroke 60, round caps; dot at (139.2, 48.5), r 23.

## Principles

- Ode never sends a message. The user always presses send in Messages.
- Local first. Messages, embeddings, memory and generation stay on the Mac. A local model served by LM Studio (OpenAI-compatible, `http://localhost:1234/v1`) is the primary engine; Apple's on-device model is only a fallback, because its drafts are much worse. When the fallback runs, say so in the UI. The cloud path (consent per conversation, redaction, spend cap) is kept but hidden.
- The other people in these conversations never agreed to be analyzed. Write copy and design features that respect that; avoid scoring or surveilling people.

## Known risks

Most of these only matter if Ode goes public.

- **Local model dependency:** drafting quality depends on LM Studio running with a good model. If it isn't running, Ode falls back to Apple's model, so that fallback must stay visible.
- **Full Disk Access onboarding** is the biggest funnel drop. The sandbox is off, so the app can't ship through the Mac App Store; it needs direct distribution with notarization. Show value before asking for access where possible (the file and paste import paths).
- **Reach** is limited to Mac users with Messages history synced to the Mac. No WhatsApp, Signal or Android.
- **Platform** risk: Apple controls the chat.db schema (there is drift detection), the on-device model (its safety filter blocks some ordinary excerpts), and the Messages features we compete with.
- **Trademark:** a USPTO search in October 2026 found no live ODE mark for messaging or writing software in classes 9 or 42. File an intent-to-use application for classes 9 and 42 before launch, because AI companies filed other ODE marks in mid-2026. sayode.com and heyode.com were unregistered at the time.
- **Identifiers are now permanent:** the bundle id `com.focal55.ode`, the Keychain service `com.focal55.ode.api-keys` and `~/Library/Application Support/Ode`. Once outside users install the app, changing any of them needs a migration, and macOS ties Full Disk Access to the bundle id.

## Code layout

- `OdeCore/`: Swift package holding everything testable. It reads chat.db read-only and computes metrics, patterns, open loops, memory (SQLite with MiniLM embeddings), writing style, draft review, redaction and the drafting prompt (`ReplyPrompt`). `ode-probe` prints aggregate decode health without any message content.
- `ode-eval` (in `OdeCore/`) measures drafting against replies Joe actually sent. `build` freezes a test set from the conversations chosen in Ode, `run --model <LM Studio id|apple>` drafts each one and has a local judge score the drafts, `review` shows Joe blind pairs of draft sets from different models' latest runs and records which he'd rather reply from (the judge scores substance, not whether it sounds like him), and `summary` compares runs and picks. The terminal shows only scores; message text stays in `~/Library/Application Support/Ode/eval/`, including the per-run reports. Don't read those reports or paste them into a chat: they hold other people's messages. Run it before and after any change to the prompt, model or context to see whether drafting got better.
- `Ode/`: the SwiftUI macOS app (macOS 26). `AppModel.swift` holds the app state; each screen is its own view file.
- `brand/`: SVG masters of the mark and the wordmark, with "de" outlined so no font is needed.
- `tools/brand/`: `wordmark.py` regenerates the SVGs from Nunito's variable font (`Nunito[wght].ttf` from google/fonts, OFL); `AppIcon.swift` renders `Ode/Assets.xcassets/AppIcon.appiconset`. The in-app `Wordmark` view draws `Wordmark.imageset`, a copy of `brand/ode-wordmark.svg`.
- `tools/minilm/`: conversion scripts for the bundled embedding model. See its README.

Run the core tests with `cd OdeCore && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`; the Command Line Tools toolchain lacks the Swift Testing macros. Build the app by opening `Ode.xcodeproj` in Xcode. From the command line, `xcode-select` points at the Command Line Tools on this Mac, so prefix with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` to use `xcodebuild`.

## Workforce: opted out

This project does not use the agentic workforce protocol while it's being prototyped quickly. Operate in interactive mode without consulting a project board or assuming the standard label conventions apply.
