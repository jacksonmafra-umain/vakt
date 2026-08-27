# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

VAKT is a menu-bar macOS app (SwiftUI, macOS 14+) that watches the built-in camera, confirms the
person at the keyboard is the enrolled owner, and locks the screen when that stops being true —
without letting the machine sleep, so background work keeps running.

## Repository state — read this first

There is **no Xcode project, Package.swift, build script, or test target in this repo**. The Swift
sources sit flat at the repository root; the `Sources/VAKT/...` tree described in `README.md` is the
layout you are expected to create *inside Xcode*, not what is on disk. There is no `swift build`,
`xcodebuild`, or `swift test` command that works here as-is.

Consequences when working in this repo:

- Verification of a change means reading it and reasoning about it, or building it in a real Xcode
  project the user has set up outside this repo. Do not claim a change "builds" without one.
- Do not invent a build/test command in docs or commit messages.
- If asked to make the repo buildable, ask first whether the target is a `Package.swift` (SwiftPM,
  which cannot produce the app bundle/entitlements this app needs) or a generated `.xcodeproj`.

Build/install steps for a human are in `README.md` (§Build): non-sandboxed, Hardened Runtime on,
`Info.plist` + `VAKT.entitlements` from the repo, LaunchAgent via `launchctl bootstrap`.

## Architecture

Single-direction data flow, one owner of the lock decision:

```
CaptureEngine  → SentryController → Locker / PowerAssertion
 (AVFoundation)   (@MainActor state machine)
                      ├── FaceAnalyzer   (Vision landmarks → FaceSample)
                      ├── LivenessEngine (is it a living head?)
                      ├── IdentityEngine (is it the owner?)
                      ├── AuthGate       (Touch ID / password for privilege changes)
                      ├── EnrollmentStore(Keychain owner template)
                      └── EventLog       (JSONL decision log)
```

Invariants worth preserving:

- **`SentryController` is the only thing allowed to call `Locker`.** Every other type reports; it
  decides. Keep it that way — a second lock caller makes lock reasons unauditable.
- **`SentryController` is `@MainActor`.** `CaptureEngine` delivers frames on its own
  `vakt.capture` queue and hops via `Task { @MainActor in ... }`. Anything reading controller state
  must be on the main actor.
- **An `undecided` liveness verdict must never refresh `lastFaceSeen`.** That is the whole photo
  defence: an unproven face cannot hold the session open by existing. See `handle(frame:)`.
- **Every state change that weakens protection goes through `AuthGate`** — arm, disarm, enrol,
  forget, change rules, quit. `PolicyStore.save` is deliberately *not* self-guarding; the call site
  must authenticate first (`SettingsView` does).
- **Never write frames or images to disk.** `EventLog` records decisions plus the scores that
  produced them, nothing else. This is a stated privacy guarantee in the README, not a preference.

### The liveness signal (`LivenessEngine`)

Macs have no TrueDepth/IR, so liveness is geometric and temporal, RGB-only. Per frame pair:

1. Fit a closed-form Procrustes similarity transform on the **rigid** landmarks only (nose, nose
   crest, median line, face contour).
2. Apply it to the **expressive** landmarks (eyes, brows, lips), measure the residual.
3. Subtract the rigid set's own residual — that residual *is* the detector noise floor, which is
   why the metric survives dim light and low frame rates without recalibration.

A flat photo yields ≈0 energy because every point moves under one transform. Fused with blink
(eye-aperture collapse, derived index-order-independently from the two farthest contour points) and
head micro-jitter (a taped-up photo has suspiciously *zero* motion), weights 0.55/0.35/0.10.

Attack flow to keep in mind: photo → identity `owner` + liveness `spoofSuspected` → wait out
`spoofGrace` → lock with reason `spoofSuspected`.

### Identity (`IdentityEngine`)

`FaceEmbedder` is a protocol with two implementations. `SentryController.init` tries
`CoreMLFaceEmbedder(modelName: "FaceEmbedder")` first and silently falls back to
`FeaturePrintEmbedder` (Vision's general image descriptor — *not* an identity descriptor, adequate
only for a stranger-vs-owner split under stable lighting).

The template records its `embedderIdentifier`; `match` refuses to compare across embedders and
returns `.inconclusive` rather than producing garbage similarities. If you change an embedder's
`identifier` string, existing enrolments stop matching and the user must re-enrol — that is the
intended behaviour, do not "fix" it by loosening the check.

All vectors are L2-normalised, so `VectorMath.cosine` is a plain dot product.

### Threshold changes

Every behavioural knob is a threshold, and they are personal to a user's camera and lighting. Do not
retune them speculatively. The named ones and their symptoms are tabulated in `README.md`
(§Calibration): `LivenessEngine.Tuning.fullMotion` / `.spoofAt`, `IdentityEngine.acceptThreshold` /
`.rejectThreshold` / `.minCaptureQuality`, `Policy.spoofGrace`.

Ground truth for tuning is `~/Library/Application Support/VAKT/events.jsonl` — every decision with
the liveness score and similarity that produced it.

## Platform constraints that are load-bearing

- **App Sandbox must stay off.** It blocks both `dlopen` of `login.framework` and the `CGSession`
  fallback, i.e. VAKT would detect an intruder and be unable to act. `VAKT.entitlements` sets
  `com.apple.security.app-sandbox` to `false` on purpose.
- **`SACLockScreenImmediate` is private API** (`login.framework`, via `dlopen`/`dlsym`). Keep the
  `CGSession -suspend` fallback intact. Neither path sleeps the machine.
- **`PowerAssertion` holds `PreventUserIdleSystemSleep` only** — the display is still free to sleep.
  Dark, locked screen; processes alive. Do not upgrade it to a display assertion.
- **`LSUIElement` is true** — menu-bar only, no Dock icon, no main window.
- The camera privacy LED is hardware-wired and will blink whenever `CaptureEngine` samples. That is
  why the capture is duty-cycled (`Cadence.burst` while idle, `.continuous` once a face appears).

## Conventions

- Comments in this codebase explain *why* a decision was made, often with the attack or failure mode
  it defends against. Match that register; do not add comments that restate the code.
- User-facing strings are British-spelled ("enrol", "authorise") and written as plain sentences —
  `LockReason.rawValue` doubles as the message shown in the menu.
- Prefer microcommits: one focused change per commit.
